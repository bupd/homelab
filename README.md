# Homelab

Declarative K3s homelab managed with FluxCD and Helm. Applications and cluster
add-ons run inside Kubernetes; Docker Compose is not part of the deployment
model.

## Architecture

The `ins1` cluster has one intentionally authoritative control plane and any
number of agent-only workers.

| Node | LAN address | Tailnet address | K3s role | Workload policy |
| --- | --- | --- | --- | --- |
| `archbtw` | `192.168.0.4` | `100.81.118.34` | Server/control plane | `NoSchedule` |
| Future nodes | Assigned per host | Assigned by Tailscale | Agent/worker | Application workloads |

The control plane is deliberately not highly available. Losing `archbtw`
makes the Kubernetes API unavailable until that machine is restored, while
worker capacity can be expanded without changing the control-plane topology.

## Repository layout

```text
clusters/
  ins1/                    # Kubernetes objects reconciled for the ins1 cluster
    nodes/                 # One declarative policy per registered node
hosts/
  instance1/
    k3s/                   # Host bootstrap configuration installed under /etc
experiments/               # Raspberry Pi and bootc experiments
docs/                       # Architecture and operational documentation
```

Host configuration and cluster configuration are intentionally separate:

- `hosts/` contains files required before Kubernetes and Flux can run, such as
  the K3s server configuration, kernel modules, and sysctl settings.
- `clusters/` contains Kubernetes resources rendered by Kustomize and
  eventually reconciled continuously by Flux.
- Each application will be installed through a pinned Helm release declared in
  Git. Runtime edits are treated as drift rather than configuration.

## Current state

- K3s `v1.36.2+k3s1` is running on `archbtw`.
- The local kubeconfig context is named `ins1`.
- CoreDNS, metrics-server, local-path-provisioner, Traefik, and ServiceLB are
  currently provided by the default K3s installation. Traefik and ServiceLB
  are transitional and are disabled in the declared host configuration.
- The control-plane Node policy is declared in
  `clusters/ins1/nodes/archbtw/node-policy.yaml`.
- Flux bootstrap and application releases have not been added yet.
- Tailscale is installed but must be logged back into the tailnet before its
  declared address and MagicDNS name are reachable.

## Private access

The cluster has no public ingress. Remote administrative access and application
traffic stay inside the Tailscale network:

- Kubernetes API: `https://archbtw.tail6c5ea9.ts.net:6443`
- Control-plane tailnet IP: `100.81.118.34`
- Applications: individual tailnet-only MagicDNS names provisioned by the
  Flux-managed Tailscale Kubernetes Operator, using the bare application name
  such as `immich.tail6c5ea9.ts.net` or `sonarr.tail6c5ea9.ts.net`
- Tailscale Funnel: prohibited

The LAN API address remains available for agent registration. No application
will use a public `LoadBalancer`, public DNS record, router port forward, or
Funnel annotation. See `docs/networking.md` for the complete policy.

The `192.168.0.0/24` network is only the cluster underlay. It is never an
application identity. Every user-facing service must have a dedicated
Tailscale MagicDNS name, and the application must be configured with that exact
HTTPS URL as its external/base URL.

## Apply the current cluster configuration

Select the cluster kubeconfig:

```bash
export KUBECONFIG="$HOME/.kube/k3s.kubeconfig.yaml"
kubectl config use-context ins1
```

Preview the rendered resources:

```bash
kubectl kustomize clusters/ins1
```

Apply them using server-side ownership compatible with Flux:

```bash
kubectl apply --server-side -k clusters/ins1
```

Verify the control-plane scheduling policy:

```bash
kubectl get node archbtw \
  -o custom-columns='NAME:.metadata.name,LABELS:.metadata.labels,TAINTS:.spec.taints'
```

## Adding workers

Worker installation is a host bootstrap operation and cannot be performed by a
Kubernetes manifest. Install the matching K3s agent on the new machine using
`https://192.168.0.4:6443` and the server's private node token.

After the agent registers:

1. Confirm that the Node is `Ready` and record its exact Kubernetes name.
2. Add `clusters/ins1/nodes/<node-name>/node-policy.yaml`.
3. Reference the policy from `clusters/ins1/nodes/kustomization.yaml`.
4. Render and apply the cluster configuration.

Never commit the K3s token, kubeconfig credentials, or unencrypted application
secrets.

## Storage conventions

- Application configuration and database state belong under `/opt/<service>`
  on the ext4 filesystem of the node that owns the workload, or on storage
  exposed through an explicitly selected CSI/NFS provisioner.
- Bulk photos, media, and downloads belong under `/home/bupd/hdd/data`.
- PostgreSQL and other databases must not be placed on the NTFS media disk.
- Host-backed volumes require explicit node affinity because their contents do
  not follow a Pod to another worker.

The media HDD is currently attached to `archbtw`, but application Pods are
excluded from that node. Workers therefore cannot use the HDD through a direct
`hostPath`. Before Immich is deployed, the storage must either be exported to
workers, attached to a storage-capable worker, or exposed through an
appropriate persistent-volume provisioner.

## Planned services

The initial application rollout is Immich, followed by Jellyfin, Transmission,
Sonarr, Radarr, Prowlarr, Bazarr, File Browser, and related Arr services. Each
service will be deployed through Flux and Helm with declarative storage,
networking, resource, and backup policies.
