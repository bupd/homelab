#!/usr/bin/env bash
set -euo pipefail

image_url="${IMAGE_URL:-https://download.fedoraproject.org/pub/alt/iot/44/IoT/aarch64/images/Fedora-IoT-raw-44-20260427.0.aarch64.raw.xz}"
device=""
target="${TARGET:-rpi4}"
hostname="${HOSTNAME:-node2}"
wifi_ssid="${WIFI_SSID:-}"
wifi_psk="${WIFI_PSK:-}"
yes="false"
force="false"

usage() {
  cat <<'EOF'
Usage:
  experiments/fedora-iot-rpi5/scripts/flash-fedora-iot.sh --device /dev/sdX --yes

Options:
  --device PATH       Target SD card block device. This is wiped.
  --image-url URL     Fedora IoT aarch64 raw.xz URL.
  --target NAME       arm-image-installer target. Default: rpi4.
  --hostname NAME     Hostname to write into the image. Default: node2.
  --wifi-ssid SSID    Wi-Fi SSID. Can also use WIFI_SSID.
  --wifi-psk PSK      Wi-Fi password. Can also use WIFI_PSK.
  --yes               Required confirmation for destructive flash.
  --force             Allow non-removable/non-USB target devices.

Environment defaults:
  IMAGE_URL=https://download.fedoraproject.org/pub/alt/iot/44/IoT/aarch64/images/Fedora-IoT-raw-44-20260427.0.aarch64.raw.xz
  TARGET=rpi4
  HOSTNAME=node2
  WIFI_SSID=
  WIFI_PSK=

Notes:
  - This follows the Fedora IoT Raspberry Pi path: official Fedora IoT ARM
    raw image, arm-image-installer, SSH key injection, then NetworkManager
    Wi-Fi profile injection into the OSTree deployment.
  - It does not build ARM images locally.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      device="${2:-}"
      shift 2
      ;;
    --image-url)
      image_url="${2:-}"
      shift 2
      ;;
    --target)
      target="${2:-}"
      shift 2
      ;;
    --hostname)
      hostname="${2:-}"
      shift 2
      ;;
    --wifi-ssid)
      wifi_ssid="${2:-}"
      shift 2
      ;;
    --wifi-psk)
      wifi_psk="${2:-}"
      shift 2
      ;;
    --yes)
      yes="true"
      shift
      ;;
    --force)
      force="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$device" ]] || die "--device is required"
[[ "$yes" == "true" ]] || die "--yes is required because flashing wipes the target"
[[ -b "$device" ]] || die "$device is not a block device"
command -v curl >/dev/null 2>&1 || die "missing curl"
command -v findmnt >/dev/null 2>&1 || die "missing findmnt"
command -v lsblk >/dev/null 2>&1 || die "missing lsblk"
command -v podman >/dev/null 2>&1 || die "missing podman"
command -v sudo >/dev/null 2>&1 || die "missing sudo"

dev_name="$(basename "$device")"
dev_type="$(lsblk -dnro TYPE "$device")"
dev_tran="$(lsblk -dnro TRAN "$device" || true)"
dev_rm="$(lsblk -dnro RM "$device" || true)"
[[ "$dev_type" == "disk" ]] || die "$device is not a whole disk"
if [[ "$force" != "true" && "$dev_rm" != "1" && "$dev_tran" != "usb" ]]; then
  die "$device does not look removable/USB; pass --force only if this is intentional"
fi

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/homelab/fedora-iot-rpi5"
work_dir="$(mktemp -d)"
mnt_dir="$work_dir/root"
keys_file="$work_dir/authorized_keys"
trap 'set +e; mountpoint -q "$mnt_dir" && sudo umount "$mnt_dir"; rm -rf "$work_dir"' EXIT
mkdir -p "$cache_dir" "$mnt_dir"

image_file="$cache_dir/$(basename "$image_url")"
echo "==> target device"
lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,RO,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$device"

echo "==> downloading Fedora IoT image"
curl -L --fail --continue-at - --output "$image_file" "$image_url"

