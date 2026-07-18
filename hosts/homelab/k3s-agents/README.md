# K3s workers

This folder holds worker definitions.

Simple model:

- `archbtw` runs the control plane on the real host.
- Workers run separately.
- Workers run Pods. The control plane does not.
- Secrets do not go in Git.

Each worker gets its own folder. Run that worker's install script from the
repository root.
