#!/usr/bin/env bash

set -Eeuo pipefail

readonly K3S_IMAGE="docker.io/rancher/k3s:v1.36.2-k3s1"
readonly WORKER_NAME="media-worker"
readonly CONTROL_PLANE_NAME="archbtw"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../../.." && pwd)"
readonly SERVER_CONFIG="${REPO_ROOT}/hosts/homelab/k3s/config.yaml"
readonly SERVER_MODULES="${REPO_ROOT}/hosts/homelab/k3s/modules-load.conf"
readonly SERVER_SYSCTL="${REPO_ROOT}/hosts/homelab/k3s/sysctl.conf"
readonly WORKER_CONFIG="${SCRIPT_DIR}/config.yaml"
readonly WORKER_NETWORK="${SCRIPT_DIR}/media-worker.network"
readonly WORKER_CONTAINER="${SCRIPT_DIR}/media-worker.container"
readonly WORKER_ENSURE_SERVICE="${SCRIPT_DIR}/media-worker-ensure.service"
readonly WORKER_CDI_REFRESH="${SCRIPT_DIR}/refresh-nvidia-cdi.sh"
readonly WORKER_FSTAB="${SCRIPT_DIR}/media-worker.fstab"
readonly WORKER_POLICY="${REPO_ROOT}/clusters/homelab/nodes/media-worker/node-policy.yaml"
readonly K3S_TIME_SYNC_DROPIN_DIR="/etc/systemd/system/k3s.service.d"
readonly K3S_TIME_SYNC_DROPIN="${K3S_TIME_SYNC_DROPIN_DIR}/10-time-sync.conf"
readonly KUBECTL=(k3s kubectl)

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

install_if_changed() {
  local mode="$1"
  local source="$2"
  local destination="$3"

  if [[ ! -f ${destination} ]] || ! cmp -s "${source}" "${destination}"; then
    install -m "${mode}" "${source}" "${destination}"
    return 0
  fi
  return 1
}

reconcile_media_mount() {
  local desired_entry
  local fstab_temp

  desired_entry="$(grep -Ev '^[[:space:]]*(#|$)' "${WORKER_FSTAB}")"
  [[ -n ${desired_entry} ]] || die "${WORKER_FSTAB} has no fstab entry"

  fstab_temp="$(mktemp)"
  awk -v desired="${desired_entry}" '
    BEGIN { replaced = 0 }
    $0 !~ /^[[:space:]]*#/ && $2 == "/home/bupd/hdd/data" {
      if (!replaced) {
        print desired
        replaced = 1
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        print ""
        print "# Homelab media disk (managed by media-worker/reconcile.sh)"
        print desired
      }
    }
  ' /etc/fstab >"${fstab_temp}"

  findmnt --verify --tab-file "${fstab_temp}" >/dev/null || {
    rm -f "${fstab_temp}"
    die "refusing to install an invalid /etc/fstab"
  }

  if ! cmp -s "${fstab_temp}" /etc/fstab; then
    if [[ ! -f /var/backups/homelab/fstab.before-media-worker ]]; then
      install -m 0644 /etc/fstab /var/backups/homelab/fstab.before-media-worker
    fi
    install -m 0644 "${fstab_temp}" /etc/fstab
  fi
  rm -f "${fstab_temp}"
}

reconcile_time_sync_ordering() {
  local dropin_temp

  install -d -m 0755 "${K3S_TIME_SYNC_DROPIN_DIR}"
  dropin_temp="$(mktemp)"
  printf '%s\n' \
    '[Unit]' \
    'Wants=systemd-time-wait-sync.service time-sync.target' \
    'After=systemd-time-wait-sync.service time-sync.target' \
    >"${dropin_temp}"

  if [[ ! -f ${K3S_TIME_SYNC_DROPIN} ]] || \
     ! cmp -s "${dropin_temp}" "${K3S_TIME_SYNC_DROPIN}"; then
    install -m 0644 "${dropin_temp}" "${K3S_TIME_SYNC_DROPIN}"
  fi
  rm -f "${dropin_temp}"

  systemctl enable systemd-time-wait-sync.service >/dev/null
}

