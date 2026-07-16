#!/usr/bin/env bash
set -euo pipefail

tarball="${1:-build/nixos-bootc-rpi5-rootfs.tar}"
test -f "$tarball"

tar -tf "$tarball" | grep -qx './sbin/init'
tar -tf "$tarball" | grep -qx './usr/local/sbin/rpi-bootc-sync'
tar -tf "$tarball" | grep -qx './usr/local/sbin/bootsy-headless-apply'
tar -tf "$tarball" | grep -qx './usr/local/bin/bootsy-reverse-ssh'
tar -tf "$tarball" | grep -qx './etc/bootsy/reverse-ssh.env'
tar -tf "$tarball" | grep -q '^./nix/store/.*/init$'
tar -tf "$tarball" | grep -q '^./nix/store/.*/etc/os-release$'
tar -tf "$tarball" | grep -q '^./usr/lib/modules/.*/vmlinuz$'
tar -tf "$tarball" | grep -q '^./usr/lib/modules/.*/initramfs.img$'
tar -tf "$tarball" | grep -q '^./usr/lib/rpi-boot/.*bcm2712.*\.dtb$'

echo "nixos bootc rootfs layout test passed"
