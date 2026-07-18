set shell := ["bash", "-euo", "pipefail", "-c"]

oci_repository := env("OCI_REPOSITORY", "oci://ghcr.io/bupd/homelab/cluster")
kube_context := env("KUBE_CONTEXT", "homelab")
container_runtime := env("CONTAINER_RUNTIME", "podman")
ci_image := env("HOMELAB_CI_IMAGE", "localhost/homelab-ci:latest")
repo_dir := justfile_directory()
home_dir := env("HOME")
kubeconfig := env("KUBECONFIG", home_dir + "/.kube/k3s.kubeconfig.yaml")
sops_age_key := env("SOPS_AGE_KEY_FILE", home_dir + "/.config/sops/age/keys.txt")

# Show commands. Change nothing.
default:
    @just --list

# CI needs Podman. Install and verify it on the normal Actions runner VM.
ci-install-container-runtime:
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates podman
    podman version
    podman info

# Build tool box container. Change no cluster.
ci-image:
    {{container_runtime}} build -t "{{ci_image}}" -f tools/ci/Containerfile tools/ci

# Open one SOPS file into ignored plaintext. Print no secret.
decrypt file: ci-image
    test -f {{quote(file)}}
    test -f "{{sops_age_key}}"
    {{container_runtime}} run --rm \
      --env SOPS_AGE_KEY_FILE=/sops-age-key \
      -v "{{repo_dir}}:/workspace" \
      -v "{{sops_age_key}}:/sops-age-key:ro" \
      -w /workspace \
      "{{ci_image}}" just _decrypt {{quote(file)}}

