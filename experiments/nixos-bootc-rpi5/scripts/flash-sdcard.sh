#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/flash-sdcard.sh --image build/out/nixos-bootc-rpi5.img --device /dev/sdX --yes-i-know-this-will-erase

This writes the image to the whole block device. Existing partitions and data on
that device will be destroyed.
EOF
}

image=""
device=""
confirmed=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      image="${2:-}"
      shift 2
      ;;
    --device)
      device="${2:-}"
      shift 2
      ;;
    --yes-i-know-this-will-erase)
      confirmed=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd blockdev
require_cmd dd
require_cmd lsblk
require_cmd partprobe
require_cmd sed
require_cmd stat
require_cmd sync
require_cmd tr
require_cmd umount
require_cmd udevadm

if [[ "$(id -u)" != "0" ]]; then
  echo "run as root so the whole SD block device can be written" >&2
  exit 1
fi

if [[ -z "$image" || -z "$device" || "$confirmed" != "1" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$image" ]]; then
  echo "image does not exist: $image" >&2
  exit 1
fi

if [[ ! -b "$device" ]]; then
  echo "device is not a block device: $device" >&2
  exit 1
fi

dev_type="$(lsblk -dnro TYPE "$device" | head -n 1)"
if [[ "$dev_type" != "disk" ]]; then
  echo "refusing to write non-disk block device $device (TYPE=$dev_type)" >&2
  exit 1
fi

parent_pkname="$(lsblk -dnro PKNAME "$device" | head -n 1)"
if [[ -n "$parent_pkname" ]]; then
  echo "refusing to write partition-like device $device; pass the whole disk" >&2
  exit 1
fi

device_size="$(blockdev --getsize64 "$device")"
image_size="$(stat -c '%s' "$image")"
if (( image_size > device_size )); then
  echo "image is larger than target device" >&2
  echo "image bytes:  $image_size" >&2
  echo "device bytes: $device_size" >&2
  exit 1
fi

echo "Target device:"
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$device"
echo
echo "Writing $image to $device"

while IFS= read -r mountpoint; do
  [[ -n "$mountpoint" ]] || continue
  umount "$mountpoint"
done < <(lsblk -nrpo MOUNTPOINTS "$device" | tr ' ' '\n' | sed '/^$/d')

dd if="$image" of="$device" bs=16M status=progress conv=fsync
sync
udevadm settle || true
partprobe "$device" >/dev/null 2>&1 || true

echo
echo "Flashed device:"
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$device"
