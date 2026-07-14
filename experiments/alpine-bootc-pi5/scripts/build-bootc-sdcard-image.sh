#!/usr/bin/env bash
set -euo pipefail

image="${IMAGE:-ghcr.io/bupd/homelab/bootc-alpine-arm64}"
tag="${TAG:-latest}"
target_imgref="${TARGET_IMGREF:-${image}:${tag}}"
out="${OUT:-alpine-bootc-pi5.img}"
size="${SIZE:-16G}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd awk
require_cmd find
require_cmd losetup
require_cmd mkfs.ext4
require_cmd mkfs.vfat
require_cmd parted
require_cmd podman
require_cmd sfdisk
require_cmd tar

if [[ "$(id -u)" != "0" ]]; then
  echo "run as root; bootc install needs a rootful container namespace" >&2
  exit 1
fi

tmp="$(mktemp -d)"
loopdev=""
root_mnt="$tmp/root"
boot_mnt="$tmp/boot"
mkdir -p "$root_mnt" "$boot_mnt"

cleanup() {
  set +e
  mountpoint -q "$root_mnt/boot" && umount "$root_mnt/boot"
  mountpoint -q "$boot_mnt" && umount "$boot_mnt"
  mountpoint -q "$root_mnt" && umount "$root_mnt"
  [[ -n "$loopdev" ]] && losetup -d "$loopdev" >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT

rm -f "$out"
truncate -s "$size" "$out"

parted -s "$out" mklabel msdos
parted -s "$out" mkpart primary fat32 1MiB 513MiB
parted -s "$out" set 1 boot on
parted -s "$out" mkpart primary ext4 513MiB 100%

loopdev="$(losetup --find --show --partscan "$out")"
boot_part="${loopdev}p1"
root_part="${loopdev}p2"
if [[ ! -b "$boot_part" ]]; then
  boot_part="${loopdev}1"
  root_part="${loopdev}2"
fi

udevadm settle || true
mkfs.vfat -F 32 -n BOOT "$boot_part"
mkfs.ext4 -F -L ALPINE_BOOTC "$root_part"

mount "$root_part" "$root_mnt"
mkdir -p "$root_mnt/boot"
mount "$boot_part" "$root_mnt/boot"

echo "== target mounts =="
findmnt -R "$root_mnt"
ls -l "$loopdev" "$boot_part" "$root_part"

podman run --rm --privileged --pid=host \
  --security-opt label=type:unconfined_t \
  --device "$loopdev" \
  --device "$boot_part" \
  --device "$root_part" \
  -v /dev:/dev \
  -v /var/lib/containers:/var/lib/containers \
  -v "$root_mnt:/target" \
  "${image}:${tag}" \
  bootc install to-filesystem \
    --bootloader none \
    --root-mount-spec LABEL=ALPINE_BOOTC \
    --boot-mount-spec LABEL=BOOT \
    --target-imgref "$target_imgref" \
    --skip-fetch-check \
    /target

echo "== bootc-installed filesystem summary =="
find "$root_mnt" -maxdepth 4 \( -type d -o -type l -o -type f \) | sort | sed -n '1,240p'

echo "== boot loader entries =="
find "$root_mnt/boot" -maxdepth 4 -type f -print | sort | while read -r f; do
  case "$f" in
    *.conf|*/cmdline.txt|*/config.txt)
      echo "--- ${f#$root_mnt/boot/} ---"
      sed -n '1,120p' "$f"
      ;;
  esac
done

echo "== installing Raspberry Pi firmware boot files =="
deployment="$(find "$root_mnt/ostree/deploy" -path '*/deploy/*.0' -type d | sort | tail -n 1)"
if [[ -z "$deployment" ]]; then
  echo "could not find bootc deployment under ostree/deploy" >&2
  exit 1
fi

tar --exclude='./boot' -C "$deployment/usr/lib/rpi-boot" -cpf - . | tar -C "$root_mnt/boot" -xpf -

entry="$(find "$root_mnt/boot/loader/entries" -name '*.conf' -type f | sort | tail -n 1 || true)"
if [[ -z "$entry" ]]; then
  echo "bootc did not generate a BLS entry; cannot derive Pi cmdline" >&2
  exit 1
fi

options="$(awk '/^options / { sub(/^options /, ""); print; exit }' "$entry")"
cat > "$root_mnt/boot/config.txt" <<'EOF'
kernel=vmlinuz-rpi
initramfs initramfs-rpi
arm_64bit=1
enable_uart=1
include usercfg.txt
EOF
touch "$root_mnt/boot/usercfg.txt"
printf '%s cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1\n' "$options" > "$root_mnt/boot/cmdline.txt"

sync
umount "$root_mnt/boot"
umount "$root_mnt"
losetup -d "$loopdev"
loopdev=""

sfdisk -d "$out"
ls -lh "$out"
