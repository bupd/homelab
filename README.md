# Homelab

One K3s control plane, one media worker, and FluxCD deploying media apps from a
public GHCR OCI artifact.

## The simple picture

```text
archbtw                       media-worker
K3s API + datastore           Kubernetes Pods
no application Pods           Immich + PostgreSQL + Valkey
        |                             ^
        +---------- schedules --------+

GitHub push -> ghcr.io/bupd/homelab/cluster:latest -> Flux -> cluster
```

Flux is installed once in the cluster. Do not install Flux on every worker.
When another worker joins K3s, the existing Flux controllers can manage it.

## Before you start

Run these steps on `archbtw` from the repository root unless a step says
otherwise.

You need:

- Arch Linux with a working NVIDIA driver;
- the media disk with UUID `ACCA4642CA460952` attached;
- this repository checked out;
- permission to push to `bupd/homelab`; and
- the GHCR package `ghcr.io/bupd/homelab/cluster` set to public.

Install the host tools:

```bash
sudo pacman -S --needed curl podman nvidia-container-toolkit
brew install just
```

Check them:

```bash
podman info
nvidia-smi
nvidia-ctk --version
just --version
```

`just` is the only project command runner. It builds a pinned tool container
for Flux, Helm, kubectl, and yq. Those tools do not need to be installed on the
host.

## Fresh install: do these steps in order

### 1. Check the machine and disk

The checked-in addresses and disk UUID are specific to this homelab. Confirm
them before installing anything:

```bash
ip address show
lsblk -f
grep -v '^#' hosts/homelab/k3s-agents/media-worker/media-worker.fstab
```

Expected control-plane LAN address: `192.168.0.4`.

Create the mount point. The worker reconciler installs the persistent mount:

```bash
sudo install -d -m 0755 /home/bupd/hdd/data
```

Stop here if the address or disk UUID is wrong. Fix the checked-in files first.

### 2. Create the K3s cluster

Install the declared server configuration before K3s starts:

```bash
sudo install -d -m 0755 /etc/rancher/k3s
sudo install -m 0600 hosts/homelab/k3s/config.yaml /etc/rancher/k3s/config.yaml
sudo install -m 0644 hosts/homelab/k3s/modules-load.conf /etc/modules-load.d/k3s.conf
sudo install -m 0644 hosts/homelab/k3s/sysctl.conf /etc/sysctl.d/90-k3s.conf
sudo modprobe overlay br_netfilter
sudo sysctl --system
```

Install the pinned K3s release:

```bash
curl -sfL https://get.k3s.io \
  | sudo env INSTALL_K3S_VERSION='v1.36.2+k3s1' sh -
```

Check the control plane:

```bash
sudo systemctl status k3s --no-pager
sudo k3s kubectl get --raw=/readyz
```

`kubectl get nodes` can be empty at this point. The server is agentless and is
not a Kubernetes worker.

### 3. Create and join `media-worker`

Run the host reconciler:

```bash
sudo hosts/homelab/k3s-agents/media-worker/reconcile.sh
```

It mounts the HDD, creates the Podman K3s agent, copies the private K3s token,
joins the worker, applies its labels, moves system Pods to it, and verifies the
GPU and storage mounts.

