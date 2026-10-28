# 11 – Rebuild runbook

This is the ordered plan for rebuilding the stack from a blank Raspberry Pi. It
reconstructs what is running today and incorporates the fixes recommended in
[08-security.md](08-security.md).

Use the placeholders from the [README](../README.md):

- Pi: `192.168.1.10`
- Router: `192.168.1.1`
- Public domain: `example.com`
- Hosts: `cloud.example.com`, `vault.example.com`, `media.example.com`
- User: `pi`

## Phase overview

| Phase | What | Approx. time |
| --- | --- | --- |
| 0 | Prepare hardware, accounts and secrets | 15 min |
| 1 | Install OS, set hostname, static IP, mount SSD | 30 min |
| 2 | Install and configure Pi-hole | 20 min |
| 3 | Install and configure Unbound | 20 min |
| 4 | Point the router at Pi-hole and verify DNS | 10 min |
| 5 | Install Docker | 10 min |
| 6 | Create the Cloudflare Tunnel | 20 min |
| 7 | Deploy Nextcloud | 30 min |
| 8 | Deploy Vaultwarden | 20 min |
| 9 | Deploy Jellyfin | 20 min |
| 10 | Harden, back up, monitor | 45 min |

Do not skip the verification step at the end of each phase.

## Phase 0 – Prepare

Gather:

- Raspberry Pi 5, 8 GB, official PSU, active cooler, Ethernet cable
- microSD card (32 GB+) and/or NVMe SSD + HAT
- A domain on Cloudflare (for the tunnel)
- A password manager for the secrets you are about to create

Decide on:

- LAN subnet and static address (`192.168.1.10/24` here)
- Public hostnames
- Which services should be public

Never reuse the credentials from this repository. Generate new ones.

## Phase 1 – Base OS and network

1. Flash Raspberry Pi OS 64-bit (bookworm or newer) with Raspberry Pi Imager.
   In the Imager settings:
   - hostname `rpi5`
   - user `pi`
   - SSH enabled with your public key
   - locale/timezone
2. Boot, connect Ethernet, and log in:

   ```bash
   ssh pi@192.168.1.10   # or the DHCP address first
   ```

3. Update:

   ```bash
   sudo apt update && sudo apt full-upgrade -y
   sudo reboot
   ```

4. Set a static address:

   ```bash
   sudo nmcli connection modify "Wired connection 1" \
     ipv4.method manual \
     ipv4.addresses 192.168.1.10/24 \
     ipv4.gateway 192.168.1.1 \
     ipv4.dns 192.168.1.10 \
     ipv6.method auto
   sudo nmcli connection up "Wired connection 1"
   ```

5. Mount the NVMe SSD:

   ```bash
   lsblk -f
   sudo mkfs.ext4 /dev/nvme0n1p1     # only if it is empty
   sudo mkdir -p /mnt/myssd
   sudo blkid /dev/nvme0n1p1         # copy the UUID
   ```

   Add to `/etc/fstab`:

   ```fstab
   UUID=<UUID>  /mnt/myssd  ext4  defaults  0  2
   ```

   ```bash
   sudo systemctl daemon-reload
   sudo mount -a
   findmnt /mnt/myssd
   ```

6. Verify:

   ```bash
   ip -brief addr
   ip route
   df -h /
   ```

## Phase 2 – Pi-hole

```bash
curl -sSL https://install.pi-hole.net | bash
```

Choose:

- Interface: `eth0`
- Upstream DNS: **leave it for now**, or use a temporary public resolver until Unbound
  is ready. The final configuration points to `127.0.0.1#5335`.
- Blocklists: choose the standard list (you can add the rest later)
- Web UI: enabled
- DHCP: **disabled**

Set the admin password:

```bash
sudo pihole setpassword
```

Verify:

```bash
sudo pihole status
sudo pihole -v
```

Do not point the router at Pi-hole yet; finish Unbound first.

## Phase 3 – Unbound

```bash
sudo apt update
sudo apt install -y unbound
```

Create `/etc/unbound/unbound.conf.d/pi-hole.conf` from
[`configs/unbound/pi-hole.conf`](../configs/unbound/pi-hole.conf). The final version
forwards to Cloudflare over DNS-over-TLS.

