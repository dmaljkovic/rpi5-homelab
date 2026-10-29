# 05 – Nextcloud

Nextcloud runs as two Docker containers: the application and a MariaDB database. It is
published through the Cloudflare Tunnel at `cloud.example.com`.

## Current deployment

| Item | Value |
| --- | --- |
| Nextcloud | 32.0.1.2 (image `nextcloud:latest`) |
| Database | MariaDB 10.6.24 (image `mariadb:10.6`) |
| App container | `nextcloud-app`, `restart: always` |
| DB container | `nextcloud-db`, `restart: always` |
| App port | `0.0.0.0:8082 -> 80/tcp` |
| DB port | internal only |
| Compose project | `nextcloud` |
| App data | `/home/pi/nextcloud/html` (bind mount) |
| DB data | `/home/pi/nextcloud/db` (bind mount) |
| Public URL | `https://cloud.example.com` |
| Local URL | `http://192.168.1.10:8082` |

The Nextcloud directory occupies about **3.6 GB** on the SD card.

## Compose file

The live compose file is at `/home/pi/nextcloud/docker-compose.yaml`. A sanitized version
is in
[`configs/nextcloud/docker-compose.yaml`](../configs/nextcloud/docker-compose.yaml), with
passwords moved to environment variables.

Key points:

- The database uses `--transaction-isolation=READ-COMMITTED` and
  `--binlog-format=ROW`, which are the recommended MariaDB settings for Nextcloud.
- Nextcloud connects to the database using the service name `db`.
- Both containers use bind mounts, not named volumes. Backups must therefore copy
  `/home/pi/nextcloud/html` and `/home/pi/nextcloud/db`.
- There is **no healthcheck** on either container. Add one if you want Docker to
  restart a wedged app.
- The `version: "3.8"` key is obsolete in modern Compose but harmless.

## Initial deployment

```bash
mkdir -p /home/pi/nextcloud/{html,db}
cd /home/pi/nextcloud
# create docker-compose.yaml and .env (see configs/)
docker compose up -d
```

The Nextcloud image initializes the database on first start. Then finish the setup in the
browser at `http://192.168.1.10:8082` and create the admin account.

### Environment variables

```dotenv
MYSQL_ROOT_PASSWORD=change-me-root
MYSQL_PASSWORD=change-me-nextcloud
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
```

Both the `db` and `app` services must use the same `MYSQL_PASSWORD`. The root password is
only used by the database container.

## Post-install configuration

The live `config.php` contains:

```php
'trusted_domains' =>
array (
  0 => 'cloud.example.com',
  1 => '192.168.1.10',
),
'overwrite.cli.url' => 'https://cloud.example.com',
'overwriteprotocol' => 'https',
'trusted_proxies' =>
array (
  0 => '172.19.0.1',
  1 => '127.0.0.1',
),
'forwarded_for_headers' =>
array (
  0 => 'HTTP_X_FORWARDED_FOR',
),
'datadirectory' => '/var/www/html/data',
'memcache.local' => '\\OC\\Memcache\\APCu',
'dbname' => 'nextcloud',
'dbhost' => 'db',
'dbuser' => 'nextcloud',
```

The database password and secret are stored in `config.php` as well. That file is
sensitive; it is inside the bind-mounted `html` directory and must never be committed.

Useful `occ` commands (run inside the container):

```bash
# Status and version
docker exec -u www-data nextcloud-app php occ status

# List apps
docker exec -u www-data nextcloud-app php occ app:list

# Set the canonical URL and force HTTPS
docker exec -u www-data nextcloud-app php occ config:system:set \
  overwrite.cli.url --value=https://cloud.example.com
docker exec -u www-data nextcloud-app php occ config:system:set \
  overwriteprotocol --value=https

# Keep only the public hostname as a trusted domain
docker exec -u www-data nextcloud-app php occ config:system:set \
  trusted_domains 0 --value=cloud.example.com

# Add the LAN name/IP if you also use it directly
docker exec -u www-data nextcloud-app php occ config:system:set \
  trusted_domains 1 --value=192.168.1.10

# Trust the Docker bridge gateway and localhost as reverse proxies
docker exec -u www-data nextcloud-app php occ config:system:set \
  trusted_proxies 0 --value=172.19.0.1
docker exec -u www-data nextcloud-app php occ config:system:set \
  trusted_proxies 1 --value=127.0.0.1
docker exec -u www-data nextcloud-app php occ config:system:set \
  forwarded_for_headers 0 --value=HTTP_X_FORWARDED_FOR
```

## Installed apps

Enabled apps included:

