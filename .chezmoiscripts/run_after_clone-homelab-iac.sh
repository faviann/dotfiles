#!/usr/bin/env bash
set -euo pipefail

readonly homelab_iac_url=https://github.com/faviann/homelab-iac.git
readonly homelab_iac_repo="$HOME/repos/homelab-iac"

if [[ -e "$homelab_iac_repo" || -L "$homelab_iac_repo" ]]; then
  exit 0
fi

mkdir -p "$(dirname "$homelab_iac_repo")"
if ! GIT_TERMINAL_PROMPT=0 git clone "$homelab_iac_url" "$homelab_iac_repo"; then
  printf 'clone-homelab-iac: warning: cannot clone %s into %s; the next apply retries\n' \
    "$homelab_iac_url" "$homelab_iac_repo" >&2
fi
