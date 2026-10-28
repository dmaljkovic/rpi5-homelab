# 06 – Vaultwarden

Vaultwarden is a lightweight, Bitwarden-compatible password manager written in Rust. It
runs in a single Docker container with SQLite storage and is published through the
Cloudflare Tunnel at `vault.example.com`.

## Current deployment

| Item | Value |
| --- | --- |
| Vaultwarden | 1.37.1 |
| Web vault | 2026.6.4 |
| Image | `vaultwarden/server:latest` |
| Container | `vaultwarden` |
| Restart policy | `unless-stopped` |
| HTTP port | `127.0.0.1:8081 -> 80/tcp` |
| WebSocket port | `127.0.0.1:3012 -> 3012/tcp` |
| Data | `/home/pi/vaultwarden/vw-data` (bind mount) |
| Public URL | `https://vault.example.com` |
| Health | healthy at scan |

The service is bound to `127.0.0.1`, so it is not reachable directly from the LAN. The
only path in is through `cloudflared`.

## Compose file

The live file is `/home/pi/vaultwarden/docker-compose.yaml`. A sanitized version is in
[`configs/vaultwarden/docker-compose.yaml`](../configs/vaultwarden/docker-compose.yaml).

Important settings:

| Setting | Value | Meaning |
| --- | --- | --- |
| `DOMAIN` | `https://vault.example.com` | Public URL used in emails and WebAuthn |
| `WEBSOCKET_ENABLED` | `true` | Enable live sync notifications |
| `SIGNUPS_ALLOWED` | `false` | No new accounts after the initial one |
| `ADMIN_TOKEN` | secret | Protects the `/admin` page |
| `ROCKET_PORT` | `80` | HTTP listen port inside the container |
| `ROCKET_WORKERS` | `10` | Worker threads |

## The config-precedence trap

At scan time the container logged:

```text
[WARNING] The following environment variables are being overridden by the config.json file.
[WARNING] Please use the admin panel to make changes to them:
[WARNING] DOMAIN, SIGNUPS_ALLOWED, ADMIN_TOKEN
```

Vaultwarden saves settings to `vw-data/config.json` when you change them in the admin
panel. **Values in `config.json` take precedence over environment variables in
`docker-compose.yaml`.** This means editing `DOMAIN`, `SIGNUPS_ALLOWED` or `ADMIN_TOKEN`
in the compose file and restarting may have no effect.

Inspect the file:

```bash
sudo cat /home/pi/vaultwarden/vw-data/config.json | \
  sed -E 's/("admin_token"\s*:\s*")[^"]*/\1REDACTED/'
```

Choose one source of truth:

- manage everything through the admin panel and leave the compose file minimal, or
- remove the relevant keys from `config.json` and manage them via env vars.

Do not set them in both places and expect the compose file to win.

## Admin token

The admin token was stored in plaintext. Vaultwarden supports an Argon2 PHC hash, which
is preferable because a plaintext token in a compose file or backup is immediately
usable.

Generate a hash inside the container:

```bash
docker exec -it vaultwarden /vaultwarden hash
# Enter the admin password when prompted, copy the $argon2... output
```

Then set the hashed value as `ADMIN_TOKEN` (in `config.json` or the compose file,
whichever is authoritative) and restart:

```bash
docker compose restart vaultwarden
```

The admin page is at `https://vault.example.com/admin`. Consider restricting it with
Cloudflare Access as well.

## Data and backup

Everything lives in `vw-data`:

```text
config.json          settings (may override env vars)
db.sqlite3           accounts, vault items, attachments metadata
db.sqlite3-wal       write-ahead log
db.sqlite3-shm       shared memory
rsa_key.pem          JWT signing key
icon_cache/          cached site icons
```

Two manual backups existed:

```text
vw-data-backup-2025-09-01
vw-data-backup-20260817-204625
```

There is no automatic backup job. See [09-backup-and-recovery.md](09-backup-and-recovery.md).

Because SQLite uses a WAL, copying `db.sqlite3` while the container is running can
produce an inconsistent snapshot. Safer options:

```bash
# Option A: stop, copy, start
docker stop vaultwarden
sudo tar czf /mnt/myssd/backups/vaultwarden-$(date +%F).tar.gz \
  -C /home/pi/vaultwarden vw-data
docker start vaultwarden

# Option B: use SQLite's online backup if sqlite3 is available
sqlite3 /home/pi/vaultwarden/vw-data/db.sqlite3 \
  ".backup '/mnt/myssd/backups/vaultwarden-$(date +%F).sqlite3'"
```

Also back up `config.json` and `rsa_key.pem`. Losing `rsa_key.pem` invalidates sessions.

## WebSocket / live sync

`WEBSOCKET_ENABLED=true` is set and port `3012` is published to localhost, but the
Cloudflare ingress only forwards `https://vault.example.com` to `http://localhost:8081`.
The WebSocket endpoint on `3012` is **not** reachable through the tunnel. Clients will
still sync, but may fall back to polling.

To enable live sync through Cloudflare, add a path rule such as:

```yaml
ingress:
  - hostname: vault.example.com
    path: /notifications/hub
    service: http://localhost:3012
  - hostname: vault.example.com
    path: /notifications/hub/negotiate
    service: http://localhost:8081
  - hostname: vault.example.com
    service: http://localhost:8081
```

Cloudflare supports WebSockets over tunnels. Verify with the browser developer tools
that the WebSocket connection succeeds after the change.

## Updating Vaultwarden

```bash
cd /home/pi/vaultwarden

# 1. Back up
docker stop vaultwarden
sudo tar czf /mnt/myssd/backups/vaultwarden-$(date +%F).tar.gz -C /home/pi/vaultwarden vw-data
docker start vaultwarden

# 2. Pull and recreate
docker compose pull
docker compose up -d

# 3. Verify
docker ps --filter name=vaultwarden
docker logs --tail 50 vaultwarden
curl -I https://vault.example.com
```

The `latest` tag means updates are pulled without an explicit version. Consider pinning a
known-good tag and updating deliberately.

## Security notes

- Bind to `127.0.0.1` only, as done here. Never publish port 8081 on `0.0.0.0`.
- Keep `SIGNUPS_ALLOWED=false` after creating your account.
- Use a strong master password and enable 2FA in the web vault.
- Put `vault.example.com` behind Cloudflare Access or another identity-aware proxy.
- Back up `rsa_key.pem`; it is required for existing sessions and some encrypted data.
- Do not commit `vw-data`, `config.json`, `rsa_key.pem` or the admin token.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| 502 from Cloudflare | Is the container running? Is `cloudflared` running? |
| Admin page 404/403 | Is `ADMIN_TOKEN` set? Did `config.json` override it? |
| No live sync | WebSocket path/port not routed through the tunnel |
| Login works but attachments fail | Check storage mount and permissions on `vw-data` |
| Settings changes ignored | `config.json` overrides environment variables |