[private]
_decrypt file:
    #!/usr/bin/env bash
    input=$(realpath -e {{quote(file)}})
    case "${input}" in /workspace/*) ;; *) echo "file must be inside repository" >&2; exit 2 ;; esac
    case "${input}" in
      *.sops.yaml) output=${input%.sops.yaml}.dec.yaml ;;
      *.sops.yml) output=${input%.sops.yml}.dec.yml ;;
      *) echo "expected a *.sops.yaml or *.sops.yml file" >&2; exit 2 ;;
    esac
    umask 077
    temporary=$(mktemp)
    trap 'rm -f "${temporary}"' EXIT
    sops decrypt --input-type yaml --output-type yaml "${input}" >"${temporary}"
    install -m 0600 "${temporary}" "${output}"
    printf 'decrypted: %s\n' "${output#/workspace/}"

# Seal one ignored plaintext file, verify ciphertext, then remove plaintext.
encrypt file: ci-image
    test -f {{quote(file)}}
    {{container_runtime}} run --rm \
      -v "{{repo_dir}}:/workspace" \
      -w /workspace \
      "{{ci_image}}" just _encrypt {{quote(file)}}

[private]
_encrypt file:
    #!/usr/bin/env bash
    input=$(realpath -e {{quote(file)}})
    case "${input}" in /workspace/*) ;; *) echo "file must be inside repository" >&2; exit 2 ;; esac
    case "${input}" in
      *.dec.yaml) output=${input%.dec.yaml}.sops.yaml ;;
      *.dec.yml) output=${input%.dec.yml}.sops.yml ;;
      *) echo "expected a *.dec.yaml or *.dec.yml file" >&2; exit 2 ;;
    esac
    umask 077
    temporary=$(mktemp)
    trap 'rm -f "${temporary}"' EXIT
    sops encrypt --filename-override "${output}" --input-type yaml --output-type yaml \
      "${input}" >"${temporary}"
    install -m 0600 "${temporary}" "${output}"
    test "$(sops filestatus "${output}" | jq -r .encrypted)" = true
    rm -f "${input}"
    printf 'encrypted: %s\n' "${output#/workspace/}"

# Check all manifests and charts. Push nothing. Change no cluster.
validate: ci-image
    {{container_runtime}} run --rm --network=host \
      -v "{{repo_dir}}:/workspace:ro" -w /workspace \
      "{{ci_image}}" just _validate

[private]
_validate: validate-kustomize validate-helm validate-yaml validate-sops validate-names

# Render every Kustomization. Fail when one is broken.
validate-kustomize:
    #!/usr/bin/env bash
    for directory in \
      clusters/homelab/flux-system \
      clusters/homelab/bootstrap \
      clusters/homelab/cluster \
      clusters/homelab/nodes \
      platform/controllers \
      platform/controllers/cloudnative-pg \
      platform/networking \
      platform/networking/tailscale-operator \
      platform/observability \
      platform/observability/kube-prometheus-stack \
      apps/media/immich \
      apps/media/immich/database \
      apps/media/immich/app; do
      kubectl kustomize "${directory}" >/dev/null
    done

# Render every pinned Helm chart. Install nothing.
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
    helm repo add prometheus-community \
      https://prometheus-community.github.io/helm-charts --force-update >/dev/null
    helm template kube-prometheus-stack \
      prometheus-community/kube-prometheus-stack \
      --version 87.17.0 \
      --namespace observability \
      --values platform/observability/kube-prometheus-stack/values.yaml >/dev/null
    helm repo add tailscale https://pkgs.tailscale.com/helmcharts --force-update >/dev/null
    helm template tailscale-operator tailscale/tailscale-operator \
      --version 1.98.9 \
      --namespace tailscale \
      --values platform/networking/tailscale-operator/values.yaml >/dev/null

# Parse every YAML file. Fail on bad YAML.
validate-yaml:
    #!/usr/bin/env bash
    while IFS= read -r -d '' file; do
      yq eval '.' "${file}" >/dev/null
    done < <(find clusters/homelab apps/media/immich platform .github/workflows \
      -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

# Check SOPS encryption. Hunt plaintext secrets.
validate-sops:
    #!/usr/bin/env bash
    while IFS= read -r -d '' encrypted; do
      [[ "$(sops filestatus "${encrypted}" | jq -r .encrypted)" == true ]]
    done < <(find clusters/homelab apps platform -type f \
      \( -name '*.sops.yaml' -o -name '*.sops.yml' \) -print0)
    if find . -type f \( -name '*.dec.yaml' -o -name '*.dec.yml' -o \
      -name '*.plain.yaml' -o -name '*.plain.yml' \) -not -path './.git/*' -print -quit \
      | grep -q .; then
      echo 'plaintext secret file exists; run just encrypt before building' >&2
      exit 1
    fi
    if rg -n 'AGE-SECRET-KEY-|client_secret: tskey-|admin-password: [^E]' \
      . -g '!**/.git/**' -g '!*.md' -g '!Justfile'; then
      echo 'possible plaintext secret found' >&2
      exit 1
    fi

# Hunt stale instance1 and ins1 names.
validate-names:
    #!/usr/bin/env bash
    if rg -n -i 'instance1|ins1' . -g '!**/.git/**' -g '!Justfile'; then
      echo 'stale cluster name found' >&2
      exit 1
    fi

# Pack chosen layer into local OCI artifact. No scope means enabled graph. Push nothing.
build-artifact *selection: ci-image
    {{container_runtime}} run --rm --network=host \
      --env ARTIFACT_OUTPUT=/workspace/dist/homelab-cluster.tgz \
      -v "{{repo_dir}}:/workspace" -w /workspace \
      "{{ci_image}}" just _build-artifact {{selection}}

[private]
_build-artifact *selection: _validate
    #!/usr/bin/env bash
    stage_dir=$(mktemp -d)
    trap 'rm -rf "$stage_dir"' EXIT
    tools/ci/stage-artifact.sh "$stage_dir" {{selection}}
    mkdir -p "$(dirname "$ARTIFACT_OUTPUT")"
    flux build artifact --path="$stage_dir" --output="$ARTIFACT_OUTPUT"

# Pack chosen layer. Push immutable GHCR artifact. Move latest tag. Change no cluster directly.
push-artifact *selection: ci-image
    {{container_runtime}} run --rm --network=host \
      --env GHCR_USERNAME --env GHCR_TOKEN --env OCI_TAG --env OCI_SOURCE \
      --env OCI_REVISION --env UPDATE_LATEST --env GITHUB_SHA --env GITHUB_REF_NAME \
      --env OCI_REPOSITORY="{{oci_repository}}" \
      -v "{{repo_dir}}:/workspace:ro" -w /workspace \
      "{{ci_image}}" just _push-artifact {{selection}}

[private]
_push-artifact *selection: _validate
    #!/usr/bin/env bash
    : "${GHCR_USERNAME:?set GHCR_USERNAME}"
    : "${GHCR_TOKEN:?set GHCR_TOKEN}"
    stage_dir=$(mktemp -d)
    trap 'rm -rf "$stage_dir"' EXIT
    tools/ci/stage-artifact.sh "$stage_dir" {{selection}}
    tag="${OCI_TAG:-${GITHUB_SHA:-$(git rev-parse HEAD)}}"
    source="${OCI_SOURCE:-$(git config --get remote.origin.url 2>/dev/null || printf 'local://homelab')}"
    revision="${OCI_REVISION:-${GITHUB_REF_NAME:-local}@sha1:${tag}}"
    flux push artifact "{{oci_repository}}:${tag}" \
      --path="$stage_dir" \
      --source="${source}" \
      --revision="${revision}" \
      --reproducible \
      --creds="${GHCR_USERNAME}:${GHCR_TOKEN}"
    if [[ "${UPDATE_LATEST:-true}" == true ]]; then
      flux tag artifact "{{oci_repository}}:${tag}" \
        --tag=latest \
        --creds="${GHCR_USERNAME}:${GHCR_TOKEN}"
    fi

# Install Flux controllers once. Deploy no platform or apps yet.
flux-install: ci-image
    {{container_runtime}} run --rm --network=host \
      --env KUBE_CONTEXT="{{kube_context}}" --env KUBECONFIG=/kubeconfig \
      -v "{{repo_dir}}:/workspace:ro" -v "{{kubeconfig}}:/kubeconfig:ro" -w /workspace \
      "{{ci_image}}" just _flux-install

[private]
_flux-install:
    kubectl --context "{{kube_context}}" apply --server-side -k clusters/homelab/flux-system
    kubectl --context "{{kube_context}}" wait --for=condition=Available deployment -n flux-system --all --timeout=5m

# Give Flux local Age key. Flux can now open SOPS secrets.
flux-sops-key: ci-image
    test -f "{{sops_age_key}}"
    {{container_runtime}} run --rm --network=host \
      --env KUBE_CONTEXT="{{kube_context}}" --env KUBECONFIG=/kubeconfig \
      -v "{{repo_dir}}:/workspace:ro" \
      -v "{{kubeconfig}}:/kubeconfig:ro" \
      -v "{{sops_age_key}}:/sops-age-key:ro" \
      -w /workspace \
      "{{ci_image}}" just _flux-sops-key

[private]
_flux-sops-key:
    kubectl --context "{{kube_context}}" -n flux-system create secret generic sops-age \
      --from-file=identity.agekey=/sops-age-key --dry-run=client -o yaml \
      | kubectl --context "{{kube_context}}" apply --server-side -f -

# First boot only. Install Flux, give key, watch GHCR, reconcile, show result.
flux-up: ci-image
    test -f "{{sops_age_key}}"
    {{container_runtime}} run --rm --network=host \
      --env KUBE_CONTEXT="{{kube_context}}" --env KUBECONFIG=/kubeconfig \
      -v "{{repo_dir}}:/workspace:ro" \
      -v "{{kubeconfig}}:/kubeconfig:ro" \
      -v "{{sops_age_key}}:/sops-age-key:ro" \
      -w /workspace \
      "{{ci_image}}" just _flux-up

[private]
_flux-up: _flux-install _flux-sops-key _flux-bootstrap _flux-reconcile _flux-status

# Tell installed Flux to watch homelab artifact in GHCR.
flux-bootstrap: ci-image
    {{container_runtime}} run --rm --network=host \
      --env KUBE_CONTEXT="{{kube_context}}" --env KUBECONFIG=/kubeconfig \
      -v "{{repo_dir}}:/workspace:ro" -v "{{kubeconfig}}:/kubeconfig:ro" -w /workspace \
      "{{ci_image}}" just _flux-bootstrap

[private]
_flux-bootstrap:
    kubectl --context "{{kube_context}}" apply --server-side -k clusters/homelab/bootstrap

# Tell Flux: pull latest artifact now and reconcile now.
flux-reconcile: ci-image
    {{container_runtime}} run --rm --network=host \
      --env KUBE_CONTEXT="{{kube_context}}" --env KUBECONFIG=/kubeconfig \
      -v "{{repo_dir}}:/workspace:ro" -v "{{kubeconfig}}:/kubeconfig:ro" -w /workspace \
      "{{ci_image}}" just _flux-reconcile

[private]
_flux-reconcile:
    flux --context "{{kube_context}}" reconcile source oci homelab -n flux-system
    flux --context "{{kube_context}}" reconcile kustomization cluster -n flux-system --with-source

# Show Flux, nodes, workloads, storage, ingress, and releases.
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
    kubectl --context "{{kube_context}}" get prometheus,alertmanager -n observability
    kubectl --context "{{kube_context}}" get ingress -A
    kubectl --context "{{kube_context}}" get helmrelease,ocirepository -A
