# instance1 K3s host

`archbtw` is the authoritative K3s server for the `ins1` cluster. It uses the
single-server datastore created by the standard K3s installation and is not an
application worker. The files in this directory mirror host configuration
installed under `/etc`.

The control-plane node has a persistent `NoSchedule` taint. Application
capacity is supplied by agent-only worker nodes that join
`https://192.168.0.4:6443`.

Cluster objects, infrastructure add-ons, and applications are declared under
`clusters/ins1` and will be reconciled by Flux. Host-level K3s configuration
remains here because it must exist before Kubernetes and Flux start.
