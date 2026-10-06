#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}
REAL_BASH="$(command -v bash)"
readonly REAL_BASH

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

  # Home Manager provides run; the fixture models its dry-run handoff.
  cat >"$script_path" <<'HELPER'
run() {
  if [[ -z "${DRY_RUN_CMD:-}" ]]; then
    "$@"
  fi
}
HELPER
  activation_script >>"$script_path"
  if [[ "${TEST_ISOLATE_ACTIVATION_PATH:-0}" == "1" ]]; then
    # The rendered PATH names the real profile by absolute path, so a probe for a
    # tool this workstation happens to have would pass on host state instead of
    # on the fixture. Tool-probe cases keep only the fixture's own bin.
    # $HOME stays literal: the activation script expands it against the fixture.
    # shellcheck disable=SC2016
    sed -i 's#^export PATH=.*#export PATH="$HOME/.local/bin"#' "$script_path"
  fi
  chmod +x "$script_path"
  env \
    HOME="$home" \
    XDG_STATE_HOME="$home/state" \
    PATH= \
    DRY_RUN_CMD="${TEST_DRY_RUN_CMD:-}" \
    VERBOSE_ARG= \
    COMMAND_LOG="$home/command-log" \
    "$REAL_BASH" "$script_path"
}

@test "test_missing_tools_are_installed_by_the_bootstrap_handoff" {
  local test_dir
  local bin_dir
  test_dir="$(mktemp -d)"
  bin_dir="$test_dir/.local/bin"
  mkdir -p "$bin_dir"

  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
  cat >>"$bin_dir/update-agent-tools" <<'STUB'
set -euo pipefail

printf 'update-agent-tools%s\n' "${*:+ $*}" >>"$COMMAND_LOG"
STUB
  chmod +x "$bin_dir/update-agent-tools"

  TEST_ISOLATE_ACTIVATION_PATH=1 run_activation "$test_dir" \
    || fail "fresh-workstation handoff exited nonzero"

  diff -u \
    <(printf 'update-agent-tools\n') \
    "$test_dir/command-log" \
    || fail "fresh-workstation handoff did not install the complete toolchain"
}

@test "test_complete_toolchain_is_not_refreshed_during_bootstrap" {
  local test_dir
  local bin_dir
  local command
  test_dir="$(mktemp -d)"
  bin_dir="$test_dir/.local/bin"

  for command in \
    bun codex claude pi opencode omp; do
    make_stub "$bin_dir/$command"
  done
  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
  cat >>"$bin_dir/update-agent-tools" <<'STUB'
set -euo pipefail

printf 'update-agent-tools%s\n' "${*:+ $*}" >>"$COMMAND_LOG"
STUB
  chmod +x "$bin_dir/update-agent-tools"

  TEST_ISOLATE_ACTIVATION_PATH=1 run_activation "$test_dir" \
    || fail "complete-toolchain handoff exited nonzero"

  [[ ! -e "$test_dir/command-log" ]] \
    || fail "bootstrap refreshed an already-complete toolchain"
}

@test "test_missing_new_harnesses_are_repaired_by_the_bootstrap_handoff" {
  local bin_dir
  local command
  local missing_harness
  local test_dir

  for missing_harness in opencode omp bun; do
    test_dir="$(mktemp -d)"
    bin_dir="$test_dir/.local/bin"
    for command in \
      bun codex claude pi opencode omp; do
      if [[ "$command" != "$missing_harness" ]]; then
        make_stub "$bin_dir/$command"
      fi
    done
    printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
    cat >>"$bin_dir/update-agent-tools" <<'STUB'
set -euo pipefail

printf 'update-agent-tools%s\n' "${*:+ $*}" >>"$COMMAND_LOG"
STUB
    chmod +x "$bin_dir/update-agent-tools"

    TEST_ISOLATE_ACTIVATION_PATH=1 run_activation "$test_dir" \
      || fail "missing-$missing_harness bootstrap handoff exited nonzero"
    diff -u \
      <(printf 'update-agent-tools\n') \
      "$test_dir/command-log" \
      || fail "missing $missing_harness did not trigger the bootstrap handoff"
    rm -rf "$test_dir"
  done
}

@test "test_failed_install_fails_the_bootstrap_handoff" {
  local test_dir
  local bin_dir
  test_dir="$(mktemp -d)"
  bin_dir="$test_dir/.local/bin"
  mkdir -p "$bin_dir"

  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
  cat >>"$bin_dir/update-agent-tools" <<'STUB'
exit 23
STUB
  chmod +x "$bin_dir/update-agent-tools"

  if run_activation "$test_dir"; then
    fail "failed agent-tool installation was accepted by the bootstrap handoff"
  fi
}

@test "test_bootstrap_handoff_runs_after_the_profile_exists" {
  local after

  after="$(activation_ordering)" \
    || fail "could not read the bootstrap handoff ordering"

  jq -e 'index("installPackages")' >/dev/null <<<"$after" \
    || fail "handoff must run after installPackages, or home.packages tools are missing from the profile it reads"
}

# The updater's other dependencies come from the profile (npm) or Home Manager's
# own activation PATH (bash, coreutils, grep); these have no other source.
readonly updater_host_tools=(flock curl unzip)

@test "test_updater_host_tools_are_reachable_from_the_bootstrap_handoff" {
  local test_dir
  local bin_dir
  test_dir="$(mktemp -d)"
  bin_dir="$test_dir/.local/bin"
  mkdir -p "$bin_dir"

  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
  cat >>"$bin_dir/update-agent-tools" <<'STUB'
set -euo pipefail

for tool in $UPDATER_HOST_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || { printf '%s\n' "$tool" >"$COMMAND_LOG.missing"; exit 23; }
done
printf 'update-agent-tools%s\n' "${*:+ $*}" >>"$COMMAND_LOG"
STUB
  chmod +x "$bin_dir/update-agent-tools"

  UPDATER_HOST_TOOLS="${updater_host_tools[*]}" run_activation "$test_dir" \
    || fail "handoff ran the updater without $(cat "$test_dir/command-log.missing" 2>/dev/null || printf 'its host tools') on PATH"
}

@test "test_bootstrap_dry_run_does_not_install_missing_tools" {
  local test_dir="$BATS_TEST_TMPDIR/home"
  mkdir -p "$test_dir/.local/bin"
  # shellcheck disable=SC2016
  printf '#!%s\nprintf installed >"$HOME/installed"\n' "$REAL_BASH" \
    >"$test_dir/.local/bin/update-agent-tools"
  chmod +x "$test_dir/.local/bin/update-agent-tools"

  TEST_DRY_RUN_CMD=echo TEST_ISOLATE_ACTIVATION_PATH=1 run_activation "$test_dir"

  [[ ! -e "$test_dir/installed" ]]
}
