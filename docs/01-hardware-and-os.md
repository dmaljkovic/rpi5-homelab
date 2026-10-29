# 01 – Hardware and operating system

## Hardware

| Component | Detail |
| --- | --- |
| Board | Raspberry Pi 5 Model B Rev 1.0 |
| SoC | Broadcom BCM2712, quad-core ARM Cortex-A76 |
| RAM | 8 GB |
| Root storage | 58.2 GB microSD card |
| Data storage | 465.8 GB Crucial P3 Plus NVMe SSD (`CT500P3PSSD8`) |
| Network | On-board Ethernet (Wi-Fi disabled in firmware config) |
| Cooling | Active cooling |
| Temperature | ~52 °C idle |

The SD card holds the OS, Docker images, Nextcloud data and all container metadata.
The NVMe SSD is mounted at `/mnt/myssd` and is used for the Jellyfin media library.

## Operating system

```text
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
VERSION_ID="12"
VERSION_CODENAME=bookworm
ID=debian
Kernel: 6.12.96+rpt-rpi-2712 #1 SMP PREEMPT Debian 1:6.12.96-1+rpt1 (2026-07-24)
Architecture: aarch64
```

This is Raspberry Pi OS (64-bit), Debian 12 based.

## Storage layout

```text
NAME          SIZE MODEL          MOUNTPOINT
mmcblk0      58.2G
├─mmcblk0p1   512M                /boot/firmware
└─mmcblk0p2  57.7G                /
nvme0n1     465.8G CT500P3PSSD8
└─nvme0n1p1 465.8G                /mnt/myssd
```

`/etc/fstab` mounts the SSD by UUID:

```fstab
proc            /proc           proc    defaults          0       0
PARTUUID=315593ec-01  /boot/firmware  vfat    defaults        0       2
PARTUUID=315593ec-02  /               ext4    defaults,noatime  0       1
UUID=22f49eed-6074-43f9-beec-d231927d449d  /mnt/myssd  ext4  defaults  0  2
```

The root filesystem uses `noatime`, which reduces SD-card writes. The SSD uses default
mount options.

## Boot firmware configuration

Relevant non-default lines from `/boot/firmware/config.txt`:

```ini
arm_64bit=1
arm_boost=1
disable_fw_kms_setup=1
dtoverlay=vc4-kms-v3d
dtoverlay=disable-wifi
```

Notes:

- `arm_boost=1` enables the higher clock behaviour supported by the Pi 5.
- `dtoverlay=disable-wifi` disables the on-board Wi-Fi. The machine is wired.
- The desktop stack is installed and running (`lightdm`, VNC). A headless server does
  not need it; it can be disabled to save memory and reduce attack surface.

Kernel command line:

```text
console=serial0,115200 console=tty1 root=PARTUUID=315593ec-02 rootfstype=ext4
fsck.repair=yes rootwait quiet splash plymouth.ignore-serial-consoles
cfg80211.ieee80211_regdom=GB
```

## Installation approach

The system was installed with Raspberry Pi Imager, then configured for headless SSH
access. The exact first-boot settings were not recoverable from the disk, but the
resulting state is:

1. Raspberry Pi OS Lite or Desktop (64-bit), Debian 12 bookworm.
2. Hostname `rpi5`.
3. Admin user `pi` (real username redacted) with sudo.
4. SSH enabled.
5. Ethernet with a static address (see [02-network.md](02-network.md)).
6. NVMe SSD formatted ext4 and mounted at `/mnt/myssd`.
7. Desktop and VNC left enabled.

To reproduce the OS layer:

```bash
# On a fresh Raspberry Pi OS 64-bit install
sudo apt update && sudo apt full-upgrade -y
sudo hostnamectl set-hostname rpi5

# Mount the NVMe SSD by UUID
lsblk -f
sudo mkdir -p /mnt/myssd
# Add the UUID line to /etc/fstab, then:
sudo systemctl daemon-reload
sudo mount -a
```

## Maintenance notes

- **EEPROM update available.** `rpi-eeprom-update` reports an update.
  Apply it during a maintenance window:

  ```bash
  sudo rpi-eeprom-update
  sudo rpi-eeprom-update -a
  sudo reboot
  ```

- **SD card wear.** Nextcloud data lives on the SD card. Consider moving
  `/home/pi/nextcloud/html/data` (or the whole `html` volume) to the NVMe SSD and
  keeping only the OS on the SD card.
- **Thermals.** Check temperature and throttling:

  ```bash
  vcgencmd measure_temp
  vcgencmd get_throttled   # 0x0 means no throttling
  ```

- **Disk health.** Install `smartmontools` and monitor the NVMe:

  ```bash
  sudo apt install smartmontools
  sudo smartctl -H /dev/nvme0n1
  sudo smartctl -a /dev/nvme0n1
  ```