wait_for_api() {
  local attempt
  for attempt in {1..120}; do
    if "${KUBECTL[@]}" get --raw=/readyz >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "Kubernetes API did not become ready"
}

wait_for_worker() {
  local attempt
  for attempt in {1..150}; do
    if "${KUBECTL[@]}" get node "${WORKER_NAME}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null | grep -qx True; then
      return 0
    fi
    sleep 2
  done

  journalctl -u media-worker.service -n 100 --no-pager >&2 || true
  die "${WORKER_NAME} did not become Ready"
}

restart_worker() {
  local attempt
  local previous_renew_time
  local renew_time

  previous_renew_time="$("${KUBECTL[@]}" -n kube-node-lease get lease \
    "${WORKER_NAME}" -o jsonpath='{.spec.renewTime}' 2>/dev/null || true)"
  systemctl restart media-worker.service

  for attempt in {1..150}; do
    renew_time="$("${KUBECTL[@]}" -n kube-node-lease get lease \
      "${WORKER_NAME}" -o jsonpath='{.spec.renewTime}' 2>/dev/null || true)"
    if [[ -n ${renew_time} && ${renew_time} != "${previous_renew_time}" ]] && \
       "${KUBECTL[@]}" get node "${WORKER_NAME}" \
         -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
         2>/dev/null | grep -qx True; then
      return 0
    fi
    sleep 2
  done

  journalctl -u media-worker.service -n 100 --no-pager >&2 || true
  die "${WORKER_NAME} did not reconnect after restart"
}

wait_for_core_workloads() {
  local deployment

  for deployment in coredns local-path-provisioner metrics-server; do
    "${KUBECTL[@]}" -n kube-system rollout status \
      "deployment/${deployment}" --timeout=300s
  done

  # A Deployment can briefly retain a stale Available condition while its
  # node is reconnecting. Check the live Pod readiness conditions too.
  "${KUBECTL[@]}" -n kube-system wait --for=condition=Ready \
    pod -l k8s-app=kube-dns --timeout=300s
  "${KUBECTL[@]}" -n kube-system wait --for=condition=Ready \
    pod -l app=local-path-provisioner --timeout=300s
  "${KUBECTL[@]}" -n kube-system wait --for=condition=Ready \
    pod -l k8s-app=metrics-server --timeout=300s
}

remove_control_plane_pods() {
  local attempt

  "${KUBECTL[@]}" delete pods -A \
    --field-selector="spec.nodeName=${CONTROL_PLANE_NAME}" \
    --wait=false >/dev/null 2>&1 || true

  for attempt in {1..60}; do
    if [[ -z $("${KUBECTL[@]}" get pods -A \
      --field-selector="spec.nodeName=${CONTROL_PLANE_NAME}" \
      -o name) ]]; then
      return 0
    fi
    sleep 2
  done

  die "stale Pods assigned to ${CONTROL_PLANE_NAME} were not removed"
}

[[ ${EUID} -eq 0 ]] || die "run this script with sudo"

for command in \
  install cmp mktemp systemctl systemd-analyze podman k3s nvidia-ctk grep \
  awk findmnt mountpoint modprobe sysctl; do
  require_command "${command}"
done

for file in \
  "${SERVER_CONFIG}" \
  "${SERVER_MODULES}" \
  "${SERVER_SYSCTL}" \
  "${WORKER_CONFIG}" \
  "${WORKER_NETWORK}" \
  "${WORKER_CONTAINER}" \
  "${WORKER_ENSURE_SERVICE}" \
  "${WORKER_CDI_REFRESH}" \
  "${WORKER_FSTAB}" \
  "${WORKER_POLICY}"; do
  [[ -f ${file} ]] || die "missing declarative file: ${file}"
done

[[ -r /var/lib/rancher/k3s/server/node-token ]] || \
  die "K3s server token is missing"
systemctl is-active --quiet k3s.service || die "k3s.service is not running"
[[ -d /home/bupd/hdd/data ]] || die "/home/bupd/hdd/data is missing"
[[ $(podman info --format '{{.Host.CgroupsVersion}}') == v2 ]] || \
  die "Podman Quadlet requires cgroup v2"

worker_changed=false
server_changed=false

log "stopping the accidental native K3s agent"
systemctl disable --now k3s-agent.service 2>/dev/null || true

