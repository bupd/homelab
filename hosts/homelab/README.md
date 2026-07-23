# homelab host files

This folder describes things that must exist before Kubernetes can manage
itself.

Simple model:

- `k3s/` configures the real `archbtw` control plane.
- `k3s-agents/` configures isolated workers.
- This repository contains host configuration.
- The host contains runtime state and secrets.
- Run a worker's `reconcile.sh` to make the host match the checked-in files.

Do not commit K3s tokens, kubeconfigs, or application passwords here.
