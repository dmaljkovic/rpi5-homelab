# Pi-hole settings reference

Pi-hole v6 stores its configuration in `/etc/pihole/pihole.toml`. The file is managed by
`pihole-FTL`. Edit it through the web UI when possible, and keep a backup.

## Key values on the live system

```toml
[dns]
  upstreams = [ "127.0.0.1#5335" ]
  port = 53
  listeningMode = "LOCAL"
  dnssec = false
  bogusPriv = true
  domain = "lan"
  localise = true
  queryLogging = true

[dhcp]
  active = false

[webserver]
  domain = "pi.hole"
  port = "80o,443os,[::]:80o,[::]:443os"
  acl = ""
```

## Notes

- `upstreams` points at Unbound on localhost. Do not use a public resolver here if
  Unbound is running.
- `listeningMode = "LOCAL"` answers only clients on directly attached subnets. This is
  safer than `ALL` for a LAN resolver.
- `dnssec = false` is intentional: Unbound validates DNSSEC. See
  [docs/03-dns-pihole-unbound.md](../../docs/03-dns-pihole-unbound.md).
- `dhcp.active = false`: the router is the DHCP server.
- The web server is built into FTL. Apache/nginx are not required for the Pi-hole UI.
- `webserver.port` includes `o` (optional) and `s` (TLS). The TLS certificate is
  self-signed (`CN=pi.hole`).
- Pi-hole also serves NTP (`[ntp]` section) and listens on port 123.

## Blocklists

The gravity database has about 380,333 domains from nine lists:

```text
https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt
https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Spam/hosts
https://adaway.org/hosts.txt
https://v.firebog.net/hosts/AdguardDNS.txt
https://v.firebog.net/hosts/Easyprivacy.txt
https://v.firebog.net/hosts/Prigent-Ads.txt
https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt
https://v.firebog.net/hosts/Prigent-Crypto.txt
```

Manage them in **Settings → Lists** or with `pihole -g`.

## Useful commands

```bash
sudo pihole status
sudo pihole -v
sudo pihole -up
sudo pihole -g
sudo pihole restartdns
sudo pihole setpassword
sudo journalctl -u pihole-FTL -f
```

## Backups

Pi-hole keeps automatic configuration and gravity backups:

```text
/etc/pihole/config_backups
/etc/pihole/gravity_backups
```

For a portable export, use **Settings → Teleporter** in the web UI. The Teleporter
archive contains the configuration and can be imported on a fresh install.
