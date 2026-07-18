set shell := ["bash", "-euo", "pipefail", "-c"]

oci_repository := env("OCI_REPOSITORY", "oci://ghcr.io/bupd/homelab/cluster")
kube_context := env("KUBE_CONTEXT", "homelab")
container_runtime := env("CONTAINER_RUNTIME", "podman")
ci_image := env("HOMELAB_CI_IMAGE", "localhost/homelab-ci:latest")
repo_dir := justfile_directory()
home_dir := env("HOME")
kubeconfig := env("KUBECONFIG", home_dir + "/.kube/k3s.kubeconfig.yaml")

default:
    @just --list

# Bootstrap the container runtime in an Ubuntu GitHub Actions job container.
ci-install-container-runtime:
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates podman

# Build the tool container used by every GitOps recipe.
ci-image:
    {{container_runtime}} build -t "{{ci_image}}" -f tools/ci/Containerfile tools/ci

# Render every GitOps boundary and chart in the pinned tool container.
validate: ci-image
    {{container_runtime}} run --rm --network=host \
      -v "{{repo_dir}}:/workspace:ro" -w /workspace \
      "{{ci_image}}" just _validate

[private]
_validate: validate-kustomize validate-helm validate-yaml validate-names

validate-kustomize:
    #!/usr/bin/env bash
    for directory in \
      clusters/homelab/flux-system \
      clusters/homelab/bootstrap \
      clusters/homelab/cluster \
      clusters/homelab/nodes \
      platform/controllers \
      platform/controllers/cloudnative-pg \
      apps/media/immich \
      apps/media/immich/database \
      apps/media/immich/app; do
      kubectl kustomize "${directory}" >/dev/null
    done

validate-helm:
    #!/usr/bin/env bash
    helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null
    helm template cloudnative-pg cnpg/cloudnative-pg \
      --version 0.29.0 \
      --namespace cnpg-system \
      --set 'nodeSelector.homelab\.bupd\.dev/workload-pool=media' \
      --set resources.requests.cpu=100m \
      --set resources.requests.memory=128Mi \
      --set resources.limits.memory=512Mi >/dev/null
    helm template immich oci://ghcr.io/immich-app/immich-charts/immich \
      --version 0.13.1 \
      --namespace immich \
      --values apps/media/immich/app/values.yaml >/dev/null

validate-yaml:
    #!/usr/bin/env bash
    while IFS= read -r -d '' file; do
      yq eval '.' "${file}" >/dev/null
    done < <(find clusters/homelab apps/media/immich platform/controllers .github/workflows \
      -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

validate-names:
    #!/usr/bin/env bash
    if rg -n -i 'instance1|ins1' . -g '!**/.git/**' -g '!Justfile'; then
      echo 'stale cluster name found' >&2
      exit 1
    fi

# Build the same reproducible artifact that CI publishes.
artifact-build output="dist/homelab-cluster.tgz": ci-image
    mkdir -p "$(dirname "{{output}}")"
    {{container_runtime}} run --rm --network=host \
      -v "{{repo_dir}}:/workspace" -w /workspace \
      "{{ci_image}}" flux build artifact --path=. --output="{{output}}"

# Push an immutable revision and move latest to it. Requires GHCR_USERNAME and GHCR_TOKEN.
artifact-push: ci-image
    {{container_runtime}} run --rm --network=host \
      --env GHCR_USERNAME --env GHCR_TOKEN --env OCI_TAG --env OCI_SOURCE \
      --env OCI_REVISION --env UPDATE_LATEST --env GITHUB_SHA --env GITHUB_REF_NAME \
      --env OCI_REPOSITORY="{{oci_repository}}" \
      -v "{{repo_dir}}:/workspace:ro" -w /workspace \
      "{{ci_image}}" just _artifact-push

[private]
_artifact-push: _validate
    #!/usr/bin/env bash
    : "${GHCR_USERNAME:?set GHCR_USERNAME}"
    : "${GHCR_TOKEN:?set GHCR_TOKEN}"
    tag="${OCI_TAG:-${GITHUB_SHA:-$(git rev-parse HEAD)}}"
    source="${OCI_SOURCE:-$(git config --get remote.origin.url 2>/dev/null || printf 'local://homelab')}"
    revision="${OCI_REVISION:-${GITHUB_REF_NAME:-local}@sha1:${tag}}"
    flux push artifact "{{oci_repository}}:${tag}" \
      --path=. \
      --source="${source}" \
      --revision="${revision}" \
      --reproducible \
      --creds="${GHCR_USERNAME}:${GHCR_TOKEN}"
    if [[ "${UPDATE_LATEST:-true}" == true ]]; then
      flux tag artifact "{{oci_repository}}:${tag}" \
        --tag=latest \
        --creds="${GHCR_USERNAME}:${GHCR_TOKEN}"
    fi

# Install Flux CRDs and controllers once. This does not deploy applications yet.
flux-install: ci-image
    {{container_runtime}} run --rm --network=host \
      --env KUBE_CONTEXT="{{kube_context}}" --env KUBECONFIG=/kubeconfig \
      -v "{{repo_dir}}:/workspace:ro" -v "{{kubeconfig}}:/kubeconfig:ro" -w /workspace \
      "{{ci_image}}" just _flux-install

[private]
_flux-install:
    kubectl --context "{{kube_context}}" apply --server-side -k clusters/homelab/flux-system
    kubectl --context "{{kube_context}}" wait --for=condition=Available deployment -n flux-system --all --timeout=5m

# Point the installed Flux controllers at the GHCR desired-state artifact.
flux-bootstrap: ci-image
    {{container_runtime}} run --rm --network=host \
      --env KUBE_CONTEXT="{{kube_context}}" --env KUBECONFIG=/kubeconfig \
      -v "{{repo_dir}}:/workspace:ro" -v "{{kubeconfig}}:/kubeconfig:ro" -w /workspace \
      "{{ci_image}}" just _flux-bootstrap

[private]
_flux-bootstrap:
    kubectl --context "{{kube_context}}" apply --server-side -k clusters/homelab/bootstrap

# Request immediate source and cluster reconciliation.
flux-reconcile: ci-image
    {{container_runtime}} run --rm --network=host \
      --env KUBE_CONTEXT="{{kube_context}}" --env KUBECONFIG=/kubeconfig \
      -v "{{repo_dir}}:/workspace:ro" -v "{{kubeconfig}}:/kubeconfig:ro" -w /workspace \
      "{{ci_image}}" just _flux-reconcile

[private]
_flux-reconcile:
    flux --context "{{kube_context}}" reconcile source oci homelab -n flux-system
    flux --context "{{kube_context}}" reconcile kustomization cluster -n flux-system --with-source

flux-status: ci-image
    {{container_runtime}} run --rm --network=host \
      --env KUBE_CONTEXT="{{kube_context}}" --env KUBECONFIG=/kubeconfig \
      -v "{{repo_dir}}:/workspace:ro" -v "{{kubeconfig}}:/kubeconfig:ro" -w /workspace \
      "{{ci_image}}" just _flux-status

[private]
_flux-status:
    flux --context "{{kube_context}}" check
    flux --context "{{kube_context}}" get all -A
    kubectl --context "{{kube_context}}" get nodes,pods,pvc -A -o wide
    kubectl --context "{{kube_context}}" get cluster,database -n immich
    kubectl --context "{{kube_context}}" get helmrelease,ocirepository -A
