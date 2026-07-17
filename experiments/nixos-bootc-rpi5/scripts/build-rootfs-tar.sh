#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
repo_dir="$(cd -- "${project_dir}/../.." && pwd)"

flake_ref="${FLAKE_REF:-${project_dir}#nixosConfigurations.rpi5}"
out="${OUT:-${project_dir}/build/nixos-bootc-rpi5-rootfs.tar}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd cp
require_cmd mkdir
require_cmd nix
require_cmd tar

nix_retry() {
  local attempt
  local max_attempts="${NIX_RETRY_ATTEMPTS:-8}"
  local delay="${NIX_RETRY_DELAY:-20}"

  for attempt in $(seq 1 "$max_attempts"); do
    if nix "$@"; then
      return 0
    fi

    if [ "$attempt" = "$max_attempts" ]; then
      echo "nix $* failed after ${max_attempts} attempts" >&2
      return 1
    fi

    echo "nix $* failed; retrying in ${delay}s (${attempt}/${max_attempts})" >&2
    sleep "$delay"
  done
}

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

root="$tmp/root"
mkdir -p "$root"

echo "==> building NixOS outputs"
toplevel="$(nix_retry build --no-link --print-out-paths "${flake_ref}.config.system.build.toplevel")"
kernel="$(nix_retry build --no-link --print-out-paths "${flake_ref}.config.system.build.kernel")"
initrd="$(nix_retry build --no-link --print-out-paths "${flake_ref}.config.system.build.initialRamdisk")"
firmware="$(nix_retry build --no-link --print-out-paths "${project_dir}#packages.aarch64-linux.rpiFirmware")"

kernel_file="$(nix_retry eval --raw "${flake_ref}.config.system.boot.loader.kernelFile")"
initrd_file="$(nix_retry eval --raw "${flake_ref}.config.system.boot.loader.initrdFile")"
mod_dir_version="$(nix_retry eval --raw "${flake_ref}.config.boot.kernelPackages.kernel.modDirVersion")"

echo "==> collecting closure"
nix_retry path-info -r "$toplevel" "$kernel" "$initrd" "$firmware" > "$tmp/store-paths"
mkdir -p "$root/nix/store"
while IFS= read -r store_path; do
  cp -a --reflink=auto "$store_path" "$root/nix/store/"
done < "$tmp/store-paths"

echo "==> assembling root hierarchy"
mkdir -p \
  "$root/bin" \
  "$root/boot/firmware" \
  "$root/dev" \
  "$root/etc/ssh/authorized_keys.d" \
  "$root/nix/var/nix/gcroots" \
  "$root/nix/var/nix/profiles" \
  "$root/proc" \
  "$root/run" \
  "$root/sbin" \
  "$root/sys" \
  "$root/sysroot" \
  "$root/tmp" \
  "$root/usr/bin" \
  "$root/usr/lib/bootc/kargs.d" \
  "$root/usr/lib/modules/${mod_dir_version}" \
  "$root/usr/lib/ostree" \
  "$root/usr/lib/rpi-boot" \
  "$root/usr/local/bin" \
  "$root/usr/local/sbin" \
  "$root/var/lib/bootsy" \
  "$root/var/home/bupd" \
  "$root/var/lib" \
  "$root/var/log" \
  "$root/var/mnt" \
  "$root/var/opt" \
  "$root/var/roothome" \
  "$root/var/srv" \
  "$root/var/tmp"

chmod 0755 "$root/tmp" "$root/var/tmp"
chmod 0700 "$root/var/roothome"

cp -a "$toplevel/etc/." "$root/etc/"
ln -sfn "$toplevel" "$root/run/current-system"
ln -sfn "$toplevel" "$root/nix/var/nix/profiles/system"
ln -sfn "$toplevel" "$root/nix/var/nix/profiles/system-1-link"
ln -sfn "$toplevel/init" "$root/sbin/init"
ln -sfn "$toplevel/sw/bin/sh" "$root/bin/sh"
ln -sfn "$toplevel/sw/bin/bootc" "$root/usr/bin/bootc"
ln -sfn "$toplevel/sw/bin/env" "$root/usr/bin/env"
ln -sfn sysroot/ostree "$root/ostree"
ln -sfn var/home "$root/home"
ln -sfn var/roothome "$root/root"
ln -sfn var/srv "$root/srv"
ln -sfn var/opt "$root/opt"
ln -sfn var/mnt "$root/mnt"

cp "$kernel/${kernel_file}" "$root/usr/lib/modules/${mod_dir_version}/vmlinuz"
cp "$initrd/${initrd_file}" "$root/usr/lib/modules/${mod_dir_version}/initramfs.img"
cp -a "$firmware/share/raspberrypi/boot/." "$root/usr/lib/rpi-boot/"

cp -a "$project_dir/rootfs_overlay/." "$root/"
chmod 0755 \
  "$root/usr/local/sbin/rpi-bootc-sync" \
  "$root/usr/local/sbin/bootsy-headless-apply" \
  "$root/usr/local/bin/bootsy-beacon" \
  "$root/usr/local/bin/bootsy-reverse-ssh"

cat > "$root/usr/lib/ostree/prepare-root.conf" <<'EOF'
[composefs]
enabled = no

[sysroot]
readonly = true
EOF

cat > "$root/usr/lib/bootc/kargs.d/10-rpi5.toml" <<'EOF'
kargs = ["console=tty1", "console=serial0,115200n8", "ip=dhcp", "boot.shell_on_fail"]
match-architectures = ["aarch64"]
EOF

if [ -n "${BOOTSY_PI_AUTHORIZED_KEYS:-}" ]; then
  printf '%s\n' "$BOOTSY_PI_AUTHORIZED_KEYS" > "$root/etc/ssh/authorized_keys.d/bupd"
  printf '%s\n' "$BOOTSY_PI_AUTHORIZED_KEYS" > "$root/etc/ssh/authorized_keys.d/root"
fi

if [ -n "${BOOTSY_REVERSE_SSH_HOST:-}" ]; then
  {
    printf 'BOOTSY_REVERSE_SSH_ENABLE=1\n'
    printf 'BOOTSY_REVERSE_SSH_HOST=%q\n' "$BOOTSY_REVERSE_SSH_HOST"
    printf 'BOOTSY_REVERSE_SSH_USER=%q\n' "${BOOTSY_REVERSE_SSH_USER:-bupd}"
    printf 'BOOTSY_REVERSE_SSH_PORT=%q\n' "${BOOTSY_REVERSE_SSH_PORT:-22}"
    printf 'BOOTSY_REVERSE_SSH_REMOTE_BIND=%q\n' "${BOOTSY_REVERSE_SSH_REMOTE_BIND:-127.0.0.1}"
    printf 'BOOTSY_REVERSE_SSH_REMOTE_PORT=%q\n' "${BOOTSY_REVERSE_SSH_REMOTE_PORT:-2222}"
    printf 'BOOTSY_REVERSE_SSH_LOCAL_PORT=22\n'
    printf 'BOOTSY_REVERSE_SSH_STRICT_HOST_KEY=%q\n' "${BOOTSY_REVERSE_SSH_STRICT_HOST_KEY:-accept-new}"
    printf 'BOOTSY_REVERSE_SSH_KEY=/boot/firmware/bootsy-reverse-ssh.key\n'
  } > "$root/etc/bootsy/reverse-ssh.env"
fi

mkdir -p "$(dirname "$out")"
tar --numeric-owner --xattrs --acls -C "$root" -cpf "$out" .
echo "wrote $out"
