#!/usr/bin/env bash
set -euo pipefail

image="${IMAGE:-ghcr.io/bupd/homelab/nixos-bootc-rpi5}"
tag="${TAG:-latest}"
target_imgref="${TARGET_IMGREF:-${image}:${tag}}"
out="${OUT:-nixos-bootc-rpi5.img}"
size="${SIZE:-3900M}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd awk
require_cmd blkid
require_cmd find
require_cmd losetup
require_cmd lsblk
require_cmd mkfs.ext4
require_cmd mkfs.vfat
require_cmd parted
require_cmd podman
require_cmd sfdisk

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
  mountpoint -q "$root_mnt/boot/firmware" && umount "$root_mnt/boot/firmware"
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
mkfs.ext4 -F -L NIXOS_BOOTC "$root_part"
root_uuid="$(blkid -s UUID -o value "$root_part")"

mount "$root_part" "$root_mnt"

majmin() {
  lsblk -nro MAJ:MIN "$1" | head -n 1
}

loop_majmin="$(majmin "$loopdev")"
boot_majmin="$(majmin "$boot_part")"
root_majmin="$(majmin "$root_part")"
udev_mount=()
if [[ -d /run/udev ]]; then
  udev_mount=(-v /run/udev:/run/udev:ro)
fi

podman run --rm --privileged --pid=host \
  --security-opt label=type:unconfined_t \
  --device "$loopdev" \
  --device "$boot_part" \
  --device "$root_part" \
  -e LOOPDEV="$loopdev" \
  -e BOOT_PART="$boot_part" \
  -e ROOT_PART="$root_part" \
  -e LOOP_MAJOR="${loop_majmin%:*}" \
  -e LOOP_MINOR="${loop_majmin#*:}" \
  -e BOOT_MAJOR="${boot_majmin%:*}" \
  -e BOOT_MINOR="${boot_majmin#*:}" \
  -e ROOT_MAJOR="${root_majmin%:*}" \
  -e ROOT_MINOR="${root_majmin#*:}" \
  -e ROOT_UUID="$root_uuid" \
  -e TARGET_IMGREF="$target_imgref" \
  -e RUST_BACKTRACE=1 \
  -e RUST_LOG="${RUST_LOG:-debug}" \
  -v /dev:/dev \
  -v /sys:/sys:ro \
  "${udev_mount[@]}" \
  -v /var/lib/containers:/var/lib/containers \
  -v "$root_mnt:/target" \
  "${image}:${tag}" \
  /bin/sh -euxc '
    ensure_block_node() {
      path="$1"
      major="$2"
      minor="$3"
      if [ ! -b "$path" ]; then
        rm -f "$path"
        mknod "$path" b "$major" "$minor"
      fi
    }

    ensure_block_node "$LOOPDEV" "$LOOP_MAJOR" "$LOOP_MINOR"
    ensure_block_node "$BOOT_PART" "$BOOT_MAJOR" "$BOOT_MINOR"
    ensure_block_node "$ROOT_PART" "$ROOT_MAJOR" "$ROOT_MINOR"
    bootc --version

    bootc install to-filesystem \
      --bootloader none \
      --root-mount-spec "UUID=$ROOT_UUID" \
      --target-imgref "$TARGET_IMGREF" \
      --skip-fetch-check \
      /target
  '

echo "== installing Raspberry Pi firmware boot files =="
mount "$boot_part" "$boot_mnt"

deployment="$(find "$root_mnt/ostree/deploy" -mindepth 3 -maxdepth 3 -path '*/deploy/*.0' -type d | sort | tail -n 1)"
if [[ -z "$deployment" ]]; then
  echo "could not find bootc deployment under ostree/deploy" >&2
  exit 1
fi

sync_tool="$deployment/usr/local/sbin/rpi-bootc-sync"
if [[ ! -x "$sync_tool" ]]; then
  echo "deployment does not contain executable rpi-bootc-sync: $sync_tool" >&2
  exit 1
fi

RPI_BOOTC_EXTRA_CMDLINE="cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1" \
  "$sync_tool" --root "$root_mnt" --boot "$boot_mnt"

touch "$boot_mnt/ssh"

if [[ "${BOOTSY_REVERSE_SSH_ENABLE:-1}" == "1" || "${BOOTSY_REVERSE_SSH_ENABLE:-1}" == "true" ]]; then
  {
    printf 'BOOTSY_REVERSE_SSH_ENABLE=1\n'
    printf 'BOOTSY_REVERSE_SSH_HOST=%q\n' "${BOOTSY_REVERSE_SSH_HOST:-}"
    printf 'BOOTSY_REVERSE_SSH_USER=%q\n' "${BOOTSY_REVERSE_SSH_USER:-}"
    printf 'BOOTSY_REVERSE_SSH_PORT=%q\n' "${BOOTSY_REVERSE_SSH_PORT:-22}"
    printf 'BOOTSY_REVERSE_SSH_REMOTE_BIND=%q\n' "${BOOTSY_REVERSE_SSH_REMOTE_BIND:-127.0.0.1}"
    printf 'BOOTSY_REVERSE_SSH_REMOTE_PORT=%q\n' "${BOOTSY_REVERSE_SSH_REMOTE_PORT:-2222}"
    printf 'BOOTSY_REVERSE_SSH_LOCAL_PORT=%q\n' "${BOOTSY_REVERSE_SSH_LOCAL_PORT:-22}"
    printf 'BOOTSY_REVERSE_SSH_STRICT_HOST_KEY=%q\n' "${BOOTSY_REVERSE_SSH_STRICT_HOST_KEY:-accept-new}"
    printf 'BOOTSY_REVERSE_SSH_KEY=/boot/firmware/bootsy-reverse-ssh.key\n'
    printf 'BOOTSY_BEACON_URL=%q\n' "${BOOTSY_BEACON_URL:-}"
    printf 'BOOTSY_BEACON_UDP_HOST=%q\n' "${BOOTSY_BEACON_UDP_HOST:-}"
    printf 'BOOTSY_BEACON_UDP_PORT=%q\n' "${BOOTSY_BEACON_UDP_PORT:-5514}"
  } > "$boot_mnt/bootsy-debug.env"
fi

if [[ -n "${BOOTSY_REVERSE_SSH_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$BOOTSY_REVERSE_SSH_PRIVATE_KEY" > "$boot_mnt/bootsy-reverse-ssh.key"
fi

if [[ -n "${BOOTSY_PI_AUTHORIZED_KEYS:-}" ]]; then
  printf '%s\n' "$BOOTSY_PI_AUTHORIZED_KEYS" > "$boot_mnt/authorized_keys"
fi

if [[ -n "${BOOTSY_PI_USERCONF:-}" ]]; then
  printf '%s\n' "$BOOTSY_PI_USERCONF" > "$boot_mnt/userconf.txt"
fi

sync
umount "$boot_mnt"
umount "$root_mnt"
losetup -d "$loopdev"
loopdev=""

sfdisk -d "$out"
ls -lh "$out"
