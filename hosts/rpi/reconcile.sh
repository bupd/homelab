#!/usr/bin/env bash
# Runs on a Pi as root, from a staged copy made by deploy.sh:
#   <stage>/root/...      files to install, laid out as their absolute host paths
#   <stage>/retired       optional list of host paths to stop and remove
# Installs what changed, reloads systemd, and restarts only the units affected.

set -Eeuo pipefail

readonly STAGE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly QUADLET_DIR="/etc/containers/systemd"

declare -a changed=()

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || die "run as root"
[[ -d ${STAGE}/root ]] || die "no ${STAGE}/root to install"

mode_for() {
  case "$1" in
    *.env) echo 600 ;;
    *.sh) echo 755 ;;
    *) echo 644 ;;
  esac
}

install_file() {
  local source="$1"
  local destination="$2"

  install -d -m 755 "$(dirname -- "${destination}")"
  if [[ -L ${source} ]]; then
    local target
    target="$(readlink -- "${source}")"
    [[ -L ${destination} && $(readlink -- "${destination}") == "${target}" ]] && return 0
    ln -sfn -- "${target}" "${destination}"
  else
    [[ -f ${destination} ]] && cmp -s "${source}" "${destination}" && return 0
    install -m "$(mode_for "${destination}")" "${source}" "${destination}"
  fi
  changed+=("${destination}")
  log "installed ${destination}"
}

# Secret files are 0600; keep their directories closed too.
lock_secret_dirs() {
  find "${STAGE}/root" -name '*.env' -printf '/%P\n' | xargs -r -n1 dirname | sort -u | xargs -r chmod 700
}

unit_for_quadlet() {
  local name
  name="$(basename -- "$1")"
  case "${name}" in
    *.container) echo "${name%.container}.service" ;;
    *) return 1 ;;
  esac
}

is_oneshot() {
  grep -qx 'Type=oneshot' "$1" 2>/dev/null
}

# Retired .container files: stop the unit, remove the file. Retired .volume files:
# remove the file and delete the podman volume with its data.
retire() {
  [[ -f ${STAGE}/retired ]] || return 0
  local path unit volume
  while IFS= read -r path; do
    [[ -z ${path} || ${path} == \#* ]] && continue
    [[ -e ${path} ]] || continue
    if unit="$(unit_for_quadlet "${path}")"; then
      systemctl stop "${unit}" 2>/dev/null || true
    fi
    if [[ ${path} == *.volume ]]; then
      volume="$(sed -n 's/^VolumeName=//p' "${path}")"
      volume="${volume:-systemd-$(basename -- "${path}" .volume)}"
      systemctl stop "$(basename -- "${path}" .volume)-volume.service" 2>/dev/null || true
      podman volume rm -f "${volume}" >/dev/null 2>&1 && log "deleted volume ${volume}"
    fi
    rm -f -- "${path}"
    changed+=("${path}")
    log "retired ${path}"
  done <"${STAGE}/retired"
}

# The tailnet name follows the OS hostname. Skipped until the node has logged in.
reconcile_tailnet_name() {
  local want have
  want="$(hostnamectl --static)"
  have="$(podman exec tailscale tailscale status --self --peers=false --json 2>/dev/null \
    | sed -n 's/^[[:space:]]*"HostName": "\(.*\)",$/\1/p' | head -n 1)" || return 0
  [[ -n ${have} && ${have} != "${want}" ]] || return 0
  podman exec tailscale tailscale set --hostname="${want}"
  log "tailnet name ${have} -> ${want}"
}

main() {
  local source destination path unit
  declare -A restart=()
  declare -A start=()

  while IFS= read -r -d '' source; do
    destination="/${source#"${STAGE}/root/"}"
    install_file "${source}" "${destination}"
  done < <(find "${STAGE}/root" \( -type f -o -type l \) -print0 | sort -z)
  lock_secret_dirs
  retire

  if [[ ${#changed[@]} -eq 0 ]]; then
    reconcile_tailnet_name
    log "no changes"
    return 0
  fi

  systemctl daemon-reload

  for path in "${changed[@]}"; do
    case "${path}" in
      ${QUADLET_DIR}/*.container)
        [[ -f ${path} ]] || continue
        is_oneshot "${path}" && continue
        unit="$(unit_for_quadlet "${path}")"
        restart["${unit}"]=1
        ;;
      /etc/systemd/system/*.timer)
        start["$(basename -- "${path}")"]=1
        ;;
      ${QUADLET_DIR}/*) ;;
      *)
        # A config or env file changed: restart every long-running container using it.
        while IFS= read -r source; do
          is_oneshot "${source}" && continue
          unit="$(unit_for_quadlet "${source}")" || continue
          restart["${unit}"]=1
        done < <(grep -lF -- "$(dirname -- "${path}")" "${QUADLET_DIR}"/*.container 2>/dev/null || true)
        ;;
    esac
  done

  for unit in "${!start[@]}"; do
    systemctl enable --now "${unit}"
    log "enabled ${unit}"
  done
  for unit in "${!restart[@]}"; do
    systemctl restart "${unit}"
    log "restarted ${unit}"
  done
  reconcile_tailnet_name
}

main "$@"
