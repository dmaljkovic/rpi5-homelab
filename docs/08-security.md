# 08 – Security review and hardening

This is a pragmatic review of the live system, not a formal audit. The stack is a
personal homelab exposed through Cloudflare Tunnel; the goal is to reduce obvious risk
without breaking the setup.

## Findings

| # | Severity | Finding | Evidence | Recommended fix |
| --- | --- | --- | --- | --- |
| 1 | High | SSH accepts passwords | `sshd` offers `publickey,password` | Install keys, set `PasswordAuthentication no`, keep console access |
| 2 | High | Vaultwarden admin token stored in plaintext | `ADMIN_TOKEN` in compose / `config.json` | Use an Argon2 hash, move to a root-only env file, rotate |
| 3 | High | No off-site backup for Nextcloud/Vaultwarden | Only manual local copies found | Implement 3-2-1 backups and test restores |
| 4 | Medium | Nextcloud proxy/URL configuration is wrong | `overwrite.cli.url` uses old domain + `http://`; no `trusted_proxies` | Set canonical HTTPS URL and trusted proxy |
| 5 | Medium | VNC desktop exposed on the LAN | `vncserver-x11` on `0.0.0.0:5900` | Disable if unused, or bind to localhost / tunnel |
| 6 | Medium | Plain FTP server running | `vsftpd` on `0.0.0.0:21` | Disable if unused; use SFTP instead |
| 7 | Medium | No host firewall | UFW absent; only Docker nftables rules | Add UFW/nftables rules for LAN-only services |
| 8 | Medium | Containers use `:latest` tags | All four images | Pin versions and update deliberately |
| 9 | Medium | Nextcloud data on SD card | `/home/pi/nextcloud/html` on `mmcblk0` | Move data to NVMe, keep OS on SD |
| 10 | Low | Pi-hole web UI uses self-signed cert | `CN=pi.hole`, valid to 2055 | Trust the cert or use a local CA |
| 11 | Low | Pi-hole and EEPROM updates pending | Core 6.4.3 vs 6.5; EEPROM update available | Schedule updates |
| 12 | Low | Old tunnel credentials and unused tunnel remain | Multiple JSON files, inactive Proxmox tunnel | Delete unused tunnels/credentials |
| 13 | Low | Cloudflared unit has no hardening | Plain systemd unit | Add `NoNewPrivileges`, `ProtectSystem`, etc. |
| 14 | Low | Nextcloud background jobs use AJAX | `backgroundjobs_mode` unset, no cron | Switch to cron |
| 15 | Low | WebSocket not routed through tunnel | Only `:8081` in ingress, `:3012` local only | Add path rules if live sync is wanted |

## Priority actions

### P1 – do these first

