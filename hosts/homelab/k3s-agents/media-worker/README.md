# media-worker

This folder makes one worker named `media-worker`.

## What runs where

- Real host: agentless K3s control plane named `archbtw`.
- Podman container: K3s agent named `media-worker`.
- `media-worker` runs every Pod.
- `archbtw` runs no Pods.

`kubectl get nodes` should show only `media-worker`. That is correct. An
agentless control plane does not create a Kubernetes Node object.

## Files

- `config.yaml`: K3s agent settings and worker labels.
- `media-worker.network`: private Podman network for the worker.
- `media-worker.container`: persistent systemd/Podman worker definition.
- `media-worker.fstab`: persistent media-disk mount with a boot-safe USB timeout.
- `media-worker-ensure.service`: retries worker startup after delayed storage.
- `reconcile.sh`: installs these files and moves Pods off `archbtw` safely.

The script copies the server token into a root-only file. The token is never
written to the repository or OCI artifact.

It installs the checked-in files as follows:

| Repository file | Host path |
| --- | --- |
| `../../k3s/config.yaml` | `/etc/rancher/k3s/config.yaml` |
| `../../k3s/modules-load.conf` | `/etc/modules-load.d/k3s.conf` |
| `../../k3s/sysctl.conf` | `/etc/sysctl.d/90-k3s.conf` |
| `config.yaml` | `/etc/rancher/k3s-media-worker/config.yaml` |
| `media-worker.network` | `/etc/containers/systemd/media-worker.network` |
| `media-worker.container` | `/etc/containers/systemd/media-worker.container` |
| `media-worker.fstab` entry | `/etc/fstab` |
| `media-worker-ensure.service` | `/etc/systemd/system/media-worker-ensure.service` |

Worker state lives at `/var/lib/rancher/k3s-media-worker`. The generated token
copy lives at `/etc/rancher/k3s-media-worker/token` with mode `0600`.
The worker's stable K3s node identity lives under
`/etc/rancher/k3s-media-worker/node`; deleting that directory requires deleting
the matching Kubernetes Node and node-password Secret before rejoining.

The HDD is allowed five minutes to appear during boot because USB disk
enumeration can lag behind the rest of the system. If it misses even that
window, `media-worker-ensure.service` retries every 30 seconds until the mount
dependency and worker both start. The worker's own `Restart=always` policy
handles failures after a successful start.

## Run it

From the repository root:

```bash
sudo hosts/homelab/k3s-agents/media-worker/reconcile.sh
```

Run the same command again after changing one of these files. The script is
idempotent. It expects the homelab to already be running; run homelab up
first when it needs to contact Kubernetes.

## Daily control

The host does not start Kubernetes automatically at boot. The worker Quadlet is
intentionally not linked to a boot target. Use:

    homelab up
    homelab media
    homelab down
    homelab status

Every command is idempotent. Up enables the media automount, mounts the disk,
and starts the control plane and worker. Media starts the homelab, then retains
only Jellyfin, Immich, and their required database, networking, GPU, and core
controllers; it stops automation, observability, Flux, and their extra
Tailscale proxies. Down stops every Pod by stopping the worker first, then
stops the control plane, flushes pending writes, disables the automount, and
cleanly unmounts the media disk.

The existing computer shutdown workflow remains separate:

    powerkill && poweroff

## Storage and GPU

The worker receives:

- `/home/bupd/hdd/data` at the same path, read-write;
- the host kernel modules;
- all NVIDIA devices through CDI; and
- the host NVIDIA Container Toolkit binaries and configuration, read-only; and
- persistent, shared-mount GPU Operator validation state under
  `/var/lib/nvidia/k3s-run`; and
- persistent K3s state under `/var/lib/rancher/k3s-media-worker`.

The Quadlet disables Podman's per-container PID cap because this container is
itself a Kubernetes node. The generated systemd service still applies the
host's `TasksMax`, while nested Pods are governed by Kubernetes resource and
node-pressure controls.

The media disk is NTFS. Put bulk photos, videos, and downloads there. Do not
put databases there. Put databases and application configuration on ext4.

The K3s image is intentionally tiny, so the Quadlet supplies the host glibc
loader and the NVIDIA runtime's required SONAMEs at their standard paths, along
with the host's statically linked `ldconfig`. The Quadlet also mounts the host's
NVIDIA Container Toolkit binaries and configuration read-only, and K3s
auto-detects `/usr/bin/nvidia-container-runtime` at startup. GPU Operator's
toolkit DaemonSet stays disabled because reloading the inner containerd
terminates the all-in-one containerized K3s agent. GPU Operator still owns
discovery, validation, time slicing, and DCGM metrics. Kubernetes Pods request
the GPU through its device plugin and `nvidia.com/gpu`.
