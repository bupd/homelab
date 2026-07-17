#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
repo_dir="$(cd -- "${project_dir}/../.." && pwd)"

volume="${NIX_VOLUME:-homelab-nix-aarch64}"
out="${OUT:-${project_dir}/build/out/nixos-bootc-rpi5-rootfs.tar}"
log="${LOG:-${project_dir}/build/local-rootfs-build.log}"
case "$out" in
  "${repo_dir}"/*)
    container_out="/work/${out#"${repo_dir}/"}"
    ;;
  *)
    echo "OUT must be inside the repository so it is visible in the build container: $out" >&2
    exit 1
    ;;
esac

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd mkdir
require_cmd podman

mkdir -p "$(dirname "$out")" "$(dirname "$log")" "${project_dir}/build/tmp"
podman volume exists "$volume" >/dev/null 2>&1 || podman volume create "$volume" >/dev/null

exec podman run --rm \
  --platform linux/arm64 \
  --security-opt seccomp=unconfined \
  -v "${volume}:/nix" \
  -v "${repo_dir}:/work" \
  -w "/work/experiments/nixos-bootc-rpi5" \
  -e "TMPDIR=/work/experiments/nixos-bootc-rpi5/build/tmp" \
  -e "OUT=${container_out}" \
  -e NIX_RETRY_ATTEMPTS="${NIX_RETRY_ATTEMPTS:-3}" \
  -e NIX_RETRY_DELAY="${NIX_RETRY_DELAY:-10}" \
  -e 'NIX_CONFIG=experimental-features = nix-command flakes
substituters = https://cache.nixos.org https://nix-community.cachix.org https://raspberry-pi-nix.cachix.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWfdf4dMRV8U7kNLL5A87L+QuxEFs= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs= raspberry-pi-nix.cachix.org-1:WmV2rdSangxW0rZjY/tBvBDSaNFQ3DyEQsVw8EvHn9o=
extra-platforms = aarch64-linux
sandbox = false
filter-syscalls = false
require-sigs = false
max-jobs = auto' \
  nixos/nix:latest \
  sh -lc 'scripts/build-rootfs-tar.sh 2>&1 | tee build/local-rootfs-build.log'
