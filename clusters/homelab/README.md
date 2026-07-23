# homelab cluster reconciliation

Flux reconciles this cluster from the OCI artifact at
`oci://ghcr.io/bupd/homelab/cluster:latest`. Git is not used as an in-cluster
source.

The directories have distinct responsibilities:

- `flux-system/` is the pinned, one-time Flux controller installation.
- `bootstrap/` declares the root OCI source and the root Flux `Kustomization`.
- `cluster/` declares the ordered cluster-wide reconciliation graph.
- `nodes/` owns policy for Kubernetes Nodes that have already joined.
- `policies/` owns API-server admission guardrails for every workload.

Application resources live under the repository-level `apps/` directory.
Shared operators and other application platform services live under
repository-level `platform/`.

## Publish the desired state

Authenticate to GHCR only when pushing. The package is public, so Flux pulls
the desired-state artifact anonymously and checks `latest` every two minutes.

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

The root `Justfile` is the supported interface for local users and CI. After an
artifact has been published, install the cluster with:

```bash
just validate
just flux-install
just flux-sops-key
just flux-bootstrap
just flux-reconcile
just flux-status
```

After bootstrap, the `cluster` Flux `Kustomization` creates the remaining
ordered reconcilers. Flux is installed once for the Kubernetes cluster, not
once per worker.

Before publishing the platform artifact, replace the encrypted placeholders in
the Tailscale `operator-oauth.sops.yaml` manifest as documented in the root
README. SOPS-encrypted Secrets are decrypted by each Flux Kustomization using
`flux-system/sops-age`.

To publish manually instead of waiting for GitHub Actions:

```bash
GHCR_USERNAME=bupd GHCR_TOKEN='<write-packages-token>' \
  just push-artifact
```

GitHub Actions publishes an immutable commit-tagged artifact for every branch
push. With no scope, it publishes exactly the graph enabled by
`clusters/homelab/cluster/kustomization.yaml`. Every successful branch workflow
also moves the `latest` tag consumed by the cluster.
