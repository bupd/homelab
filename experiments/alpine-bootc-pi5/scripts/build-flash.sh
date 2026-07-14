#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"

image="${IMAGE:-localhost/alpine-bootc-pi5}"
tag="${TAG:-latest}"
platform="${PLATFORM:-linux/arm64}"
device=""
yes="0"
force="0"
action="${1:-}"
wifi_ssid="${WIFI_SSID:-}"
wifi_psk="${WIFI_PSK:-}"

usage() {
  cat <<'EOF'
Usage:
  scripts/build-flash.sh build
  scripts/build-flash.sh smoke
  scripts/build-flash.sh flash --device /dev/sdX --yes
  scripts/build-flash.sh all --device /dev/sdX --yes

Environment:
  IMAGE=localhost/alpine-bootc-pi5
  TAG=latest
  PLATFORM=linux/arm64
  WIFI_SSID='BUPD'
  WIFI_PSK='...'

Notes:
  - flash wipes the target device.
  - this is the first Alpine+bootc Pi 5 experiment: it flashes a Pi boot
    partition plus an Alpine rootfs that contains bootc, Podman, K3s,
    Tailscale, Cloudflared, Wi-Fi config, and OpenRC services.
EOF
}

parse_args() {
  action="${1:-}"
  if [[ -z "${action}" || "${action}" == "-h" || "${action}" == "--help" ]]; then
    usage
    exit 0
  fi
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        device="${2:-}"
        shift 2
        ;;
      --yes|-y)
        yes="1"
        shift
        ;;
      --force)
        force="1"
        shift
        ;;
      --wifi-ssid)
        wifi_ssid="${2:-}"
        shift 2
        ;;
      --wifi-psk)
        wifi_psk="${2:-}"
        shift 2
        ;;
      *)
        echo "unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

