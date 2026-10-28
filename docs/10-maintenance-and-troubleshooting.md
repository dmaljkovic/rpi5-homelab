# 10 – Maintenance and troubleshooting

## Routine maintenance

### Weekly

```bash
# Quick health check
./scripts/healthcheck.sh

# Container state
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Disk and memory
df -h /
free -h
```

### Monthly

```bash
sudo apt update && sudo apt full-upgrade -y
sudo pihole -up
sudo pihole -g

cd /home/pi/nextcloud && docker compose pull && docker compose up -d
cd /home/pi/vaultwarden && docker compose pull && docker compose up -d
cd /home/pi/jellyfin && docker compose pull && docker compose up -d

sudo apt install --only-upgrade cloudflared
sudo systemctl restart cloudflared
```

Read the release notes before major Nextcloud, Vaultwarden or Jellyfin upgrades.

### Quarterly

- Test a restore (see [09-backup-and-recovery.md](09-backup-and-recovery.md)).
- Review Cloudflare tunnel connectors and DNS records.
- Check `smartctl -H /dev/nvme0n1`.
- Check `vcgencmd get_throttled` and temperatures.
- Review open ports with `ss -tulpn`.
- Rotate any secrets that may have been exposed.

## Update notes for this system

At scan time:

- Pi-hole Core 6.4.3 (latest 6.5), Web 6.6 (latest 6.6.1), FTL 6.7 (latest 6.8)
- Pi EEPROM update available
- `cloudflared` 2026.10.5
- Docker 20.10.24, Compose plugin 5.6.1, legacy `docker-compose` 1.29.2

Apply the Pi-hole and EEPROM updates during a quiet period. Pi-hole updates can briefly
interrupt DNS; clients will fail over to the secondary DNS if one is configured.

## Health checks

[`scripts/healthcheck.sh`](../scripts/healthcheck.sh) checks:

- Pi-hole FTL status and DNS resolution
- Unbound on port 5335
- DNSSEC failure behaviour
- Docker containers and health
- Public HTTPS endpoints
- Disk usage, memory and temperature

Run it with:

```bash
./scripts/healthcheck.sh
```

## Logs

| Service | Command |
| --- | --- |
| Pi-hole FTL | `sudo journalctl -u pihole-FTL -f` |
| Pi-hole query log | `sudo tail -f /var/log/pihole/pihole.log` |
| Unbound | `sudo journalctl -u unbound -f` |
| cloudflared | `sudo journalctl -u cloudflared -f` |
| Nextcloud app | `docker logs -f nextcloud-app` |
| Nextcloud DB | `docker logs -f nextcloud-db` |
| Vaultwarden | `docker logs -f vaultwarden` |
| Jellyfin | `docker logs -f jellyfin` |
| Docker daemon | `sudo journalctl -u docker -f` |
| Kernel / hardware | `dmesg -T` |

## Troubleshooting

### DNS stops working

```bash
sudo pihole status
sudo systemctl status unbound pihole-FTL
sudo ss -ulpn | grep -E ':53|:5335'
dig +short example.com @127.0.0.1
dig +short example.com @127.0.0.1 -p 5335
```

If Pi-hole works but Unbound does not, restart Unbound and check its logs. If both work
on the Pi but LAN clients fail, check the router's DNS setting and the Pi's firewall.

### `SERVFAIL` for everything

Usually DNSSEC validation or upstream connectivity:

```bash
dig +noall +comments dnssec-failed.org @127.0.0.1 -p 5335 | grep status
dig +noall +comments cloudflare.com @127.0.0.1 -p 5335 | grep status
sudo journalctl -u unbound -n 100 --no-pager
```

Check that outbound UDP/TCP 853 (DNS-over-TLS) is allowed and that the system clock is
correct (DNSSEC is time-sensitive).

### Public site returns 502 / 1033

```bash
sudo systemctl status cloudflared
sudo journalctl -u cloudflared -n 100 --no-pager
docker ps
curl -I http://localhost:8082
curl -I http://localhost:8081
curl -I http://localhost:8096
```

- 502: `cloudflared` is up but the local service is down or on the wrong port.
- 1033: Cloudflare cannot reach the tunnel connector; check the tunnel and credentials.
- 404: the hostname is not in the ingress list or matches the fallback rule.

### Nextcloud redirects to `http://` or the wrong domain

```bash
docker exec -u www-data nextcloud-app php occ config:system:get overwrite.cli.url
docker exec -u www-data nextcloud-app php occ config:system:get overwriteprotocol
docker exec -u www-data nextcloud-app php occ config:system:get trusted_domains
```

Set them as shown in [05-nextcloud.md](05-nextcloud.md). If you see "Access through
untrusted domain", add the hostname to `trusted_domains`.

### Nextcloud is slow / background jobs not running

```bash
docker exec -u www-data nextcloud-app php occ background:cron
# add the 5-minute cron entry from docs/05-nextcloud.md
docker exec -u www-data nextcloud-app php occ status
```

### Vaultwarden settings do not change

`config.json` overrides environment variables. Check the container logs for the warning
and edit the authoritative source. See [06-vaultwarden.md](06-vaultwarden.md).

### Jellyfin remote playback fails

- Confirm the client can reach `https://media.example.com`.
- Check `JELLYFIN_PublishedServerUrl`.
- Look for transcoding in the dashboard; the Pi 5 is CPU-limited.
- Check `docker logs jellyfin` for ffmpeg errors.

### SD card or disk full

```bash
df -h
sudo du -sh /var/lib/docker /home/pi/* /var/log 2>/dev/null | sort -h
docker system df
```

Safe cleanup:

```bash
docker image prune -f
docker builder prune -f
sudo journalctl --vacuum-time=14d
sudo apt autoremove --purge -y
```

Do **not** delete `vw-data`, `nextcloud/html`, `nextcloud/db`, `jellyfin/config` or
`/mnt/myssd` media.

### Pi is hot or throttled

```bash
vcgencmd measure_temp
vcgencmd get_throttled
```

`0x0` means no throttling. Clean the cooler, improve airflow, or reduce transcoding
load. The Pi 5 with active cooling should stay well below 80 °C.

### Recovering from a bad update

- Pi-hole: `sudo pihole -r` (repair) or restore config.
- Cloudflared: reinstall the package and restore `config.yml`.
- Containers: `docker compose down && docker compose up -d`; if an image is broken,
  pin the previous tag.
- Keep the previous compose file and `.env` for each service.

## Monitoring ideas

- Uptime Kuma (another container) for HTTP checks and notifications.
- Pi-hole's built-in query log and long-term database.
- `node_exporter` + Prometheus/Grafana for host metrics.
- Cloudflare Analytics for tunnel traffic and errors.
- A simple cron job that emails or notifies you if `scripts/healthcheck.sh` fails.
