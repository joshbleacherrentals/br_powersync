#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

use_raw=false
filtered_args=()

for arg in "$@"; do
  if [[ "$arg" == "--raw" ]]; then
    use_raw=true
  else
    filtered_args+=("$arg")
  fi
done

if ((${#filtered_args[@]})); then
  set -- "${filtered_args[@]}"
else
  set --
fi

if [[ "$use_raw" == true ]]; then
  compose_file="${repo_root}/docker-compose.yml"
else
  # Keep the generated compose file in sync for Coolify.
  if ! command -v ruby >/dev/null 2>&1; then
    echo "ruby is required to generate docker-compose.coolify.yml" >&2
    echo "Install ruby or run: docker compose -f docker-compose.yml up" >&2
    exit 1
  fi

  "${repo_root}/scripts/generate-coolify-compose.sh" >/dev/null
  compose_file="${repo_root}/docker-compose.coolify.yml"
fi

exec docker compose -f "$compose_file" up "$@"