log "installing time-sync ordering"
reconcile_time_sync_ordering

log "creating host directories"
install -d -m 0755 \
  /etc/rancher/k3s-media-worker \
  /var/lib/rancher/k3s-media-worker \
  /var/lib/rancher/k3s-media-worker-kubelet \
  /var/lib/rancher/k3s-media-worker-cni \
  /var/lib/nvidia/k3s-run \
  /var/log/k3s-media-worker \
  /etc/containers/systemd \
  /etc/cdi \
  /usr/local/lib/homelab \
  /var/backups/homelab
install -d -m 0700 /etc/rancher/k3s-media-worker/node

log "reconciling the persistent media disk mount"
reconcile_media_mount
systemctl daemon-reload
systemctl start home-bupd-hdd-data.automount
mountpoint -q /home/bupd/hdd/data || {
  # Accessing an automount path starts the generated mount unit.
  stat /home/bupd/hdd/data >/dev/null
}
mountpoint -q /home/bupd/hdd/data || \
  die "/home/bupd/hdd/data did not mount"

log "installing kernel configuration"
install -m 0644 "${SERVER_MODULES}" /etc/modules-load.d/k3s.conf
install -m 0644 "${SERVER_SYSCTL}" /etc/sysctl.d/90-k3s.conf
modprobe overlay
modprobe br_netfilter
sysctl --system >/dev/null

if [[ -f /etc/rancher/k3s/config.yaml && \
      ! -f /var/backups/homelab/k3s-config.before-agentless.yaml ]]; then
  install -m 0600 /etc/rancher/k3s/config.yaml \
    /var/backups/homelab/k3s-config.before-agentless.yaml
fi

log "installing worker configuration and private token"
if install_if_changed 0600 "${WORKER_CONFIG}" \
  /etc/rancher/k3s-media-worker/config.yaml; then
  worker_changed=true
fi
if install_if_changed 0600 /var/lib/rancher/k3s/server/node-token \
  /etc/rancher/k3s-media-worker/token; then
  worker_changed=true
fi

log "generating NVIDIA CDI configuration"
if install_if_changed 0755 "${WORKER_CDI_REFRESH}" \
  /usr/local/lib/homelab/refresh-nvidia-cdi.sh; then
  worker_changed=true
fi
/usr/local/lib/homelab/refresh-nvidia-cdi.sh
nvidia-ctk cdi list | grep -qx 'nvidia.com/gpu=all' || \
  die "NVIDIA CDI device nvidia.com/gpu=all is unavailable"
for glibc_file in \
  /usr/lib/ld-linux-x86-64.so.2 \
  /usr/lib/libc.so.6 \
  /usr/lib/libpthread.so.0 \
  /usr/lib/libm.so.6 \
  /usr/lib/libdl.so.2 \
  /usr/lib/librt.so.1 \
  /usr/lib/libresolv.so.2 \
  /usr/lib/libcap.so.2 \
  /usr/lib/libelf.so.1 \
  /usr/lib/libtirpc.so.3 \
  /usr/lib/libseccomp.so.2 \
  /usr/lib/libz.so.1 \
  /usr/lib/libzstd.so.1 \
  /usr/lib/libgssapi_krb5.so.2 \
  /usr/lib/libkrb5.so.3 \
  /usr/lib/libk5crypto.so.3 \
  /usr/lib/libcom_err.so.2 \
  /usr/lib/libkrb5support.so.0 \
  /usr/lib/libkeyutils.so.1 \
  /usr/bin/nvidia-container-runtime \
  /usr/bin/nvidia-container-runtime-hook \
  /usr/bin/nvidia-container-cli \
  /usr/bin/nvidia-ctk \
  /usr/lib/libnvidia-container.so.1 \
  /usr/lib/libnvidia-container-go.so.1 \
  /etc/nvidia-container-runtime/config.toml \
  /sbin/ldconfig; do
  [[ -r ${glibc_file} ]] || \
    die "required NVIDIA compatibility runtime file is unavailable: ${glibc_file}"
done

log "installing Podman Quadlet definitions"
if install_if_changed 0644 "${WORKER_NETWORK}" \
  /etc/containers/systemd/media-worker.network; then
  worker_changed=true
