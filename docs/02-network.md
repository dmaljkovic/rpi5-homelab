# 02 – Network layout

## Topology

```text
                    ┌─────────────────────────────┐
   Internet ────────│ Router 192.168.1.1          │
                    │ DHCP server, IPv6 RA        │
                    └──────────────┬──────────────┘
                                   │ Ethernet
                    ┌──────────────┴──────────────┐
                    │ Raspberry Pi 5               │
                    │ 192.168.1.10 (static)        │
                    │                              │
                    │ Pi-hole :53                  │
                    │ Pi-hole web :80/:443         │
                    │ Docker services :8081/8082   │
                    │ Jellyfin :8096               │
                    └──────────────┬──────────────┘
                                   │ outbound only
                    ┌──────────────┴──────────────┐
                    │ Cloudflare Tunnel            │
                    │ cloudflared                  │
                    └─────────────────────────────┘
```

## Addressing

The Pi uses a **static IPv4 address** configured in NetworkManager, not a DHCP
reservation:

```text
connection.id:   Wired connection 1
ipv4.method:     manual
ipv4.addresses:  192.168.1.10/24
ipv4.gateway:    192.168.1.1
ipv4.dns:        192.168.1.10
ipv6.method:     auto
```

The gateway is the router. The Pi points its own resolver at Pi-hole, which is itself.
IPv6 uses SLAAC and the ISP/ router-advertised prefix.

Inspect the live values with:

```bash
nmcli -f connection.id,ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv6.method \
  connection show "Wired connection 1"
ip -brief addr
ip route
```

To recreate the static profile on a fresh install:

```bash
sudo nmcli connection modify "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.10/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns 192.168.1.10 \
  ipv6.method auto
sudo nmcli connection up "Wired connection 1"
```

An equivalent keyfile example is in
[`configs/network/01-rpi5-static.nmconnection.example`](../configs/network/01-rpi5-static.nmconnection.example).

## DHCP

DHCP is **not** handled by Pi-hole. In `/etc/pihole/pihole.toml`:

```toml
[dhcp]
  active = false
```

The router remains the DHCP server. Only the DNS server advertised to clients was
changed to `192.168.1.10`. This is the simplest and least invasive setup, but it means
Pi-hole cannot automatically register client hostnames from DHCP leases. Reverse lookups
for LAN clients are limited unless conditional forwarding is configured.

If you want Pi-hole to be the DHCP server later:

1. Disable DHCP on the router.
2. Enable DHCP in Pi-hole and set the range, gateway and lease time.
3. Renew leases on clients.

## DNS resolution path

```text
Client
  │  UDP/TCP 53
  ▼
Pi-hole FTL (192.168.1.10:53)
  │  local blocklists, cache, local DNS
  │  127.0.0.1#5335
  ▼
Unbound (127.0.0.1:5335)
  │  DNSSEC validation
  │  DNS-over-TLS 853
  ▼
Cloudflare 1.1.1.1 / 1.0.0.1
```

Pi-hole's own `/etc/resolv.conf` points to `192.168.1.10` first, then IPv6 addresses
advertised by the router. This is normal for a host that uses itself as its resolver,
but it is worth knowing during troubleshooting: breaking Pi-hole can break the Pi's own
name resolution.

Test from the Pi:

```bash
dig +short cloudflare.com @127.0.0.1
dig +noall +comments dnssec-failed.org @127.0.0.1 | grep status
```

Expected: `cloudflare.com` resolves, `dnssec-failed.org` returns `SERVFAIL`.

## Listening ports

| Proto | Port | Process | Scope | Purpose |
| --- | --- | --- | --- | --- |
| TCP | 22 | `sshd` | all | SSH |
| TCP/UDP | 53 | `pihole-FTL` | all | DNS (IPv4 + IPv6) |
| TCP | 80 | `pihole-FTL` | all | Pi-hole web UI / redirect |
| TCP | 443 | `pihole-FTL` | all | Pi-hole web UI (self-signed TLS) |
| TCP/UDP | 123 | `pihole-FTL` | all | NTP server |
| TCP | 8081 | Docker proxy | 127.0.0.1 | Vaultwarden HTTP |
| TCP | 3012 | Docker proxy | 127.0.0.1 | Vaultwarden WebSocket |
| TCP | 8082 | Docker proxy | all | Nextcloud HTTP |
| TCP | 8096 | `jellyfin` | all | Jellyfin HTTP |
| UDP | 7359 | `jellyfin` | all | Jellyfin client discovery |
| TCP | 5900 | `vncserver-x11-c` | all | VNC desktop |
| TCP | 21 | `vsftpd` | all | FTP |
| TCP | 631 | `cupsd` | localhost | CUPS |
| UDP | 5353 | `avahi-daemon` | all | mDNS |

Notes:

- Nextcloud is published on all interfaces (`0.0.0.0:8082`), even though public access
  should go through the tunnel. Binding it to `127.0.0.1:8082` would prevent direct LAN
  access and reduce exposure.
- Vaultwarden is correctly bound to `127.0.0.1`.
- Jellyfin uses `network_mode: host`, so it listens directly on `8096` and `7359`.
- VNC and FTP are not required for the documented stack.

## Firewall

There is **no UFW** and no custom host firewall:

```text
ufw status -> no-ufw
```

The only nftables rules present were created by Docker for container NAT and isolation.
This is acceptable while the router does not forward inbound ports, but a host firewall
is still recommended to limit LAN exposure of SSH, VNC, FTP and the Docker-published
ports.

Example UFW policy that keeps the stack usable:

```bash
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 53
sudo ufw allow from 192.168.1.0/24 to any port 80,443 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 8096 proto tcp
sudo ufw enable
```

Do **not** expose port 53 to the internet. Pi-hole is configured with
`listeningMode = "LOCAL"`, which only answers clients on directly attached subnets, but
an open resolver is still a real risk if the firewall or router is misconfigured.

## Router configuration

Changes required on the router:

1. Reserve or statically assign `192.168.1.10` to the Pi (the Pi also sets it statically,
   so a reservation avoids duplicate assignments).
2. Set the LAN DHCP DNS server to `192.168.1.10`.
3. Do **not** forward any inbound ports to the Pi.
4. Leave DHCP enabled on the router unless you deliberately migrate it to Pi-hole.

## Public DNS and TLS

The three public names are proxied by Cloudflare and resolve to Cloudflare anycast
addresses. TLS is terminated at Cloudflare; the origin only speaks HTTP on localhost.
See [04-cloudflare-tunnel.md](04-cloudflare-tunnel.md).
