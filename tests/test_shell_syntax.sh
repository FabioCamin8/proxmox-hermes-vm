#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

while IFS= read -r -d '' script; do
    bash -n "$script"
done < <(find "$repo_root/scripts" -type f -name '*.sh' -print0)

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$repo_root"/scripts/*.sh "$repo_root"/scripts/lib/*.sh
else
    printf '%s\n' 'shellcheck unavailable; bash syntax checks passed.'
fi
