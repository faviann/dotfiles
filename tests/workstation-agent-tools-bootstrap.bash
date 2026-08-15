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

activation_ordering() {
  if [[ -n "${TEST_BOOTSTRAP_ACTIVATION_AFTER:-}" ]]; then
    cat "$TEST_BOOTSTRAP_ACTIVATION_AFTER"
    return
  fi

  nix eval --json \
    "$REPO_ROOT#homeConfigurations.workstation.config.home.activation.bootstrapAgentTools.after"
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

test_bootstrap_handoff_runs_after_the_profile_exists() {
  local after

  after="$(activation_ordering)" \
    || fail "could not read the bootstrap handoff ordering"

  jq -e 'index("installPackages")' >/dev/null <<<"$after" \
    || fail "handoff must run after installPackages, or home.packages tools are missing from the profile it reads"
}

# The updater's other dependencies come from the profile (npm) or Home Manager's
# own activation PATH (jq, sed, date, mktemp); these two have no other source.
readonly updater_host_tools=(flock curl)

test_updater_host_tools_are_reachable_from_the_bootstrap_handoff() {
  local test_dir
  local bin_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  bin_dir="$test_dir/.local/bin"

  make_stub "$bin_dir/aoe"
  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
  cat >>"$bin_dir/update-agent-tools" <<'STUB'
set -euo pipefail

for tool in $UPDATER_HOST_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || { printf '%s\n' "$tool" >"$COMMAND_LOG.missing"; exit 23; }
done
printf 'update-agent-tools %s\n' "$*" >>"$COMMAND_LOG"
STUB
  chmod +x "$bin_dir/update-agent-tools"

  UPDATER_HOST_TOOLS="${updater_host_tools[*]}" run_activation "$test_dir" \
    || fail "handoff ran the updater without $(cat "$test_dir/command-log.missing" 2>/dev/null || printf 'its host tools') on PATH"
}

# shellcheck source=tests/lib/suite-dispatch.bash
source "$REPO_ROOT/tests/lib/suite-dispatch.bash"

readonly test_cases=(
  test_missing_tools_are_installed_by_the_bootstrap_handoff
  test_complete_toolchain_is_not_refreshed_during_bootstrap
  test_bootstrap_handoff_runs_after_the_profile_exists
  test_updater_host_tools_are_reachable_from_the_bootstrap_handoff
  test_failed_install_fails_the_bootstrap_handoff
)

suite_dispatch 'workstation agent-tool bootstrap handoff' "$@"
