# 07 – Jellyfin

Jellyfin is a free media server. It runs in Docker with **host networking** so that
clients can discover it on the LAN and so it can use the host's ports directly.

## Current deployment

| Item | Value |
| --- | --- |
| Jellyfin | 10.10.7 |
| Image | `jellyfin/jellyfin:latest` |
| Container | `jellyfin` |
| Network | `host` |
| HTTP port | `8096` |
| Discovery port | UDP `7359` |
| Container user | `1000:1000` |
| Config | `/home/pi/jellyfin/config` |
| Cache | `/home/pi/jellyfin/cache` |
| Media | `/mnt/myssd` (NVMe SSD) |
| Public URL | `https://media.example.com` |
| Healthcheck | `curl -f http://192.168.1.10:8096/health` every 30 s |

The Jellyfin directory is about **1.1 GB**, mostly metadata and images.

## Compose file

The live file is `/home/pi/jellyfin/docker-compose.yml`. A sanitized version is in
[`configs/jellyfin/docker-compose.yml`](../configs/jellyfin/docker-compose.yml).

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    user: 1000:1000
    network_mode: host
    volumes:
      - ./config:/config
      - ./cache:/cache
      - /mnt/myssd:/media
    restart: unless-stopped
    environment:
      - JELLYFIN_PublishedServerUrl=https://media.example.com
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8096/health"]
      interval: 30s
      timeout: 10s
      retries: 5
```

### Why host networking?

With `network_mode: host`:

- Jellyfin binds directly to `8096/tcp` and `7359/udp` on the Pi.
- DLNA and client auto-discovery work on the LAN.
- There is no Docker port mapping to maintain.
- The container shares the host network namespace, so it sees all host interfaces.

The trade-off is that you cannot use Docker's port isolation for this container. Keep it
updated and do not expose `8096` to the internet directly; use the tunnel.

### Why `user: 1000:1000`?

The media files on `/mnt/myssd` are owned by UID/GID 1000. Running the container as that
user avoids permission problems and prevents Jellyfin from creating root-owned files.

## Media layout

All media is on the NVMe SSD:

```text
/mnt/myssd
└── ...   # movies, series, music, etc.
```

The container sees this as `/media`. Add libraries in the Jellyfin web UI under
**Dashboard → Libraries**, pointing at `/media/<folder>`.

Because the SSD is mounted in `/etc/fstab` by UUID, it is available before Docker starts.
If the mount fails, Jellyfin will start with an empty `/media`. Verify with:

```bash
findmnt /mnt/myssd
docker exec jellyfin ls -la /media
```

## HTTPS and the published URL

TLS is terminated by Cloudflare. Jellyfin itself serves plain HTTP and its network
configuration is:

```xml
<BaseUrl />
<EnableHttps>false</EnableHttps>
<RequireHttps>false</RequireHttps>
```

The container environment, however, was:

```text
JELLYFIN_PublishedServerUrl=http://192.168.1.10
```

This advertises the **LAN HTTP URL** to clients, even when they connect through
`https://media.example.com`. That can cause redirects, cast/remote-play URLs and client
configuration to point at an address that is not reachable from outside the LAN.

Set it to the public URL instead:

```yaml
environment:
  - JELLYFIN_PublishedServerUrl=https://media.example.com
```

Then recreate the container:

```bash
cd /home/pi/jellyfin
docker compose up -d
```

If you serve Jellyfin under a subpath, also set `<BaseUrl>/jellyfin</BaseUrl>` in
`config/config/network.xml` and route the path in Cloudflare. This setup uses a dedicated
hostname, so `BaseUrl` stays empty.

## Hardware transcoding on a Pi 5

The Raspberry Pi 5 has no supported hardware video encoder that Jellyfin can use for
transcoding in the same way as Intel Quick Sync or VAAPI on x86. Expect **software
transcoding**, which is CPU-heavy.

Practical guidance:

- Prefer direct play / direct stream.
- Use client-compatible codecs (H.264/AAC in MP4) for the library.
- Avoid transcoding 4K on the Pi.
- Set per-user or per-library bitrate limits if remote playback stutters.
- Monitor CPU and temperature during playback:

  ```bash
  top -b -n1 | head -20
  vcgencmd measure_temp
  ```

## Updating Jellyfin

```bash
cd /home/pi/jellyfin

# 1. Back up config (small, important)
sudo tar czf /mnt/myssd/backups/jellyfin-$(date +%F).tar.gz -C /home/pi/jellyfin config

# 2. Pull and recreate
docker compose pull
docker compose up -d

# 3. Verify
docker ps --filter name=jellyfin
curl -fsS http://localhost:8096/health && echo OK
```

Jellyfin occasionally changes its database schema. Read the release notes before a major
upgrade and keep the config backup.

## Storage and performance notes

- **Config and cache are on the SD card** (`/home/pi/jellyfin`). Metadata and image
  caching can be write-heavy. Consider moving `config` and `cache` to the NVMe SSD.
- **Media is on the NVMe SSD**, which is the right place for it.
- The SSD is a Crucial P3 Plus. Monitor its health with `smartctl`.
- If the Pi runs out of RAM, Jellyfin's cache and the Nextcloud/MariaDB containers can
  compete. The 8 GB model has headroom, but watch `free -h` and `docker stats`.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Web UI not reachable on LAN | `ss -tlnp | grep 8096`, container running, host network |
| 502 from Cloudflare | Is Jellyfin up? Is `cloudflared` up? Is the port still 8096? |
| Media folder empty | Is `/mnt/myssd` mounted? Permissions for UID 1000? |
| Playback stutters remotely | Transcoding; check CPU, bitrate, direct play |
| Clients use wrong URL | `JELLYFIN_PublishedServerUrl` and `BaseUrl` |
| Healthcheck failing | `curl -v http://localhost:8096/health`; check container logs |

Logs:

```bash
docker logs -f jellyfin
sudo journalctl -u docker -f
```
