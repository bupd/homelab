#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: stage-artifact.sh DESTINATION [SCOPE] [--ignore PATH]...

Examples:
  stage-artifact.sh /tmp/artifact
  stage-artifact.sh /tmp/artifact cluster
  stage-artifact.sh /tmp/artifact platform/observability
  stage-artifact.sh /tmp/artifact platform --ignore platform/controllers
  stage-artifact.sh /tmp/artifact --ignore apps
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }

destination=$1
shift
scope=
declare -a ignores=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ignore)
      [[ $# -ge 2 ]] || { echo '--ignore requires a path' >&2; exit 2; }
      ignores+=("${2#./}")
      shift 2
      ;;
    --ignore=*)
      ignores+=("${1#--ignore=}")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [[ -z "$scope" ]] || {
        echo "only one scope is accepted; use --ignore for exclusions" >&2
        exit 2
      }
      scope=${1#./}
      shift
      ;;
  esac
done

scope=${scope%/}
if [[ "$scope" == cluster ]]; then
  scope=clusters/homelab
fi
for index in "${!ignores[@]}"; do
  ignores[$index]=${ignores[$index]%/}
done

cluster_source=clusters/homelab/cluster
cluster_destination="$destination/$cluster_source"
declare -A files=()
declare -A paths=()
declare -A selected=()
declare -A excluded=()

path_intersects() {
  local left=${1%/}
  local right=${2%/}
  [[ "$left" == "$right" || "$left" == "$right/"* || "$right" == "$left/"* ]]
}

for file in "$cluster_source"/*.yaml; do
  [[ $(yq eval '.kind' "$file") == Kustomization ]] || continue
  [[ $(yq eval '.apiVersion' "$file") == kustomize.toolkit.fluxcd.io/* ]] || continue
  name=$(yq eval '.metadata.name' "$file")
  managed_path=$(yq eval '.spec.path' "$file")
  managed_path=${managed_path#./}
  files[$name]=$file
  paths[$name]=$managed_path
done

for name in "${!files[@]}"; do
  for ignored in "${ignores[@]}"; do
    if path_intersects "${paths[$name]}" "$ignored"; then
      excluded[$name]=1
    fi
  done

  if [[ -z "$scope" ]] || path_intersects "${paths[$name]}" "$scope"; then
    [[ -n ${excluded[$name]:-} ]] || selected[$name]=1
  fi
done

if [[ ${#selected[@]} -eq 0 ]]; then
  echo "scope selects no reconciliation boundary: ${scope:-<all>}" >&2
  exit 2
fi

# Expand the Flux dependsOn graph so a selected application carries its platform
# prerequisites. Explicit ignores always win and therefore turn a missing required
# dependency into an error.
changed=true
while [[ "$changed" == true ]]; do
  changed=false
  for name in "${!selected[@]}"; do
    while IFS= read -r dependency; do
      [[ -n "$dependency" && "$dependency" != null ]] || continue
      [[ -n ${files[$dependency]:-} ]] || {
        echo "$name depends on unknown cluster Kustomization $dependency" >&2
        exit 1
      }
      if [[ -n ${excluded[$dependency]:-} ]]; then
        echo "cannot ignore ${paths[$dependency]}: it is required by ${paths[$name]}" >&2
        exit 2
      fi
      if [[ -z ${selected[$dependency]:-} ]]; then
        selected[$dependency]=1
        changed=true
      fi
    done < <(yq eval '.spec.dependsOn[]?.name' "${files[$name]}")
  done
done

mkdir -p "$cluster_destination"
cp "$cluster_source/kustomization.yaml" "$cluster_destination/kustomization.yaml"
yq eval --inplace '.resources = []' "$cluster_destination/kustomization.yaml"

mapfile -t ordered_names < <(
  for name in "${!selected[@]}"; do
    printf '%s\t%s\n' "${files[$name]}" "$name"
  done | sort | cut -f2
)

for name in "${ordered_names[@]}"; do
  file=${files[$name]}
  managed_path=${paths[$name]}
  mkdir -p "$destination/$(dirname "$managed_path")"
  if [[ ! -e "$destination/$managed_path" ]]; then
    cp -a "$managed_path" "$destination/$managed_path"
  fi
  cp "$file" "$cluster_destination/$(basename "$file")"
  filename=$(basename "$file")
  FILENAME="$filename" yq eval --inplace \
    '.resources += [strenv(FILENAME)]' "$cluster_destination/kustomization.yaml"
  printf 'include %-22s %s\n' "$name" "$managed_path"
done

kubectl kustomize "$cluster_destination" >/dev/null
