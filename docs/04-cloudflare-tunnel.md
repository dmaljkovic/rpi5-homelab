# 04 – Cloudflare Tunnel

Cloudflare Tunnel gives public HTTPS access to services on the Pi **without opening any
inbound ports**. `cloudflared` runs on the Pi, makes outbound connections to Cloudflare,
and Cloudflare forwards requests for the configured hostnames over that tunnel.

## How it fits together

```text
User ── HTTPS 443 ──▶ Cloudflare edge (TLS terminated)
                            │
                            │ outbound tunnel (QUIC/HTTP2)
                            ▼
                     cloudflared on Pi
                            │ plain HTTP to localhost
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
        :8082 Nextcloud  :8081 Vaultwarden  :8096 Jellyfin
```

Cloudflare terminates TLS. The origin connections are plain HTTP to `localhost`. This is
why the applications themselves do not need certificates, but also why proxy headers and
`overwriteprotocol` matter (see [05-nextcloud.md](05-nextcloud.md)).

## Installed package

```text
cloudflared version 2026.10.5
```

It was installed from the Cloudflare package (a `.deb` was also downloaded manually
during setup). The service is enabled at boot and managed by systemd.

## Tunnel

The production tunnel is a **named tunnel** with one active connector. It maintains
four connections to Cloudflare edge locations.

Tunnel names and IDs are redacted in this repository. The examples use the name
`pi5-tunnel`.

Two tunnels existed on the account:

- the active tunnel used by the Pi
- an inactive tunnel for another host

Several credential JSON files were also left in `~/.cloudflared/`. Old credentials and
unused tunnels should be removed or rotated.

## Credentials and configuration

| Path | Purpose | Permissions |
| --- | --- | --- |
| `/etc/cloudflared/config.yml` | Ingress rules | `644` |
| `/etc/cloudflared/credentials.json` | Tunnel credentials (secret) | `600 root:root` |
| `~/.cloudflared/cert.pem` | Account certificate for managing tunnels | `600` |
| `~/.cloudflared/*.json` | Tunnel credentials created during setup | `600` |

**Never commit `cert.pem` or any credential JSON to Git.** A tunnel credential is enough
to run the tunnel. If one leaks, delete the tunnel and create a new one.

## Ingress configuration

`/etc/cloudflared/config.yml` (sanitized):

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

The final rule is required: it catches requests for any other hostname and returns 404.

A copy is in
[`configs/cloudflared/config.yml`](../configs/cloudflared/config.yml).

### Port mapping

| Public hostname | Local service | Application |
| --- | --- | --- |
| `cloud.example.com` | `http://localhost:8082` | Nextcloud |
| `vault.example.com` | `http://localhost:8081` | Vaultwarden |
| `media.example.com` | `http://localhost:8096` | Jellyfin |

Vaultwarden's WebSocket port `3012` is **not** exposed through the tunnel. The
`WEBSOCKET_ENABLED=true` setting is present, but the ingress rule only points to the
HTTP port. Notifications therefore fall back to polling. To enable WebSocket, add a
second ingress rule or a path rule for the WebSocket endpoint.

## Systemd unit

The live unit is a custom unit at `/etc/systemd/system/cloudflared.service`:

```ini
[Unit]
Description=cloudflared
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run pi5-tunnel
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

A copy is in
[`configs/cloudflared/cloudflared.service`](../configs/cloudflared/cloudflared.service).

Suggested hardening (test before relying on it):

```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/cloudflared
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
```

`cloudflared` needs to read `/etc/cloudflared`, write little or nothing, and make
outbound network connections. If you add `ProtectSystem=strict`, allow any required
writable paths explicitly.

## Setup procedure

```bash
# 1. Authenticate the machine to the Cloudflare account
cloudflared tunnel login
#    Opens a browser URL and writes ~/.cloudflared/cert.pem

# 2. Create the tunnel
cloudflared tunnel create pi5-tunnel
#    Writes ~/.cloudflared/<TUNNEL-UUID>.json

# 3. Install the credentials where the service can read them
sudo mkdir -p /etc/cloudflared
sudo cp ~/.cloudflared/<TUNNEL-UUID>.json /etc/cloudflared/credentials.json
sudo chown root:root /etc/cloudflared/credentials.json
sudo chmod 600 /etc/cloudflared/credentials.json

# 4. Write /etc/cloudflared/config.yml (see above)

# 5. Create DNS records that point the hostnames at the tunnel
cloudflared tunnel route dns pi5-tunnel cloud.example.com
cloudflared tunnel route dns pi5-tunnel vault.example.com
cloudflared tunnel route dns pi5-tunnel media.example.com

# 6. Install and start the systemd unit
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared
```

If you use `cloudflared service install`, Cloudflare writes its own unit. This machine
uses a custom unit instead, so pick one approach and stick to it.

## Verification

```bash
sudo systemctl status cloudflared
sudo journalctl -u cloudflared -n 50 --no-pager
cloudflared tunnel list
cloudflared tunnel info pi5-tunnel

# From outside the LAN (or through Cloudflare):
curl -I https://cloud.example.com
curl -I https://vault.example.com
curl -I https://media.example.com
```

Observed responses:

```text
https://cloud.example.com  -> 302 (to /login)
https://vault.example.com  -> 200
https://media.example.com  -> 302 (to /web/)
```

The tunnel connector was healthy and connected to four Cloudflare edge nodes.

## Domain migration note

The configuration contains traces of two public domains:

- the current domain, used in `config.yml` and Nextcloud `trusted_domains`
- a previous domain, formerly in Nextcloud `overwrite.cli.url` and still in shell history

The previous domain no longer resolves. This was harmless for the tunnel itself but
caused Nextcloud to generate URLs for a dead hostname. It was fixed on 2026-10-29 as
described in [05-nextcloud.md](05-nextcloud.md); Nextcloud now uses the current domain
over HTTPS.

Also note that DNS route commands in the shell history used the previous domain. When a
domain changes, re-run `cloudflared tunnel route dns` for every hostname and update all
application URL settings.

## Security recommendations

1. **Protect the public hostnames with Cloudflare Access.** Vaultwarden in particular
   should be behind an identity provider, not just a master password. Cloudflare Access
   can require email OTP, GitHub, Google, or a one-time PIN before the request reaches
   the tunnel.
2. **Do not add a catch-all hostname.** Keep the explicit ingress list and the 404
   fallback.
3. **Do not expose the Pi-hole admin UI through the tunnel.** It is a LAN-only service.
4. **Rotate tunnel credentials** if a JSON file or `cert.pem` was ever copied to an
   untrusted location. Delete unused tunnels.
5. **Enable Cloudflare's "Always Use HTTPS"** and HSTS for the zone.
6. **Keep `cloudflared` updated.** It is a network-facing daemon:

   ```bash
   sudo apt update
   sudo apt install --only-upgrade cloudflared
   sudo systemctl restart cloudflared
   ```

7. **Use a separate tunnel per host** if you later add Proxmox or other machines. Do not
   copy credentials between machines.
