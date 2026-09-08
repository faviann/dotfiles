#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}

render_install_packages() {
  local is_workstation="$1"
  local output="$2"
  local destination
  local render_dir

  render_dir="$(dirname "$output")"
  destination="$render_dir/destination"
  mkdir -p "$destination"
  chezmoi \
    --source "$REPO_ROOT" \
    --destination "$destination" \
    --config /dev/null \
    --config-format toml \
    --persistent-state "$render_dir/chezmoistate.boltdb" \
    --override-data "{\"is_workstation\":$is_workstation}" \
    execute-template \
    --file "$REPO_ROOT/.chezmoiscripts/run_once_install-packages.sh.tmpl" \
    >"$output"
}

@test "test_fish_is_installed_only_off_the_configured_workstation" {
  local test_dir
  local workstation_render
  local other_render

  test_dir="$(mktemp -d)"
  workstation_render="$test_dir/workstation/script"
  other_render="$test_dir/other/script"
  mkdir -p "$test_dir/workstation" "$test_dir/other"

  render_install_packages true "$workstation_render"
  render_install_packages false "$other_render"

  grep -Fq 'apt install -y fish' "$other_render" \
    || fail 'non-workstation render omitted the fish package install'
  ! grep -Fq 'apt install' "$workstation_render" \
    || fail 'workstation render proposed a package install'
}
