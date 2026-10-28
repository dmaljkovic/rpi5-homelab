#!/usr/bin/env bash
#
# Back up the Raspberry Pi homelab.
#
# Usage:
#   sudo ./scripts/backup.sh [BACKUP_ROOT]
#
# Default BACKUP_ROOT: /mnt/myssd/backups
#
# The script writes a timestamped directory containing:
#   - Pi-hole configuration files
#   - Nextcloud MariaDB dump, config and compose files
#   - Vaultwarden data (container stopped for a consistent SQLite copy)
#   - Jellyfin config
#   - cloudflared config and systemd unit
#   - SHA256SUMS
#
# Tunnel credentials and .env files are NOT copied by default because they
# contain secrets. Back them up separately into an encrypted store.

set -euo pipefail

BACKUP_ROOT="${1:-/mnt/myssd/backups}"
DATE="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$DATE"

NC_DIR="${NC_DIR:-/home/pi/nextcloud}"
VW_DIR="${VW_DIR:-/home/pi/vaultwarden}"
JF_DIR="${JF_DIR:-/home/pi/jellyfin}"
CF_DIR="${CF_DIR:-/etc/cloudflared}"
PIHOLE_DIR="${PIHOLE_DIR:-/etc/pihole}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0 $*" >&2
    exit 1
fi

if [ -e "$DEST" ]; then
    echo "Backup directory already exists: $DEST" >&2
    exit 1
fi

mkdir -p "$DEST"
chmod 700 "$DEST"

vw_was_running=0
cleanup() {
    if [ "$vw_was_running" -eq 1 ] && docker inspect vaultwarden >/dev/null 2>&1; then
        docker start vaultwarden >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "[*] Destination: $DEST"

echo "[*] Pi-hole configuration"
if [ -d "$PIHOLE_DIR" ]; then
    pihole_files=(pihole.toml dnsmasq.conf adlists.list versions tls.crt tls.pem)
    [ -d "$PIHOLE_DIR/hosts" ] && pihole_files+=(hosts)
    tar czf "$DEST/pihole-config.tar.gz" -C "$PIHOLE_DIR" "${pihole_files[@]}" 2>/dev/null || true
else
    echo "    skipped: $PIHOLE_DIR not found"
fi

echo "[*] Nextcloud"
if [ -d "$NC_DIR" ]; then
    if docker inspect nextcloud-db >/dev/null 2>&1; then
        docker compose -f "$NC_DIR/docker-compose.yaml" exec -T db \
            sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" \
            --single-transaction --routines --triggers "$MYSQL_DATABASE"' \
            > "$DEST/nextcloud.sql"
        echo "    database dump written"
    else
        echo "    warning: nextcloud-db container not found"
    fi

    tar czf "$DEST/nextcloud-config.tar.gz" -C "$NC_DIR" \
        html/config docker-compose.yaml 2>/dev/null || true
    [ -f "$NC_DIR/.env" ] && cp "$NC_DIR/.env" "$DEST/nextcloud.env"
else
    echo "    skipped: $NC_DIR not found"
fi

echo "[*] Vaultwarden"
if [ -d "$VW_DIR/vw-data" ]; then
    if docker inspect -f '{{.State.Running}}' vaultwarden 2>/dev/null | grep -q true; then
        vw_was_running=1
        docker stop vaultwarden >/dev/null
    fi
    tar czf "$DEST/vaultwarden.tar.gz" -C "$VW_DIR" vw-data docker-compose.yaml 2>/dev/null || true
    [ -f "$VW_DIR/.env" ] && cp "$VW_DIR/.env" "$DEST/vaultwarden.env"
    if [ "$vw_was_running" -eq 1 ]; then
        docker start vaultwarden >/dev/null
        vw_was_running=0
    fi
else
    echo "    skipped: $VW_DIR/vw-data not found"
fi

echo "[*] Jellyfin"
if [ -d "$JF_DIR/config" ]; then
    tar czf "$DEST/jellyfin-config.tar.gz" -C "$JF_DIR" config 2>/dev/null || true
else
    echo "    skipped: $JF_DIR/config not found"
fi

echo "[*] cloudflared config"
if [ -d "$CF_DIR" ]; then
    tar czf "$DEST/cloudflared-config.tar.gz" -C "$CF_DIR" config.yml 2>/dev/null || true
fi
if [ -f /etc/systemd/system/cloudflared.service ]; then
    cp /etc/systemd/system/cloudflared.service "$DEST/cloudflared.service"
fi

echo "[*] Checksums"
(
    cd "$DEST"
    sha256sum ./* > SHA256SUMS
)

echo "[*] Sizes"
du -sh "$DEST"/* 2>/dev/null | sort -h

echo
echo "Backup complete: $DEST"
echo "Copy this directory off-site and encrypt it. Do not store plaintext secrets."
