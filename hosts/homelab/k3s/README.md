# homelab K3s host

`archbtw` is the authoritative K3s server for the `homelab` cluster.

Simple model:

- This host controls the cluster.
- This host has no K3s agent.
- This host runs no Pods.
- `media-worker` runs every Pod.
- `kubectl get nodes` does not show `archbtw`. That is correct.

`config.yaml` is copied to `/etc/rancher/k3s/config.yaml` by the worker
reconcile script. It enables `disable-agent` and the cluster egress tunnel.

The retained `NoSchedule` taint is a safety belt if the embedded agent is ever
enabled accidentally. Normal scheduling protection comes from having no
kubelet or container runtime on the control plane at all.

Cluster objects, infrastructure add-ons, and applications are declared under
`clusters/homelab` and will be reconciled by Flux. Host-level K3s configuration
remains here because it must exist before Kubernetes and Flux start.