if compgen -G "$HOME/.ssh/*.pub" >/dev/null; then
  cat "$HOME"/.ssh/*.pub > "$keys_file"
else
  die "no public SSH keys found under $HOME/.ssh/*.pub"
fi

echo "==> unmounting existing target partitions"
while read -r mountpoint; do
  [[ -n "$mountpoint" ]] && sudo umount "$mountpoint"
done < <(lsblk -nrpo MOUNTPOINTS "$device" | awk 'NF {print}')

echo "==> flashing with Fedora arm-image-installer"
sudo podman run --rm --privileged \
  -v /dev:/dev \
  -v /run/udev:/run/udev \
  -v "$cache_dir:/images:ro" \
  -v "$keys_file:/authorized_keys:ro" \
  fedora:44 \
  bash -lc '
    set -euo pipefail
    dnf -y -q install arm-image-installer >/dev/null
    arm-image-installer \
      --image="/images/'"$(basename "$image_file")"'" \
      --media="'"$device"'" \
      --addkey=/authorized_keys \
      --norootpass \
      --resizefs \
      --target="'"$target"'" \
      -y
  '

sudo partprobe "$device" || true
sleep 3

root_part="$(lsblk -nrpo PATH,FSTYPE,LABEL "$device" | awk '$2 ~ /^(ext4|xfs|btrfs)$/ {print $1}' | tail -n 1)"
[[ -n "$root_part" ]] || die "could not find root filesystem partition on $device"

echo "==> mounting root partition $root_part"
sudo mount "$root_part" "$mnt_dir"

deploy_dir="$(sudo find "$mnt_dir/ostree/deploy" -mindepth 3 -maxdepth 3 -path '*/deploy/*.0' -type d | sort | tail -n 1 || true)"
[[ -n "$deploy_dir" ]] || die "could not find Fedora IoT OSTree deployment"
etc_dir="$deploy_dir/etc"

echo "==> configuring hostname $hostname"
printf '%s\n' "$hostname" | sudo tee "$etc_dir/hostname" >/dev/null

echo "==> configuring bupd user"
if ! sudo grep -q '^bupd:' "$etc_dir/group"; then
  echo 'bupd:x:1000:' | sudo tee -a "$etc_dir/group" >/dev/null
fi
if sudo grep -q '^wheel:' "$etc_dir/group"; then
  wheel_line="$(sudo awk -F: '$1 == "wheel" {print $4}' "$etc_dir/group")"
  if [[ ",$wheel_line," != *",bupd,"* ]]; then
    if [[ -n "$wheel_line" ]]; then
      sudo sed -i -E 's/^wheel:([^:]*):([^:]*):(.*)$/wheel:\1:\2:\3,bupd/' "$etc_dir/group"
    else
      sudo sed -i -E 's/^wheel:([^:]*):([^:]*):$/wheel:\1:\2:bupd/' "$etc_dir/group"
    fi
  fi
fi
if ! sudo grep -q '^bupd:' "$etc_dir/passwd"; then
  echo 'bupd:x:1000:1000::/var/home/bupd:/bin/bash' | sudo tee -a "$etc_dir/passwd" >/dev/null
fi
if ! sudo grep -q '^bupd:' "$etc_dir/shadow"; then
  echo 'bupd:!!:0:0:99999:7:::' | sudo tee -a "$etc_dir/shadow" >/dev/null
fi
sudo install -d -m 0700 -o 1000 -g 1000 "$mnt_dir/var/home/bupd/.ssh"
sudo install -m 0600 -o 1000 -g 1000 "$keys_file" "$mnt_dir/var/home/bupd/.ssh/authorized_keys"

if [[ -n "$wifi_ssid" && -n "$wifi_psk" ]]; then
  echo "==> configuring NetworkManager Wi-Fi profile $wifi_ssid"
  nm_dir="$etc_dir/NetworkManager/system-connections"
  sudo install -d -m 0700 "$nm_dir"
  sudo tee "$nm_dir/BUPD.nmconnection" >/dev/null <<EOF
[connection]
id=BUPD
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$wifi_ssid

[wifi-security]
key-mgmt=wpa-psk
psk=$wifi_psk

[ipv4]
method=auto

[ipv6]
addr-gen-mode=stable-privacy
method=auto
EOF
  sudo chmod 0600 "$nm_dir/BUPD.nmconnection"
else
  echo "warning: Wi-Fi not configured; pass --wifi-ssid/--wifi-psk or use Ethernet" >&2
fi

echo "==> final sync and unmount"
sync
sudo umount "$mnt_dir"

echo "==> flashed Fedora IoT Raspberry Pi image"
lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,RO,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$device"
