#!/usr/bin/env bash
# Deploys hosts/rpi to a Pi from the workstation:
#   hosts/rpi/deploy.sh rpia          system config only
#   hosts/rpi/deploy.sh rpib --shell  system config, then zsh/nvim for the alarm user
#   hosts/rpi/deploy.sh all
# Stages common/ + <host>/, decrypts secrets with sops locally, streams the stage
# over ssh and runs reconcile.sh on the Pi as root. Plaintext secrets exist only in
# a 0700 temp dir here and in root-only paths on the Pi.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SSH_USER="alarm"
readonly P10K="${HOME}/dotfiles/.p10k.zsh"

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

lan_address() {
  awk -v h="$1" '$1 == h { print $2 }' "${SCRIPT_DIR}/hosts"
}

stage_host() {
  local host="$1"
  local stage="$2"
  local sops_file destination

  mkdir -p "${stage}/root"
  cp -a "${SCRIPT_DIR}/common/root/." "${stage}/root/"
  cp -a "${SCRIPT_DIR}/${host}/root/." "${stage}/root/"
  cp "${SCRIPT_DIR}/reconcile.sh" "${stage}/reconcile.sh"
  [[ -f ${SCRIPT_DIR}/${host}/retired ]] && cp "${SCRIPT_DIR}/${host}/retired" "${stage}/retired"

  [[ -f ${SCRIPT_DIR}/${host}/secrets.map ]] || return 0
  while read -r sops_file destination; do
    [[ -z ${sops_file} || ${sops_file} == \#* ]] && continue
    mkdir -p "${stage}/root$(dirname -- "${destination}")"
    sops -d "${SCRIPT_DIR}/${host}/secrets/${sops_file}" >"${stage}/root${destination}" \
      || die "cannot decrypt ${host}/secrets/${sops_file}"
  done <"${SCRIPT_DIR}/${host}/secrets.map"
}

deploy_system() {
  local host="$1"
  local address="$2"
  local stage

  stage="$(mktemp -d)"
  chmod 700 "${stage}"
  stage_host "${host}" "${stage}" || { rm -rf "${stage}"; die "${host}: staging failed"; }

  log "${host}: reconcile system config"
  tar -C "${stage}" -czf - . | ssh -o BatchMode=yes "${SSH_USER}@${address}" '
    set -e
    d=$(sudo mktemp -d)
    trap "sudo rm -rf \"$d\"" EXIT
    sudo tar -xzf - -C "$d" --no-same-owner
    sudo chown -R root:root "$d"
    sudo bash "$d/reconcile.sh"
  ' || { rm -rf "${stage}"; die "${host}: reconcile failed"; }
  rm -rf "${stage}"
}

deploy_shell() {
  local host="$1"
  local address="$2"

  log "${host}: shell for ${SSH_USER}"
  scp -q "${SCRIPT_DIR}/common/shell/zshrc" "${SSH_USER}@${address}:.zshrc.homelab"
  [[ -f ${P10K} ]] && scp -q "$(readlink -f "${P10K}")" "${SSH_USER}@${address}:.p10k.zsh"
  ssh -o BatchMode=yes "${SSH_USER}@${address}" 'bash -s' <"${SCRIPT_DIR}/common/shell/setup.sh"
}

main() {
  local target="${1:-}"
  local with_shell=false
  local host address
  local -a hosts=()

  [[ -n ${target} ]] || die "usage: $0 <rpia|rpib|all> [--shell]"
  [[ ${2:-} == --shell ]] && with_shell=true
  require_command sops
  require_command ssh

  if [[ ${target} == all ]]; then
    mapfile -t hosts < <(awk '!/^#/ && NF { print $1 }' "${SCRIPT_DIR}/hosts")
  else
    hosts=("${target}")
  fi

  for host in "${hosts[@]}"; do
    [[ -d ${SCRIPT_DIR}/${host} ]] || die "no hosts/rpi/${host}"
    address="$(lan_address "${host}")"
    [[ -n ${address} ]] || die "${host} missing from hosts/rpi/hosts"
    deploy_system "${host}" "${address}"
    if ${with_shell}; then
      deploy_shell "${host}" "${address}"
    fi
  done
}

main "$@"
