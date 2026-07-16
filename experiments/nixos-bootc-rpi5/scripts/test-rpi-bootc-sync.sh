#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
sync_tool="${project_dir}/rootfs_overlay/usr/local/sbin/rpi-bootc-sync"

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

root="$tmp/root"
boot="$tmp/boot"
mkdir -p \
  "$root/boot/loader/entries" \
  "$root/boot/ostree/test" \
  "$root/usr/lib/rpi-boot/overlays" \
  "$boot"

printf 'kernel\n' > "$root/boot/ostree/test/vmlinuz"
printf 'initramfs\n' > "$root/boot/ostree/test/initramfs.img"
printf 'dtb\n' > "$root/usr/lib/rpi-boot/bcm2712-rpi-5-b.dtb"
printf 'overlay\n' > "$root/usr/lib/rpi-boot/overlays/test.dtbo"

cat > "$root/boot/loader/entries/test.conf" <<'BLS'
title Test bootc
linux /ostree/test/vmlinuz
initrd /ostree/test/initramfs.img
options root=UUID=abc rw ostree=/ostree/boot.1/test quiet
BLS

RPI_BOOTC_EXTRA_CMDLINE="cgroup_enable=memory" \
  "$sync_tool" --root "$root" --boot "$boot"

test -f "$boot/bootc-vmlinuz"
test -f "$boot/bootc-initramfs.img"
test -f "$boot/bcm2712-rpi-5-b.dtb"
test -f "$boot/overlays/test.dtbo"
grep -qx 'kernel=bootc-vmlinuz' "$boot/config.txt"
grep -qx 'initramfs bootc-initramfs.img followkernel' "$boot/config.txt"
grep -qx 'root=UUID=abc rw ostree=/ostree/boot.1/test quiet cgroup_enable=memory' "$boot/cmdline.txt"

echo "rpi-bootc-sync fixture test passed"
