#!/usr/bin/env bash
set -euo pipefail

tarball="${1:-build/nixos-bootc-rpi5-rootfs.tar}"
test -f "$tarball"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

tar -tf "$tarball" > "$tmp"

grep -qx './sbin/init' "$tmp"
grep -qx './usr/local/sbin/rpi-bootc-sync' "$tmp"
grep -qx './usr/local/sbin/bootsy-headless-apply' "$tmp"
grep -qx './usr/local/bin/bootsy-reverse-ssh' "$tmp"
grep -qx './etc/bootsy/reverse-ssh.env' "$tmp"
grep -q '^./nix/store/.*/init$' "$tmp"
grep -q '^./nix/store/.*/etc/os-release$' "$tmp"
grep -q '^./usr/lib/modules/.*/vmlinuz$' "$tmp"
grep -q '^./usr/lib/modules/.*/initramfs.img$' "$tmp"
grep -q '^./usr/lib/rpi-boot/.*bcm2712.*\.dtb$' "$tmp"

echo "nixos bootc rootfs layout test passed"
