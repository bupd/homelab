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
written to Git.

It installs the checked-in files as follows:

| Git file | Host path |
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
sudo hosts/instance1/k3s-agents/media-worker/reconcile.sh
```

Run the same command again after changing one of these files. The script is
idempotent.

## Storage and GPU

The worker receives:

- `/home/bupd/hdd/data` at the same path, read-write;
- the host kernel modules;
- all NVIDIA devices through CDI; and
- persistent K3s state under `/var/lib/rancher/k3s-media-worker`.

The media disk is NTFS. Put bulk photos, videos, and downloads there. Do not
put databases there. Put databases and application configuration on ext4.

The K3s image is intentionally tiny and cannot execute the host's dynamically
linked `nvidia-smi`. The reconcile script instead checks that NVIDIA device
nodes and driver libraries reached the worker. Kubernetes Pods still need the
declaratively installed NVIDIA GPU Operator/device plugin before they can
request `nvidia.com/gpu`.
