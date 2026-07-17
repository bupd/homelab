# Node policies

Each registered K3s machine has exactly one `node-policy.yaml`. That manifest
owns the node's declarative labels and taints. Keeping one resource per node
avoids server-side-apply ownership conflicts.

Do not add a worker manifest before its K3s agent has joined the cluster. A
Node manifest for an absent machine would create a phantom, permanently
`NotReady` Kubernetes Node.