fi
if install_if_changed 0644 "${WORKER_CONTAINER}" \
  /etc/containers/systemd/media-worker.container; then
  worker_changed=true
fi
install -m 0644 "${WORKER_ENSURE_SERVICE}" \
  /etc/systemd/system/media-worker-ensure.service

if [[ ! -f /etc/rancher/k3s/config.yaml ]] || \
   ! cmp -s "${SERVER_CONFIG}" /etc/rancher/k3s/config.yaml; then
  server_changed=true
fi

log "pulling the pinned K3s worker image"
podman pull "${K3S_IMAGE}"

log "loading and validating systemd units"
systemctl daemon-reload
[[ -f /run/systemd/generator/media-worker.service ]] || \
  die "Quadlet did not generate media-worker.service"
[[ -f /run/systemd/generator/media-worker-network.service ]] || \
  die "Quadlet did not generate media-worker-network.service"
systemd-analyze verify \
  /run/systemd/generator/media-worker.service \
  /run/systemd/generator/media-worker-network.service \
  /etc/systemd/system/media-worker-ensure.service
[[ "$(systemctl show media-worker.service -p WantedBy --value)" == *multi-user.target* ]] || \
  die "media-worker.service is not linked to multi-user.target"
systemctl enable media-worker-ensure.service

# Older revisions did not persist /etc/rancher/node/password. Recover only
# when the local persistent identity is absent and a stale server identity is
# present. Normal idempotent runs never enter this branch.
if [[ ! -f /etc/rancher/k3s-media-worker/node/password ]] && \
   "${KUBECTL[@]}" -n kube-system get secret \
     "${WORKER_NAME}.node-password.k3s" >/dev/null 2>&1; then
  log "removing the stale non-persistent worker identity"
  systemctl stop media-worker.service 2>/dev/null || true
  "${KUBECTL[@]}" delete node "${WORKER_NAME}" --ignore-not-found
  "${KUBECTL[@]}" -n kube-system delete secret \
    "${WORKER_NAME}.node-password.k3s" --ignore-not-found
  worker_changed=true
fi

if [[ ${worker_changed} == true ]] || \
   ! systemctl is-active --quiet media-worker.service; then
  log "starting ${WORKER_NAME} before removing the control-plane agent"
  restart_worker
else
  log "${WORKER_NAME} configuration is unchanged"
  wait_for_worker
fi

systemctl enable k3s.service
if [[ ${server_changed} == true ]]; then
  log "installing the agentless control-plane configuration"
  install -m 0600 "${SERVER_CONFIG}" /etc/rancher/k3s/config.yaml
  systemctl restart k3s.service
  wait_for_api

  # K3s requires every node to restart after egress-selector-mode changes.
  log "restarting ${WORKER_NAME} against the agentless control plane"
  restart_worker
else
  log "agentless control-plane configuration is unchanged"
fi

log "removing the stale control-plane Node object"
"${KUBECTL[@]}" delete node "${CONTROL_PLANE_NAME}" --ignore-not-found
remove_control_plane_pods

log "applying the declarative worker Node policy"
"${KUBECTL[@]}" apply --server-side \
  --field-manager=homelab-bootstrap \
  -f "${WORKER_POLICY}"

log "waiting for core workloads"
wait_for_core_workloads

log "verifying role segregation"
actual_nodes="$("${KUBECTL[@]}" get nodes \
  -o jsonpath='{.items[*].metadata.name}')"
[[ ${actual_nodes} == "${WORKER_NAME}" ]] || {
  "${KUBECTL[@]}" get nodes -o wide >&2
  die "expected exactly one Kubernetes Node named ${WORKER_NAME}"
}

podman exec "${WORKER_NAME}" test -d /home/bupd/hdd/data || \
  die "media data mount is unavailable inside ${WORKER_NAME}"
podman exec "${WORKER_NAME}" /bin/sh -c \
  'test -c /dev/nvidia0 && ls /usr/lib/libnvidia-encode.so.* >/dev/null' || \
  die "NVIDIA devices or driver libraries are unavailable inside ${WORKER_NAME}"

log "done"
"${KUBECTL[@]}" get nodes -o wide
"${KUBECTL[@]}" get pods -A -o wide