```bash
sudo systemctl enable --now unbound
sudo systemctl restart unbound
```

In Pi-hole, set the upstream to `127.0.0.1#5335`:

- Web UI: **Settings → DNS → Upstream DNS servers**, or
- edit `dns.upstreams` in `/etc/pihole/pihole.toml` and restart FTL.

Verify:

```bash
dig +short cloudflare.com @127.0.0.1 -p 5335
dig +noall +comments dnssec-failed.org @127.0.0.1 -p 5335 | grep status   # SERVFAIL
dig +short cloudflare.com @127.0.0.1
```

If you prefer full recursion instead of Cloudflare DoT, use
[`configs/unbound/pi-hole-recursive.conf.example`](../configs/unbound/pi-hole-recursive.conf.example)
and remove the `forward-zone` block.

## Phase 4 – Router and LAN DNS

1. Reserve `192.168.1.10` for the Pi on the router.
2. Set the router's DHCP DNS server to `192.168.1.10`.
3. Keep DHCP on the router.
4. Do not forward any inbound ports.

Verify from a LAN client:

```bash
# Linux/macOS
dig +short example.com
# Windows
nslookup example.com
```

The answer should come from Pi-hole. Check **Pi-hole → Query Log** to confirm.

At this point the DNS stack is complete and independent of the web services.

## Phase 5 – Docker

```bash
sudo apt install -y docker.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker pi
# log out and back in for the group change
docker run --rm hello-world
docker compose version
```

Optional: install the Compose v2 plugin from Docker's repository if you want a newer
version than Debian's.

## Phase 6 – Cloudflare Tunnel

Prerequisites: the domain is active on Cloudflare.

```bash
# Install cloudflared (Cloudflare apt repository or .deb)
cloudflared --version

cloudflared tunnel login
cloudflared tunnel create pi5-tunnel

sudo mkdir -p /etc/cloudflared
sudo cp ~/.cloudflared/<TUNNEL-UUID>.json /etc/cloudflared/credentials.json
sudo chown root:root /etc/cloudflared/credentials.json
sudo chmod 600 /etc/cloudflared/credentials.json
```

Create `/etc/cloudflared/config.yml` from
[`configs/cloudflared/config.yml`](../configs/cloudflared/config.yml):

```yaml
tunnel: pi5-tunnel
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: cloud.example.com
    service: http://localhost:8082
  - hostname: vault.example.com
    service: http://localhost:8081
  - hostname: media.example.com
    service: http://localhost:8096
  - service: http_status:404
```

Create DNS routes:

```bash
cloudflared tunnel route dns pi5-tunnel cloud.example.com
cloudflared tunnel route dns pi5-tunnel vault.example.com
cloudflared tunnel route dns pi5-tunnel media.example.com
```

Install the systemd unit from
[`configs/cloudflared/cloudflared.service`](../configs/cloudflared/cloudflared.service),
then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared
```

Do not expose Pi-hole, SSH, VNC or FTP through the tunnel.

## Phase 7 – Nextcloud

```bash
mkdir -p /home/pi/nextcloud/{html,db}
cd /home/pi/nextcloud
```

Create `docker-compose.yaml` and `.env` from
[`configs/nextcloud/`](../configs/nextcloud/). Generate strong database passwords.

```bash
docker compose up -d
docker compose ps
docker logs -f nextcloud-app
```

Open `http://192.168.1.10:8082`, create the admin account, and complete the setup wizard.
Then set the public URL and proxy configuration:

```bash
docker exec -u www-data nextcloud-app php occ config:system:set \
  overwrite.cli.url --value=https://cloud.example.com
docker exec -u www-data nextcloud-app php occ config:system:set \
  overwriteprotocol --value=https
docker exec -u www-data nextcloud-app php occ config:system:set \
  trusted_domains 0 --value=cloud.example.com
docker exec -u www-data nextcloud-app php occ background:cron
```

Add the cron entry from [05-nextcloud.md](05-nextcloud.md).

Verify: `https://cloud.example.com` returns the login page over HTTPS and assets load
without mixed-content warnings.

## Phase 8 – Vaultwarden

