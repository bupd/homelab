# homelab cluster reconciliation

Flux reconciles this cluster from the OCI artifact at
`oci://ghcr.io/bupd/homelab/cluster:latest`. Git is not used as an in-cluster
source.

The directories have distinct responsibilities:

- `flux-system/` is the pinned, one-time Flux controller installation.
- `bootstrap/` declares the root OCI source and the root Flux `Kustomization`.
- `cluster/` declares the ordered cluster-wide reconciliation graph.
- `nodes/` owns policy for Kubernetes Nodes that have already joined.

Application resources live under the repository-level `apps/` directory.
Shared operators and other application platform services live under
repository-level `platform/`.

## Publish the desired state

Authenticate to GHCR before pushing. The package must be public for the
current source declaration. If it is private, add a `secretRef` to
`bootstrap/source.yaml` and create that pull Secret separately before
bootstrapping.

```bash
desired_state_sha="$(find . -path './.git' -prune -o -type f -print0 \
  | sort -z | xargs -0 sha1sum | sha1sum | cut -d' ' -f1)"
flux push artifact oci://ghcr.io/bupd/homelab/cluster:latest \
  --path=. \
  --source=local://homelab \
  --revision="local@sha1:${desired_state_sha}" \
  --reproducible
```

The revision above is OCI provenance metadata only. Flux does not clone or
read a Git repository; its runtime source remains GHCR.

Prefer also publishing an immutable release tag for rollback, even while the
cluster follows `latest`.

## Bootstrap later

These commands are intentionally not run as part of preparing the manifests:

```bash
kubectl apply --server-side -k clusters/homelab/flux-system
kubectl wait --for=condition=Available deployment \
  -n flux-system --all --timeout=5m
kubectl apply --server-side -k clusters/homelab/bootstrap
```

After bootstrap, the `cluster` Flux `Kustomization` creates the remaining
ordered reconcilers. Flux is installed once for the Kubernetes cluster, not
once per worker.
