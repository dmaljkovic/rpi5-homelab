#!/usr/bin/env bash
#
# Quick health check for the Raspberry Pi homelab.
# Run as the admin user; no root required for the read-only checks.
#
# Environment overrides:
#   NEXTCLOUD_HOST, VAULTWARDEN_HOST, JELLYFIN_HOST
#   DNS_TEST_DOMAIN (default: cloudflare.com)
#   DNSSEC_FAIL_DOMAIN (default: dnssec-failed.org)

set -uo pipefail

NEXTCLOUD_HOST="${NEXTCLOUD_HOST:-cloud.example.com}"
VAULTWARDEN_HOST="${VAULTWARDEN_HOST:-vault.example.com}"
JELLYFIN_HOST="${JELLYFIN_HOST:-media.example.com}"
DNS_TEST_DOMAIN="${DNS_TEST_DOMAIN:-cloudflare.com}"
DNSSEC_FAIL_DOMAIN="${DNSSEC_FAIL_DOMAIN:-dnssec-failed.org}"

failures=0

ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; failures=$((failures + 1)); }

need() {
    command -v "$1" >/dev/null 2>&1 || { fail "missing command: $1"; return 1; }
}

echo "== System =="
if [ -r /proc/device-tree/model ]; then
    printf '  %s\n' "$(tr -d '\0' </proc/device-tree/model)"
fi
printf '  uptime: %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  kernel: %s\n' "$(uname -r)"

temp=""
if command -v vcgencmd >/dev/null 2>&1; then
    temp="$(vcgencmd measure_temp 2>/dev/null | tr -dc '0-9.')"
    [ -n "$temp" ] && printf '  temperature: %s C\n' "$temp"
    throttled="$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)"
    if [ -n "$throttled" ] && [ "$throttled" != "0x0" ]; then
        warn "throttling flags: $throttled"
    fi
fi

echo "== Disk =="
root_use="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
root_avail="$(df -h / | awk 'NR==2 {print $4}')"
printf '  / usage: %s%% (available %s)\n' "$root_use" "$root_avail"
if [ "${root_use:-0}" -ge 90 ]; then
    fail "root filesystem is ${root_use}% full"
elif [ "${root_use:-0}" -ge 80 ]; then
    warn "root filesystem is ${root_use}% full"
else
    ok "root filesystem has space"
fi

if findmnt -rn /mnt/myssd >/dev/null 2>&1; then
    ok "NVMe mounted at /mnt/myssd"
else
    warn "/mnt/myssd is not mounted"
fi

echo "== Services =="
for svc in pihole-FTL unbound cloudflared docker; do
    if systemctl is-active --quiet "$svc"; then
        ok "$svc is active"
    else
        fail "$svc is not active"
    fi
done

echo "== DNS =="
if need dig; then
    pihole_answer="$(dig +short "$DNS_TEST_DOMAIN" @127.0.0.1 2>/dev/null)"
    if [ -n "$pihole_answer" ]; then
        ok "Pi-hole resolves $DNS_TEST_DOMAIN"
    else
        fail "Pi-hole cannot resolve $DNS_TEST_DOMAIN"
    fi

    unbound_answer="$(dig +short "$DNS_TEST_DOMAIN" @127.0.0.1 -p 5335 2>/dev/null)"
    if [ -n "$unbound_answer" ]; then
        ok "Unbound resolves $DNS_TEST_DOMAIN on 5335"
    else
        fail "Unbound cannot resolve $DNS_TEST_DOMAIN on 5335"
    fi

    dnssec_status="$(dig +noall +comments "$DNSSEC_FAIL_DOMAIN" @127.0.0.1 2>/dev/null | awk '/status:/ {print $6}' | tr -d ',')"
    if [ "$dnssec_status" = "SERVFAIL" ]; then
        ok "DNSSEC validation rejects $DNSSEC_FAIL_DOMAIN"
    else
        fail "DNSSEC validation did not reject $DNSSEC_FAIL_DOMAIN (status=${dnssec_status:-unknown})"
    fi
fi

echo "== Containers =="
if command -v docker >/dev/null 2>&1; then
    for c in nextcloud-app nextcloud-db vaultwarden jellyfin; do
        if ! docker inspect "$c" >/dev/null 2>&1; then
            fail "container $c not found"
            continue
        fi
        running="$(docker inspect -f '{{.State.Running}}' "$c")"
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c")"
        if [ "$running" != "true" ]; then
            fail "container $c is not running"
        elif [ "$health" = "unhealthy" ]; then
            fail "container $c is unhealthy"
        else
            ok "container $c running (health: $health)"
        fi
    done
else
    warn "docker command not available"
fi

echo "== Public endpoints =="
if need curl; then
    for host in "$NEXTCLOUD_HOST" "$VAULTWARDEN_HOST" "$JELLYFIN_HOST"; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host" 2>/dev/null || true)"
        case "$code" in
            200|301|302|303|307|308) ok "https://$host -> $code" ;;
            000|"") fail "https://$host is unreachable" ;;
            *) warn "https://$host -> $code" ;;
        esac
    done
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "Result: OK"
    exit 0
fi

echo "Result: $failures check(s) failed"
exit 1
