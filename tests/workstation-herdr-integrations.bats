#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}
REAL_BASH="$(command -v bash)"
readonly REAL_BASH
export REAL_BASH

render_hook() {
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
    --file "$REPO_ROOT/.chezmoiscripts/run_after_install-herdr-integrations.sh.tmpl" \
    >"$output"
  chmod +x "$output"
}

# The stub reports each target from a state file holding `current` or
# `outdated`; a missing file is `not installed`. Like Herdr, install refuses
# when the agent's config directory is missing.
make_herdr_stub() {
  local bin_dir="$1"

  mkdir -p "$bin_dir"
  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/herdr"
  cat >>"$bin_dir/herdr" <<'STUB'
set -euo pipefail

printf 'herdr %s\n' "$*" >>"$COMMAND_LOG"
[[ "${1:-}" == integration ]] || exit 99

case "${2:-}" in
  status)
    for target in pi omp claude codex opencode; do
      state=$(cat "$HERDR_STATE/$target" 2>/dev/null || printf 'not installed')
      [[ "$state" == current ]] && state='current (v1)'
      printf '%s: %s (%s)\n' "$target" "$state" "$HOME/.$target"
    done
    ;;
  install)
    target="$3"
    case "$target" in
      claude) dir="$HOME/.claude" ;;
      codex) dir="$HOME/.codex" ;;
      pi) dir="$HOME/.pi/agent" ;;
      omp) dir="$HOME/.omp/agent" ;;
      opencode) dir="$HOME/.config/opencode" ;;
      *) exit 98 ;;
    esac
    [[ -d "$dir" ]] || exit 1
    printf 'current\n' >"$HERDR_STATE/$target"
    ;;
  *) exit 99 ;;
esac
STUB
  chmod +x "$bin_dir/herdr"
}

run_hook() {
  local test_dir="$1"
  local script="$test_dir/hook"

  mkdir -p "$test_dir/home" "$test_dir/state"
  [[ -x "$script" ]] || render_hook true "$script"
  make_herdr_stub "$test_dir/bin"
  env \
    HOME="$test_dir/home" \
    PATH="$test_dir/bin:$PATH" \
    COMMAND_LOG="$test_dir/commands" \
    HERDR_STATE="$test_dir/state" \
    "$REAL_BASH" "$script"
}

installs() {
  grep '^herdr integration install ' "$1/commands" || true
}

@test "test_integrations_not_current_are_installed_into_private_config_dirs" {
  local test_dir
  test_dir="$(mktemp -d)"

  mkdir -p "$test_dir/state"
  printf 'current\n' >"$test_dir/state/claude"
  printf 'outdated (v0 < v1)\n' >"$test_dir/state/codex"
  run_hook "$test_dir" || fail 'integration install failed'

  diff -u \
    <(printf 'herdr integration install %s\n' codex pi omp opencode) \
    <(installs "$test_dir") \
    || fail 'did not install exactly the integrations Herdr does not report as current'
  for dir in .codex .pi .omp .config/opencode; do
    [[ "$(stat -c %a "$test_dir/home/$dir")" == 700 ]] \
      || fail "created config directory $dir is not private"
  done
  [[ ! -e "$test_dir/home/.claude" ]] \
    || fail 'a current integration had its config directory created'
}

@test "test_rerun_with_current_integrations_installs_nothing" {
  local test_dir
  test_dir="$(mktemp -d)"

  run_hook "$test_dir" || fail 'first apply failed'
  : >"$test_dir/commands"
  run_hook "$test_dir" || fail 'second apply failed'

  [[ -z "$(installs "$test_dir")" ]] \
    || fail 'second apply reinstalled current integrations'
}

@test "test_non_workstation_render_is_a_noop" {
  local test_dir
  local script
  test_dir="$(mktemp -d)"
  script="$test_dir/hook"

  render_hook false "$script"
  if grep -q '[^[:space:]]' "$script"; then
    fail 'non-workstation render contained executable work'
  fi
}
