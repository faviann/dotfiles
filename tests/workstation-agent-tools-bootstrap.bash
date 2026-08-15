#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
REAL_BASH="$(command -v bash)"
readonly REAL_BASH

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

activation_script() {
  if [[ -n "${TEST_BOOTSTRAP_ACTIVATION_SCRIPT:-}" ]]; then
    cat "$TEST_BOOTSTRAP_ACTIVATION_SCRIPT"
    return
  fi

  nix eval --raw \
    "$REPO_ROOT#homeConfigurations.workstation.config.home.activation.bootstrapAgentTools.data"
}

make_stub() {
  local path="$1"

  mkdir -p "$(dirname "$path")"
  printf '#!%s\nexit 0\n' "$REAL_BASH" >"$path"
  chmod +x "$path"
}

run_activation() {
  local home="$1"
  local script_path="$home/bootstrap-agent-tools"

  activation_script >"$script_path"
  chmod +x "$script_path"
  env \
    HOME="$home" \
    PATH= \
    DRY_RUN_CMD= \
    VERBOSE_ARG= \
    COMMAND_LOG="$home/command-log" \
    "$REAL_BASH" "$script_path"
}

test_missing_tools_are_installed_by_the_bootstrap_handoff() {
  local test_dir
  local bin_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  bin_dir="$test_dir/.local/bin"

  make_stub "$bin_dir/aoe"
  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
  cat >>"$bin_dir/update-agent-tools" <<'STUB'
set -euo pipefail

printf 'update-agent-tools %s\n' "$*" >>"$COMMAND_LOG"
STUB
  chmod +x "$bin_dir/update-agent-tools"

  run_activation "$test_dir" \
    || fail "fresh-workstation handoff exited nonzero"

  diff -u \
    <(printf 'update-agent-tools --yes\n') \
    "$test_dir/command-log" \
    || fail "fresh-workstation handoff did not install the complete toolchain"
}

test_complete_toolchain_is_not_refreshed_during_bootstrap() {
  local test_dir
  local bin_dir
  local command
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  bin_dir="$test_dir/.local/bin"

  for command in \
    aoe codex claude pi codex-acp claude-agent-acp pi-acp; do
    make_stub "$bin_dir/$command"
  done
  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
  cat >>"$bin_dir/update-agent-tools" <<'STUB'
set -euo pipefail

printf 'update-agent-tools %s\n' "$*" >>"$COMMAND_LOG"
STUB
  chmod +x "$bin_dir/update-agent-tools"

  run_activation "$test_dir" \
    || fail "complete-toolchain handoff exited nonzero"

  [[ ! -e "$test_dir/command-log" ]] \
    || fail "bootstrap refreshed an already-complete toolchain"
}

test_failed_install_fails_the_bootstrap_handoff() {
  local test_dir
  local bin_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  bin_dir="$test_dir/.local/bin"

  make_stub "$bin_dir/aoe"
  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
  cat >>"$bin_dir/update-agent-tools" <<'STUB'
exit 23
STUB
  chmod +x "$bin_dir/update-agent-tools"

  if run_activation "$test_dir"; then
    fail "failed agent-tool installation was accepted by the bootstrap handoff"
  fi
}

test_updater_lock_tool_is_reachable_from_the_bootstrap_handoff() {
  local test_dir
  local bin_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  bin_dir="$test_dir/.local/bin"

  make_stub "$bin_dir/aoe"
  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
  cat >>"$bin_dir/update-agent-tools" <<'STUB'
set -euo pipefail

command -v flock >/dev/null 2>&1 || exit 23
printf 'update-agent-tools %s\n' "$*" >>"$COMMAND_LOG"
STUB
  chmod +x "$bin_dir/update-agent-tools"

  run_activation "$test_dir" \
    || fail "handoff ran the updater without its flock lock tool on PATH"
}

# shellcheck source=tests/lib/suite-dispatch.bash
source "$REPO_ROOT/tests/lib/suite-dispatch.bash"

readonly test_cases=(
  test_missing_tools_are_installed_by_the_bootstrap_handoff
  test_complete_toolchain_is_not_refreshed_during_bootstrap
  test_updater_lock_tool_is_reachable_from_the_bootstrap_handoff
  test_failed_install_fails_the_bootstrap_handoff
)

suite_dispatch 'workstation agent-tool bootstrap handoff' "$@"
