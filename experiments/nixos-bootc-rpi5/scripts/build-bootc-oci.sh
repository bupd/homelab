#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"

rootfs_tar="${ROOTFS_TAR:-${project_dir}/build/out/nixos-bootc-rpi5-rootfs.tar}"
work_dir="${WORK_DIR:-${project_dir}/build/bootc-oci-work}"
rootfs_dir="${ROOTFS_DIR:-${work_dir}/rootfs}"
ostree_repo="${OSTREE_REPO:-${work_dir}/ostree-repo}"
oci_dir="${OCI_DIR:-${project_dir}/build/out/nixos-bootc-rpi5-oci}"
image="${IMAGE:-localhost/nixos-bootc-rpi5}"
tag="${TAG:-local}"
target_imgref="${TARGET_IMGREF:-${image}:${tag}}"
load_containers_storage="${BOOTC_LOAD_CONTAINERS_STORAGE:-0}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd awk
require_cmd cargo
require_cmd find
require_cmd jq
require_cmd ostree
require_cmd rm
require_cmd sha256sum
require_cmd skopeo
require_cmd stat
require_cmd tar

if [[ "$(id -u)" != "0" ]]; then
  echo "run as root; preserving the rootfs ownership and xattrs needs root" >&2
  exit 1
fi

case "$rootfs_dir" in
  "$project_dir"/build/*) ;;
  *) echo "refusing to remove ROOTFS_DIR outside project build dir: $rootfs_dir" >&2; exit 1 ;;
esac

case "$oci_dir" in
  "$project_dir"/build/*) ;;
  *) echo "refusing to remove OCI_DIR outside project build dir: $oci_dir" >&2; exit 1 ;;
esac

rewrite_oci_platform() {
  local oci="$1"
  local arch="$2"
  local os="$3"
  local index="$oci/index.json"
  local old_manifest_digest manifest_path old_config_digest config_path
  local tmp new_config_digest new_config_size new_manifest_digest new_manifest_size

  old_manifest_digest="$(jq -r '.manifests[0].digest' "$index")"
  manifest_path="$oci/blobs/sha256/${old_manifest_digest#sha256:}"
  old_config_digest="$(jq -r '.config.digest' "$manifest_path")"
  config_path="$oci/blobs/sha256/${old_config_digest#sha256:}"

  tmp="$(mktemp)"
  jq --arg arch "$arch" --arg os "$os" '.architecture = $arch | .os = $os' "$config_path" > "$tmp"
  new_config_digest="sha256:$(sha256sum "$tmp" | awk '{print $1}')"
  new_config_size="$(stat -c '%s' "$tmp")"
  mv "$tmp" "$oci/blobs/sha256/${new_config_digest#sha256:}"

  tmp="$(mktemp)"
  jq \
    --arg digest "$new_config_digest" \
    --argjson size "$new_config_size" \
    '.config.digest = $digest | .config.size = $size' \
    "$manifest_path" > "$tmp"
  new_manifest_digest="sha256:$(sha256sum "$tmp" | awk '{print $1}')"
  new_manifest_size="$(stat -c '%s' "$tmp")"
  mv "$tmp" "$oci/blobs/sha256/${new_manifest_digest#sha256:}"

  tmp="$(mktemp)"
  jq \
    --arg old_digest "$old_manifest_digest" \
    --arg new_digest "$new_manifest_digest" \
    --argjson new_size "$new_manifest_size" \
    --arg arch "$arch" \
    --arg os "$os" \
    '(.manifests[] | select(.digest == $old_digest)) |=
      (.digest = $new_digest | .size = $new_size | .platform.architecture = $arch | .platform.os = $os)' \
    "$index" > "$tmp"
  mv "$tmp" "$index"
}

rm -rf "$rootfs_dir" "$ostree_repo" "$oci_dir"
mkdir -p "$rootfs_dir" "$ostree_repo" "$(dirname "$oci_dir")"

echo "==> extracting NixOS rootfs"
tar --numeric-owner --xattrs --acls -C "$rootfs_dir" -xf "$rootfs_tar"
rm -rf "$rootfs_dir/etc"

kernel_version="$(find "$rootfs_dir/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1)"

echo "==> committing rootfs to OSTree"
ostree init --repo="$ostree_repo" --mode=archive
ostree commit \
  --repo="$ostree_repo" \
  --branch=nixos/bootc/rpi5 \
  --subject="NixOS bootc Raspberry Pi 5" \
  --bootable \
  --add-metadata-string="ostree.linux=${kernel_version}" \
  --tree=dir="$rootfs_dir"
commit="$(ostree rev-parse --repo="$ostree_repo" nixos/bootc/rpi5)"

echo "==> encapsulating OSTree commit as bootc OCI image"
cargo run --manifest-path "$project_dir/tools/ostree-encapsulate/Cargo.toml" -- \
  --repo "$ostree_repo" \
  --ref "$commit" \
  --dest "oci:${oci_dir}:${tag}" \
  --label containers.bootc=1 \
  --label ostree.bootable=true \
  --label org.opencontainers.image.title=nixos-bootc-rpi5 \
  --label org.opencontainers.image.description="Experimental NixOS bootc image for Raspberry Pi 5" \
  --cmd /sbin/init

echo "==> setting OCI platform to linux/arm64"
rewrite_oci_platform "$oci_dir" arm64 linux

echo "==> validating bootc image metadata"
skopeo inspect --override-os linux --override-arch arm64 \
  "oci:${oci_dir}:${tag}" |
  jq -e '
    .Architecture == "arm64" and
    .Os == "linux" and
    .Labels["containers.bootc"] == "1" and
    (.Labels["ostree.commit"] | type == "string") and
    (.Labels["ostree.final-diffid"] | type == "string")
  ' >/dev/null

skopeo inspect --override-os linux --override-arch arm64 \
  "oci:${oci_dir}:${tag}" |
  jq '{Name, Digest, Architecture, Os, Labels: .Labels}'

if [[ "$load_containers_storage" == "1" || "$load_containers_storage" == "true" ]]; then
  echo "==> loading bootc OCI image into containers-storage"
  skopeo copy --insecure-policy \
    "oci:${oci_dir}:${tag}" \
    "containers-storage:${target_imgref}"
fi

echo "bootc source image: oci:${oci_dir}:${tag}"