part_path() {
  local dev="$1"
  local n="$2"
  if [[ "$dev" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$dev" "$n"
  else
    printf '%s%s\n' "$dev" "$n"
  fi
}

check_tools() {
  require_cmd podman
  require_cmd jq
  require_cmd lsblk
  require_cmd findmnt
  require_cmd tar
}

check_arm64() {
  echo "==> checking ARM64 emulation"
  podman run --rm --arch arm64 alpine:3.23 uname -m | grep -qx aarch64
}

build_image() {
  check_tools
  check_arm64
  echo "==> building ${image}:${tag} for ${platform}"
  cd "$project_dir"
  podman build --platform "$platform" -t "${image}:${tag}" -f Containerfile .
}

smoke_image() {
  check_tools
  echo "==> smoke testing ${image}:${tag}"
  podman run --rm --platform "$platform" --privileged "${image}:${tag}" sh -lc '
    set -eux
    test -x /usr/bin/bootc
    bootc --version
    test -d /usr/lib/rpi-boot
    test -f /usr/lib/rpi-boot/vmlinuz-rpi
    test -f /usr/lib/rpi-boot/initramfs-rpi
    test -f /etc/wpa_supplicant/wpa_supplicant.conf
    test -f /etc/init.d/k3s
    command -v podman
    command -v k3s
    command -v tailscale
    command -v cloudflared
  '
}

ensure_flash_ok() {
  [[ -n "$device" ]] || {
    echo "--device is required for flash/all" >&2
    exit 2
  }
  [[ -b "$device" ]] || {
    echo "not a block device: $device" >&2
    exit 2
  }
  [[ "$yes" == "1" ]] || {
    echo "refusing to wipe $device without --yes" >&2
    exit 2
  }

  local rmflag
  rmflag="$(lsblk -dn -o RM "$device" | tr -d ' ')"
  if [[ "$rmflag" != "1" && "$force" != "1" ]]; then
    echo "$device is not marked removable; pass --force if this is intentional" >&2
    exit 2
  fi

  echo "==> target device"
  lsblk -o NAME,PATH,MODEL,SERIAL,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,RM,HOTPLUG "$device"
}

unmount_device() {
  echo "==> unmounting existing mounts on $device"
  while read -r mountpoint; do
    [[ -n "$mountpoint" ]] && sudo umount "$mountpoint"
  done < <(lsblk -nrpo MOUNTPOINT "$device" | awk 'NF')
}

flash_device() {
  check_tools
  require_cmd parted
  require_cmd mkfs.vfat
  require_cmd mkfs.ext4
  require_cmd wipefs
  require_cmd partprobe
  if [[ -n "$wifi_ssid" || -n "$wifi_psk" ]]; then
    require_cmd wpa_passphrase
  fi
  ensure_flash_ok
  smoke_image

  local boot_part root_part
  boot_part="$(part_path "$device" 1)"
  root_part="$(part_path "$device" 2)"
  tmp="$(mktemp -d)"
  boot_mnt="$tmp/boot"
  root_mnt="$tmp/root"
  cid=""
  mkdir -p "$boot_mnt" "$root_mnt"

  cleanup() {
    set +e
    [[ -n "${cid:-}" ]] && podman rm -f "$cid" >/dev/null 2>&1
    mountpoint -q "$boot_mnt" && sudo umount "$boot_mnt"
    mountpoint -q "$root_mnt" && sudo umount "$root_mnt"
    rm -rf "$tmp"
  }
  trap cleanup EXIT

  unmount_device

  echo "==> wiping and partitioning $device"
  sudo wipefs -a "$device"
  sudo parted -s "$device" mklabel msdos
  sudo parted -s "$device" mkpart primary fat32 1MiB 513MiB
  sudo parted -s "$device" set 1 boot on
  sudo parted -s "$device" mkpart primary ext4 513MiB 100%
  sudo partprobe "$device" || true
  command -v udevadm >/dev/null 2>&1 && sudo udevadm settle || true
  sleep 2
  unmount_device

  echo "==> formatting"
  sudo mkfs.vfat -F 32 -n BOOT "$boot_part"
  sudo mkfs.ext4 -F -L ALPINE_BOOTC "$root_part"
  command -v udevadm >/dev/null 2>&1 && sudo udevadm settle || true
  sleep 1
  unmount_device

  sudo mount "$root_part" "$root_mnt"
  sudo mount "$boot_part" "$boot_mnt"

  echo "==> exporting rootfs from ${image}:${tag}"
  cid="$(podman create --platform "$platform" "${image}:${tag}" /bin/true)"
  podman export "$cid" | sudo tar --numeric-owner -xpf - -C "$root_mnt"
  podman rm "$cid" >/dev/null
  cid=""

  echo "==> installing Raspberry Pi boot files"
  sudo tar --exclude='./boot' -C "$root_mnt/usr/lib/rpi-boot" -cpf - . | sudo tar -C "$boot_mnt" -xpf -
  sudo tee "$boot_mnt/config.txt" >/dev/null <<'EOF'
kernel=vmlinuz-rpi
initramfs initramfs-rpi
arm_64bit=1
enable_uart=1
include usercfg.txt
EOF
  sudo touch "$boot_mnt/usercfg.txt"
  sudo tee "$boot_mnt/cmdline.txt" >/dev/null <<'EOF'
root=LABEL=ALPINE_BOOTC modules=sd-mod,usb-storage,ext4 quiet rootfstype=ext4 cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
EOF

  echo "==> configuring fstab and SSH authorized_keys"
  sudo tee "$root_mnt/etc/fstab" >/dev/null <<'EOF'
LABEL=ALPINE_BOOTC / ext4 rw,relatime 0 1
LABEL=BOOT /boot vfat rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,errors=remount-ro 0 2
tmpfs /tmp tmpfs nosuid,nodev 0 0
EOF

  sudo install -d -m 0700 -o 1000 -g 1000 "$root_mnt/var/home/bupd/.ssh"
  if compgen -G "$HOME/.ssh/*.pub" >/dev/null; then
    cat "$HOME"/.ssh/*.pub | sudo tee "$root_mnt/var/home/bupd/.ssh/authorized_keys" >/dev/null
    sudo chown 1000:1000 "$root_mnt/var/home/bupd/.ssh/authorized_keys"
    sudo chmod 0600 "$root_mnt/var/home/bupd/.ssh/authorized_keys"
  else
    echo "warning: no $HOME/.ssh/*.pub keys found; SSH password auth is disabled" >&2
  fi

  if [[ -n "$wifi_ssid" && -n "$wifi_psk" ]]; then
    echo "==> configuring Wi-Fi network ${wifi_ssid}"
    local wifi_hash
    wifi_hash="$(wpa_passphrase "$wifi_ssid" "$wifi_psk" | awk -F= '/^[[:space:]]*psk=[0-9a-f]+$/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    sudo install -d -m 0755 "$root_mnt/etc/wpa_supplicant"
    sudo tee "$root_mnt/etc/wpa_supplicant/wpa_supplicant.conf" >/dev/null <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=wheel
update_config=0
country=IN

network={
    ssid="${wifi_ssid}"
    psk=${wifi_hash}
    key_mgmt=WPA-PSK
    priority=10
}
EOF
  else
    echo "warning: Wi-Fi not configured; set WIFI_SSID/WIFI_PSK or pass --wifi-ssid/--wifi-psk" >&2
  fi

  echo "==> final sync"
  sync
  sudo umount "$boot_mnt"
  sudo umount "$root_mnt"
  trap - EXIT
  rm -rf "$tmp"

  echo "==> flashed $device"
}

parse_args "$@"

case "$action" in
  build)
    build_image
    ;;
  smoke)
    smoke_image
    ;;
  flash)
    flash_device
    ;;
  all)
    build_image
    flash_device
    ;;
  *)
    echo "unknown action: $action" >&2
    usage
    exit 2
    ;;
esac