```bash
mkdir -p /home/pi/vaultwarden
cd /home/pi/vaultwarden
# create docker-compose.yaml and .env from configs/vaultwarden/
docker compose up -d
docker logs -f vaultwarden
```

Create the first account at `https://vault.example.com` **before** disabling signups.
Then:

```bash
# Hash the admin token
docker exec -it vaultwarden /vaultwarden hash
```

Put the hash in the authoritative config (`config.json` or `ADMIN_TOKEN`), restart, and
set `SIGNUPS_ALLOWED=false`.

Verify: log in, create an item, confirm it survives a container restart, and check the
backup.

## Phase 9 – Jellyfin

```bash
mkdir -p /home/pi/jellyfin/{config,cache}
cd /home/pi/jellyfin
# create docker-compose.yml from configs/jellyfin/
docker compose up -d
docker logs -f jellyfin
```

Open `http://192.168.1.10:8096`, complete the wizard, and add libraries under `/media`.
Set:

```yaml
environment:
  - JELLYFIN_PublishedServerUrl=https://media.example.com
```

Then recreate the container.

Verify: play a file locally and through `https://media.example.com`.

## Phase 10 – Harden, back up, monitor

1. SSH keys only:

   ```bash
   sudoedit /etc/ssh/sshd_config.d/10-hardening.conf
   ```

   ```conf
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PermitRootLogin no
   ```

   ```bash
   sudo sshd -t && sudo systemctl reload ssh
   ```

2. Remove or disable unused services:

   ```bash
   sudo systemctl disable --now vsftpd
   sudo systemctl disable --now vncserver-x11-serviced
   ```

3. Add firewall rules ([02-network.md](02-network.md)).
4. Put `vault.example.com` behind Cloudflare Access.
5. Install the backup script and schedule it:

   ```bash
   sudo ./scripts/backup.sh /mnt/myssd/backups
   sudo crontab -e
   ```

   ```cron
   30 3 * * * /home/pi/rpi5-homelab/scripts/backup.sh /mnt/myssd/backups >> /var/log/rpi5-backup.log 2>&1
   ```

6. Copy backups off-site with restic/borg.
7. Enable Cloudflare "Always Use HTTPS" and HSTS.
8. Apply pending Pi-hole and EEPROM updates.
9. Run the healthcheck:

   ```bash
   ./scripts/healthcheck.sh
   ```

## Final verification checklist

- [ ] `pihole status` shows FTL listening on 53 over IPv4 and IPv6
- [ ] `dig cloudflare.com @127.0.0.1` returns an answer
- [ ] `dig dnssec-failed.org @127.0.0.1` returns `SERVFAIL`
- [ ] LAN clients receive `192.168.1.10` as DNS
- [ ] `https://cloud.example.com` loads over HTTPS
- [ ] `https://vault.example.com` loads over HTTPS
- [ ] `https://media.example.com` loads over HTTPS
- [ ] `docker ps` shows Nextcloud, MariaDB, Vaultwarden and Jellyfin healthy
- [ ] Vaultwarden data survives a restart
- [ ] Nextcloud background cron runs every 5 minutes
- [ ] Backups exist on the NVMe and off-site
- [ ] A restore has been tested
- [ ] No inbound ports are forwarded on the router
- [ ] SSH password authentication is disabled
- [ ] VNC and FTP are disabled unless deliberately needed
- [ ] Pi-hole and EEPROM are up to date
- [ ] `vcgencmd get_throttled` returns `0x0`

## What the original setup looked like

For reference, the live system at scan time differed from this runbook in these ways:

- Pi-hole upstream was already `127.0.0.1#5335`, with Unbound forwarding to Cloudflare
  over DoT (the recursive config was kept as `.bak`).
- Nextcloud `overwrite.cli.url` still referenced the previous domain and used `http://`;
  proxy headers were not set.
- Vaultwarden stored `ADMIN_TOKEN` in plaintext, and `config.json` overrode the compose
  environment.
- Jellyfin advertised `http://192.168.1.10` instead of the public HTTPS URL.
- No cron entry existed for Nextcloud background jobs.
- VNC and `vsftpd` were running; SSH accepted passwords; UFW was absent.
- Backups were manual and local only.

The runbook above is the corrected rebuild plan, not a byte-for-byte copy of the
original.
