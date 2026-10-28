# 09 – Backup and recovery

Backups are the weakest part of the current setup. Pi-hole has automatic configuration
backups, and Vaultwarden has two manual copies, but Nextcloud has no backup job and
nothing is stored off-site.

## What exists today

| Component | Existing protection | Gap |
| --- | --- | --- |
| Pi-hole config | `/etc/pihole/config_backups` (628 KB) | Local only |
| Pi-hole gravity | `/etc/pihole/gravity_backups` (884 KB) | Local only; reproducible with `pihole -g` |
| Vaultwarden | Two manual `vw-data` copies | Not scheduled, not off-site |
| Nextcloud | None found | Database and files unprotected |
| Jellyfin | None found | Config/metadata unprotected; media is on NVMe |
| Cloudflared | Config + credentials on disk | No backup; credentials can be reissued |
| Compose files | On disk | Not in version control |

## Recommended policy: 3-2-1

- **3** copies of important data
- **2** different media
- **1** off-site

For this homelab:

| Copy | Location |
| --- | --- |
| 1 | Live data on the Pi |
| 2 | Snapshot on `/mnt/myssd` (NVMe) |
| 3 | Encrypted copy on another machine or cloud storage |

Use `restic` or `borg` for the off-site copy. Both support encryption, deduplication and
retention. Do not sync plaintext backups to a public cloud bucket.

## What to back up

### Critical

- Vaultwarden `vw-data` (especially `db.sqlite3`, `rsa_key.pem`, `config.json`)
- Nextcloud database (MariaDB dump) and `html/config/config.php`
- Nextcloud user data (`html/data`), if you do not back up files separately
- Cloudflare tunnel config, and the ability to recreate credentials
- Compose files and `.env` files (store secrets in a password manager)

### Nice to have

- Pi-hole configuration and Teleporter export
- Jellyfin `config`
- Crontabs, `/etc/fstab`, NetworkManager profiles
- SSH host keys (for client trust continuity)

### Not necessary

- Docker images (rebuild/pull)
- Jellyfin cache
- Pi-hole gravity database (can be regenerated)
- Media files (back them up separately; they are large)

## Backup script

[`scripts/backup.sh`](../scripts/backup.sh) creates a timestamped directory containing:

- Pi-hole Teleporter/config files
- Nextcloud MariaDB dump and `config.php`
- Vaultwarden `vw-data` (container stopped for a consistent SQLite copy)
- Jellyfin `config`
- Compose files and tunnel config

Usage:

```bash
sudo ./scripts/backup.sh /mnt/myssd/backups
```

The script refuses to overwrite an existing backup directory and prints a summary. Review
it before running; it stops Vaultwarden briefly to get a consistent database copy.

Schedule it with cron or a systemd timer. Example cron entry (root):

```cron
30 3 * * * /home/pi/rpi5-homelab/scripts/backup.sh /mnt/myssd/backups >> /var/log/rpi5-backup.log 2>&1
```

Then copy `/mnt/myssd/backups` off-site with restic/borg/rsync.

## Restore procedures

### Pi-hole

Fastest path: fresh Pi-hole install, then import a Teleporter archive from
**Settings → Teleporter** in the web UI.

Manual restore:

```bash
sudo systemctl stop pihole-FTL
sudo cp -a /path/to/backup/pihole/etc-pihole/. /etc/pihole/
sudo systemctl start pihole-FTL
sudo pihole restartdns
```

If you restore `pihole.toml`, review interface names and the upstream (`127.0.0.1#5335`)
afterwards. Recreate the Unbound config from
[`configs/unbound/pi-hole.conf`](../configs/unbound/pi-hole.conf) if needed.

### Nextcloud

Full restore from bind mounts:

```bash
cd /home/pi/nextcloud
docker compose down

sudo rm -rf html db
sudo tar xzf /path/to/backup/nextcloud-html.tar.gz -C /home/pi/nextcloud
sudo tar xzf /path/to/backup/nextcloud-db.tar.gz -C /home/pi/nextcloud

docker compose up -d
docker exec -u www-data nextcloud-app php occ maintenance:mode --off
docker exec -u www-data nextcloud-app php occ status
```

Database dump restore (if the backup contains a `.sql` file):

```bash
cd /home/pi/nextcloud
docker compose up -d db
# wait for MariaDB to be ready
docker exec -i nextcloud-db mariadb -u root -p"$MYSQL_ROOT_PASSWORD" nextcloud \
  < /path/to/nextcloud.sql
docker compose up -d app
```

After restoring, confirm `trusted_domains`, `overwrite.cli.url`, `overwriteprotocol` and
`trusted_proxies` match the current environment.

### Vaultwarden

```bash
cd /home/pi/vaultwarden
docker compose down

sudo rm -rf vw-data
sudo tar xzf /path/to/vaultwarden.tar.gz -C /home/pi/vaultwarden

docker compose up -d
docker logs --tail 50 vaultwarden
```

Restore `rsa_key.pem` together with the database. Restoring the database without the key
can invalidate sessions and some encrypted data.

### Jellyfin

```bash
cd /home/pi/jellyfin
docker compose down

sudo rm -rf config
sudo tar xzf /path/to/jellyfin-config.tar.gz -C /home/pi/jellyfin

docker compose up -d
```

Recheck library paths if `/mnt/myssd` is mounted somewhere else.

### Cloudflare tunnel

The tunnel credential is a secret. Prefer creating a new tunnel rather than restoring an
old credential from backup:

```bash
cloudflared tunnel login
cloudflared tunnel create pi5-tunnel
sudo cp ~/.cloudflared/<UUID>.json /etc/cloudflared/credentials.json
sudo chmod 600 /etc/cloudflared/credentials.json
# restore /etc/cloudflared/config.yml
cloudflared tunnel route dns pi5-tunnel cloud.example.com
cloudflared tunnel route dns pi5-tunnel vault.example.com
cloudflared tunnel route dns pi5-tunnel media.example.com
sudo systemctl restart cloudflared
```

If you restore the old credentials, make sure the old tunnel still exists and that the
credential file was stored securely.

## Disaster recovery order

1. Install Raspberry Pi OS and create the admin user.
2. Set the static IP and mount the NVMe.
3. Install Pi-hole and Unbound; restore Pi-hole config.
4. Install Docker.
5. Restore Nextcloud, Vaultwarden and Jellyfin data and compose files.
6. Install `cloudflared`, recreate or restore the tunnel, and recreate DNS routes.
7. Verify DNS, DNSSEC, all three public endpoints, and container health.
8. Re-enable backups and monitoring.

## Test your restores

A backup that has never been restored is a hope, not a backup. Once per quarter:

1. Restore Vaultwarden into a temporary directory and start it on a different port.
2. Log in and confirm the vault is intact.
3. Restore the Nextcloud database into a scratch container and run `occ status`.
4. Check that `rsa_key.pem` and `config.php` are present in the backups.