`activity`, `app_api`, `bruteforcesettings`, `calendar`, `circles`,
`cloud_federation_api`, `comments`, `contacts`, `contactsinteraction`, `dashboard`,
`dav`, `federatedfilesharing`, `federation`, `files`, `files_downloadlimit`,
`files_pdfviewer`, `files_reminders`, `files_sharing`, `files_trashbin`,
`files_versions`, `firstrunwizard`, `logreader`, `lookup_server_connector`, `mail`,
`nextcloud_announcements`, `notes`, `notifications`, `oauth2`, `password_policy`,
`photos`, `privacy`, `profile`, `provisioning_api`, `recommendations`,
`related_resources`, `richdocuments`, `serverinfo`, `settings`, `sharebymail`,
`spreed`, `support`, `survey_client`, `systemtags`, `text`, `theming`,
`twofactor_backupcodes`, `updatenotification`, `user_status`, `viewer`,
`weather_status`, `webhook_listeners`, `workflowengine`.

Notable additions beyond a default install:

- **Calendar** and **Contacts** – personal information management
- **Mail** – webmail client
- **Notes** – Markdown notes
- **Richdocuments** – Collabora Online integration
- **Talk (`spreed`)** – chat and video calls
- **Photos** – photo management

Disabled apps included `admin_audit`, `encryption`, `files_external`,
`richdocumentscode`, `suspicious_login` and `twofactor_nextcloud_notification`.

## Configuration fixes

### 1. Stale canonical URL and missing HTTPS override (fixed 2026-10-29)

Originally, `overwrite.cli.url` pointed at the **previous** domain and used `http://`,
so the public endpoint returned:

```text
https://cloud.example.com -> 302 http://cloud.example.com/login
```

The live config now uses:

```php
'overwrite.cli.url' => 'https://cloud.example.com',
'overwriteprotocol' => 'https',
```

and the public endpoint redirects to `https://cloud.example.com/login`. Direct HTTP
access to `127.0.0.1:8082` also redirects to HTTPS; use the public hostname or a local
TLS reverse proxy for LAN access.

### 2. Trusted proxy configuration (fixed 2026-10-29)

`trusted_proxies` and `forwarded_for_headers` were not set. Behind the tunnel,
Nextcloud saw the connection as coming from the local Docker/cloudflared path rather
than the real client. This affects:

- brute-force protection (it may throttle the wrong address)
- login/audit logs
- URL generation
- client IP detection

The live config now has the addresses the container actually sees:

```text
trusted_proxies[0] = 172.19.0.1   (Docker bridge gateway)
trusted_proxies[1] = 127.0.0.1
forwarded_for_headers[0] = HTTP_X_FORWARDED_FOR
```

Verify with `occ config:system:get trusted_proxies` and
`occ config:system:get forwarded_for_headers`.

Cloudflare also sends `CF-Connecting-IP`. If you need the real client IP and you are
certain only Cloudflare can reach the origin, handle it at the proxy layer. Do not trust
forwarded headers from arbitrary clients.

### 3. Background jobs are not using cron

`backgroundjobs_mode` was unset and there was no cron entry. Nextcloud then falls back
to AJAX jobs triggered by page loads, which is slower and less reliable. Fix:

```bash
docker exec -u www-data nextcloud-app php occ background:cron
```

Then add a host cron entry (as root):

```cron
*/5 * * * * docker exec -u www-data nextcloud-app php -f /var/www/html/cron.php
```

### 4. Data lives on the SD card

The app's data directory is on the 58 GB microSD. Nextcloud is write-heavy and can wear
out the card. Move `html/data` (or the entire `html` bind mount) to the NVMe SSD when
convenient.

### 5. No healthcheck

Add a healthcheck to the app service, for example:

```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -fsS http://localhost/status.php || exit 1"]
  interval: 30s
  timeout: 10s
  retries: 5
```

The `nextcloud` image includes `curl`.

## Updating Nextcloud

```bash
cd /home/pi/nextcloud

# 1. Back up first
sudo tar czf /mnt/myssd/backups/nextcloud-$(date +%F).tar.gz \
  -C /home/pi/nextcloud html db docker-compose.yaml

# 2. Update
docker compose pull
docker compose up -d

# 3. Run the upgrade if the web UI asks for it
docker exec -u www-data nextcloud-app php occ upgrade
docker exec -u www-data nextcloud-app php occ maintenance:mode --off
```

Major version upgrades should be done one major version at a time if you are far behind.
The `latest` tag makes upgrades automatic but also unpredictable; consider pinning a
tested version.

## Logs

```bash
docker logs -f nextcloud-app
docker logs -f nextcloud-db
docker exec -u www-data nextcloud-app tail -f /var/www/html/data/nextcloud.log
```
