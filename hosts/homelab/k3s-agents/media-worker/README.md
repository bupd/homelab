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
idempotent.

## Storage and GPU

The worker receives:

- `/home/bupd/hdd/data` at the same path, read-write;
- the host kernel modules;
- all NVIDIA devices through CDI; and
- host libraries at the isolated, read-only `/usr/local/nvidia/host-libs`
  compatibility path for the injected NVIDIA tools; and
- persistent GPU Operator toolkit files under `/var/lib/nvidia/k3s-toolkit`; and
- persistent GPU Operator validation state under `/var/lib/nvidia/k3s-run`; and
- persistent K3s state under `/var/lib/rancher/k3s-media-worker`.

The media disk is NTFS. Put bulk photos, videos, and downloads there. Do not
put databases there. Put databases and application configuration on ext4.

The K3s image is intentionally tiny, so the Quadlet supplies the host glibc
loader plus an isolated, read-only host-library path required by CDI-injected
NVIDIA tools. The NVIDIA runtime's OCI hooks do not inherit that library path,
so their required SONAMEs are additionally mounted read-only at the standard
paths they expect, along with the host's statically linked `ldconfig`. This lets
GPU Operator validate the pre-installed host driver without installing another
driver inside the worker. The NVIDIA runtime binary, validation markers, and
K3s containerd drop-in survive worker restarts; this prevents GPU Operator from
treating every nested-worker restart as a fresh runtime installation. K3s
imports the drop-in from its persistent agent state when it starts. Kubernetes
Pods request the GPU through the declaratively installed NVIDIA GPU
Operator/device plugin and `nvidia.com/gpu`.
