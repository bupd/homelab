#!/usr/bin/env bash

set -Eeuo pipefail

readonly cdi_dir=/etc/cdi
readonly cdi_spec="${cdi_dir}/nvidia.yaml"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v nvidia-ctk >/dev/null 2>&1 || die "missing command: nvidia-ctk"
command -v nvidia-smi >/dev/null 2>&1 || die "missing command: nvidia-smi"
[[ ${EUID} -eq 0 ]] || die "run this script as root"

nvidia-smi >/dev/null || die "NVIDIA driver is not ready"
install -d -m 0755 "${cdi_dir}"

temporary_dir="$(mktemp -d)"
temporary="${temporary_dir}/nvidia.yaml"
trap 'rm -f "${temporary}"; rmdir "${temporary_dir}"' EXIT

nvidia-ctk cdi generate --output="${temporary}" >/dev/null
[[ -s ${temporary} ]] || die "NVIDIA CDI generator produced an empty spec"

missing_device=false
while IFS= read -r device_path; do
  if [[ ! -e ${device_path} ]]; then
    printf 'missing generated CDI device node: %s\n' "${device_path}" >&2
    missing_device=true
  fi
done < <(awk '$1 == "-" && $2 == "path:" && $3 ~ /^\/dev\// { print $3 }' "${temporary}")
[[ ${missing_device} == false ]] || die "generated NVIDIA CDI spec references unavailable device nodes"

if ! nvidia-ctk cdi list --spec-dir="${temporary_dir}" | grep -qx 'nvidia.com/gpu=all'; then
  die "generated NVIDIA CDI spec does not expose nvidia.com/gpu=all"
fi

install -m 0644 "${temporary}" "${cdi_spec}"
