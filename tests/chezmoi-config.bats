#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

effective_safe() {
  local hostname="$1"
  local config="$BATS_TEST_TMPDIR/$hostname.toml"

  chezmoi --config /dev/null --config-format toml --source "$REPO_ROOT" \
    execute-template --init \
    --override-data "{\"chezmoi\":{\"hostname\":\"$hostname\"}}" \
    <"$REPO_ROOT/.chezmoi.toml.tmpl" >"$config"
  chezmoi --config "$config" dump-config --format json | jq '.safe'
}

@test "test_only_the_workstation_writes_targets_in_place" {
  [ "$(effective_safe workstation)" = false ]
  [ "$(effective_safe laptop)" = true ]
}