1. **Harden SSH.**

   ```bash
   # From your workstation, install your key first
   ssh-copy-id -i ~/.ssh/id_ed25519.pub pi@192.168.1.10

   # On the Pi, test key login, then edit:
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

   Keep an existing session open until you have verified key login in a second terminal.
   If you lock yourself out, use the console or a recovery mount.

2. **Hash and rotate the Vaultwarden admin token.**

   ```bash
   docker exec -it vaultwarden /vaultwarden hash
   ```

   Put the `$argon2...` value in the authoritative config, restart, and confirm the old
   token no longer works. Store the plaintext only in your password manager.

3. **Set up backups today.** See [09-backup-and-recovery.md](09-backup-and-recovery.md).
   At minimum, copy `vw-data`, the Nextcloud database dump and `html/config` to the NVMe
   and to another machine.

### P2 – next maintenance window

4. **Fix Nextcloud URL and proxy settings.** See [05-nextcloud.md](05-nextcloud.md).
5. **Disable unused services.**

   ```bash
   sudo systemctl disable --now vsftpd
   sudo systemctl disable --now vncserver-x11-serviced
   # If you need the desktop, at least do not expose it to the LAN.
   ```

6. **Add a host firewall** (example in [02-network.md](02-network.md)).
7. **Pin container image versions** in the compose files, for example
   `nextcloud:32.0.1`, `mariadb:10.6.24`, `vaultwarden:1.37.1`,
   `jellyfin/jellyfin:10.10.7`.
8. **Put public services behind Cloudflare Access**, especially Vaultwarden. A password
   manager login page should not be reachable by the whole internet without an extra
   identity layer.

### P3 – nice to have

9. Update Pi-hole and the Pi EEPROM.
10. Move Nextcloud data and Jellyfin metadata to the NVMe.
11. Add systemd hardening to `cloudflared`.
12. Add monitoring (disk, temperature, certificate expiry, container health).
13. Replace the Pi-hole self-signed certificate with a locally trusted one.

## What is already good

- **No inbound ports are forwarded.** Public access is outbound-only through
  `cloudflared`.
- **Vaultwarden is bound to localhost**, not to `0.0.0.0`.
- **Pi-hole listens in `LOCAL` mode**, not as an open resolver.
- **DNSSEC validation is active** in Unbound.
- **Tunnel credentials are mode `600`** and owned by root.
- **Signups are disabled** in Vaultwarden.
- **The database is not published** outside the Docker network.
- **The media disk is separate** from the OS disk.
- **The system has been stable** (57 days uptime, no throttling).

## Secrets inventory

These files contain credentials and must never be committed:

| Path | Contains |
| --- | --- |
| `/etc/cloudflared/credentials.json` | Tunnel credential |
| `/home/pi/.cloudflared/cert.pem` | Cloudflare account certificate |
| `/home/pi/.cloudflared/*.json` | Tunnel credentials |
| `/home/pi/nextcloud/docker-compose.yaml` | DB passwords (in the live version) |
| `/home/pi/nextcloud/html/config/config.php` | DB password, instance secret |
| `/home/pi/vaultwarden/docker-compose.yaml` | Admin token |
| `/home/pi/vaultwarden/vw-data/config.json` | Admin token, settings |
| `/home/pi/vaultwarden/vw-data/rsa_key.pem` | JWT signing key |
| `/home/pi/.smbcredentials` | SMB credentials |
| `/etc/pihole/cli_pw` | Pi-hole CLI password |
| `/etc/pihole/tls.pem` | Pi-hole TLS private key |
| `~/.ssh/id_*` | SSH private keys |

The repository uses placeholders and `.gitignore` rules to keep these out. Before every
commit, run:

```bash
git diff --cached
grep -RInE '(password|token|secret|BEGIN .*PRIVATE KEY)' .
```

## Cloudflare-specific hardening

- Enable **Always Use HTTPS** and **HSTS** for the zone.
- Enable **Cloudflare Access** for `vault.example.com` and, if desired, the other
  hostnames.
- Set a **WAF** rule or rate limit on login endpoints.
- Do not create DNS records for the Pi's LAN address.
- Do not enable "Argo Tunnel" fallback or a catch-all ingress rule.
- Review the tunnel's connectors periodically and delete unused tunnels.

## SSH and account hygiene

- One admin user with sudo is enough. Avoid enabling root login.
- Use key-based SSH and a passphrase-protected key.
- Consider `fail2ban` if SSH must remain exposed on the LAN.
- Keep the Pi's OS and containers patched.
- Unattended upgrades are reasonable for security updates on a homelab:

  ```bash
  sudo apt install unattended-upgrades
  sudo dpkg-reconfigure --priority=low unattended-upgrades
  ```

  Exclude Docker and Pi-hole if you prefer to update them manually.

## Physical and network security

- The Pi and its SD card/NVMe are physically accessible; full-disk encryption is not
  configured. Treat physical access as compromise.
- The router should not forward any ports to the Pi. Verify from an external network.
- Guest Wi-Fi should not be able to reach the Pi's management ports.
- Keep the Cloudflare account protected with a strong password and 2FA.