Check the result:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A -o wide
sudo podman ps --filter name=media-worker
```

Expected result: the only Kubernetes Node is `media-worker`, and it is `Ready`.
`archbtw` must not appear as a Node.

### 4. Create the local kubeconfig

The Just recipes expect `$HOME/.kube/k3s.kubeconfig.yaml` and context
`homelab`:

```bash
install -d -m 0700 "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/k3s.kubeconfig.yaml"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/k3s.kubeconfig.yaml"
chmod 0600 "$HOME/.kube/k3s.kubeconfig.yaml"
export KUBECONFIG="$HOME/.kube/k3s.kubeconfig.yaml"
kubectl config rename-context default homelab
kubectl config use-context homelab
kubectl get nodes
```

If the context is already named `homelab`, skip the `rename-context` command.
Never commit this file. It is a cluster-admin credential.

### 5. Validate and publish the desired state

Validate all Kustomizations, YAML, and pinned Helm charts locally:

```bash
just validate
```

Push or merge the desired state to `main`:

```bash
git push origin main
```

GitHub Actions validates the repository, publishes an immutable commit-tagged
artifact, and moves `ghcr.io/bupd/homelab/cluster:latest` to that artifact.
Wait for the `Publish homelab cluster artifact` workflow to succeed before
continuing.

To publish manually instead:

```bash
GHCR_USERNAME=bupd \
GHCR_TOKEN='<GitHub token with write:packages>' \
just artifact-push
```

Flux pulls the public artifact anonymously. No GHCR pull Secret is needed.

### 6. Install Flux once

```bash
export KUBECONFIG="$HOME/.kube/k3s.kubeconfig.yaml"
just flux-install
```

This installs only the Flux CRDs and controllers. Check them:

```bash
kubectl -n flux-system get pods -o wide
```

All Flux Pods should become `Running` on `media-worker`.

### 7. Point Flux at GHCR and deploy everything

```bash
just flux-bootstrap
just flux-reconcile
just flux-status
```

That starts this dependency chain:

```text
node policy
  -> CloudNativePG operator
  -> Immich PostgreSQL database
  -> Immich Helm release
```

Flux checks the public `latest` OCI artifact every two minutes. Future pushes
to `main` are deployed automatically. Pushes to other branches publish an
immutable artifact but do not move `latest`.

### 8. Check Immich

```bash
kubectl -n immich get pods,pvc
kubectl -n immich get clusters.postgresql.cnpg.io,databases.postgresql.cnpg.io
kubectl -n immich get helmrelease,ocirepository
kubectl -n immich rollout status deployment/immich-server --timeout=15m
```

There is no ingress yet. Open a temporary local tunnel:

```bash
kubectl -n immich port-forward service/immich-server 2283:2283
```

Open <http://127.0.0.1:2283>.

Do not create a new admin account if restoring the existing library. Follow
[Immich backup and restore](apps/media/immich/README.md#backup-and-restore) to
restore the existing database, verify the photos, and enable scheduled
backups.

## Normal daily operation

Change manifests, validate, then push to `main`:

```bash
just validate
git add --all
git commit -m 'describe the cluster change'
git push origin main
```

Watch reconciliation:

```bash
just flux-status
```

Do not fix managed resources with `kubectl edit`. Flux will revert the change.
Edit this repository and publish a new artifact.

## Add another worker later

Flux does not join machines to Kubernetes. First install and join a K3s agent
using the server address `https://192.168.0.4:6443` and the private token at
`/var/lib/rancher/k3s/server/node-token`.

After the Node is `Ready`:

1. Add `clusters/homelab/nodes/<node-name>/node-policy.yaml`.
2. Add that file to `clusters/homelab/nodes/kustomization.yaml`.
3. Add node selectors or affinity only to workloads intended for that node.
4. Run `just validate`, commit, and push to `main`.

Do not install another copy of Flux on the worker.

## Where things live

```text
hosts/homelab/             host bootstrap, K3s server, worker definition
clusters/homelab/          Flux installation and cluster reconciliation graph
platform/controllers/      shared operators such as CloudNativePG
apps/media/immich/         Immich, its database, values, storage, and backups
tools/ci/                   pinned containerized GitOps tools
```

Storage rules:

- Immich assets: `/home/bupd/hdd/data/BUPD_Personal/immich`
- Immich database: K3s `local-path` storage on the Linux filesystem
- Logical database dumps: the asset root's `backups/` directory
- Never put a live PostgreSQL data directory on the NTFS media disk
- Host-path storage requires hard node affinity to `media-worker`

More detail:

- [Host configuration](hosts/homelab/README.md)
- [Cluster reconciliation](clusters/homelab/README.md)
- [Immich operation and recovery](apps/media/immich/README.md)
- [Architecture and rollout decisions](docs/architecture-plan.md)
- [Private networking policy](docs/networking.md)
