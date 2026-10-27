#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}
REAL_BASH="$(command -v bash)"
readonly REAL_BASH

readonly profiles=(workstation desktop)

bootstrap_probed_commands() {
  case "$1" in
    workstation) printf '%s\n' bun codex claude opencode pi ;;
    desktop) printf '%s\n' bun codex claude opencode ;;
  esac
}

activation_script() {
  local profile="$1"

  if [[ -n "${TEST_BOOTSTRAP_ACTIVATIONS:-}" ]]; then
    cat "$TEST_BOOTSTRAP_ACTIVATIONS/$profile/data"
    return
  fi

  nix eval --raw \
    "$REPO_ROOT#homeConfigurations.$profile.config.home.activation.bootstrapAgentTools.data"
}

activation_ordering() {
  local profile="$1"

  if [[ -n "${TEST_BOOTSTRAP_ACTIVATIONS:-}" ]]; then
    cat "$TEST_BOOTSTRAP_ACTIVATIONS/$profile/after.json"
    return
  fi

  nix eval --json \
    "$REPO_ROOT#homeConfigurations.$profile.config.home.activation.bootstrapAgentTools.after"
}

make_stub() {
  local path="$1"

  mkdir -p "$(dirname "$path")"
  printf '#!%s\nexit 0\n' "$REAL_BASH" >"$path"
  chmod +x "$path"
}

make_logging_updater() {
  local bin_dir="$1"

  mkdir -p "$bin_dir"
  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/update-agent-tools"
  cat >>"$bin_dir/update-agent-tools" <<'STUB'
set -euo pipefail

printf 'update-agent-tools%s\n' "${*:+ $*}" >>"$COMMAND_LOG"
STUB
  chmod +x "$bin_dir/update-agent-tools"
}

run_activation() {
  local home="$1"
  local profile="$2"
  local script_path="$home/bootstrap-agent-tools"

  # Home Manager provides run; the fixture models its dry-run handoff.
  cat >"$script_path" <<'HELPER'
run() {
  if [[ -z "${DRY_RUN_CMD:-}" ]]; then
    "$@"
  fi
}
HELPER
  activation_script "$profile" >>"$script_path"
  if [[ "${TEST_ISOLATE_ACTIVATION_PATH:-0}" == "1" ]]; then
    # The rendered PATH names the real profile by absolute path, so a probe for a
    # tool this workstation happens to have would pass on host state instead of
    # on the fixture. Tool-probe cases keep only the fixture's own bin.
    # $HOME stays literal: the activation script expands it against the fixture.
    # shellcheck disable=SC2016
    sed -i 's#^export PATH=.*#export PATH="$HOME/.local/bin"#' "$script_path"
  elif [[ "${TEST_DROP_PROFILE_PATH:-0}" == "1" ]]; then
    sed -i 's#:/[^:]*/\.nix-profile/bin:#:#' "$script_path"
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
  local profile
  local test_dir

  for profile in "${profiles[@]}"; do
    test_dir="$(mktemp -d)"
    make_logging_updater "$test_dir/.local/bin"

    TEST_ISOLATE_ACTIVATION_PATH=1 run_activation "$test_dir" "$profile" \
      || fail "fresh $profile handoff exited nonzero"

    diff -u \
      <(printf 'update-agent-tools\n') \
      "$test_dir/command-log" \
      || fail "fresh $profile handoff did not install the complete toolchain"
  done
}

@test "test_complete_toolchain_is_not_refreshed_during_bootstrap" {
  local command
  local profile
  local test_dir

  for profile in "${profiles[@]}"; do
    test_dir="$(mktemp -d)"
    while read -r command; do
      make_stub "$test_dir/.local/bin/$command"
    done < <(bootstrap_probed_commands "$profile")
    make_logging_updater "$test_dir/.local/bin"

    TEST_ISOLATE_ACTIVATION_PATH=1 run_activation "$test_dir" "$profile" \
      || fail "complete-toolchain $profile handoff exited nonzero"

    [[ ! -e "$test_dir/command-log" ]] \
      || fail "$profile bootstrap refreshed a toolchain of exactly $(bootstrap_probed_commands "$profile" | xargs)"
  done
}

@test "test_any_missing_profile_command_triggers_the_bootstrap_handoff" {
  local command
  local missing
  local profile
  local test_dir

  for profile in "${profiles[@]}"; do
    while read -r missing; do
      test_dir="$(mktemp -d)"
      while read -r command; do
        if [[ "$command" != "$missing" ]]; then
          make_stub "$test_dir/.local/bin/$command"
        fi
      done < <(bootstrap_probed_commands "$profile")
      make_logging_updater "$test_dir/.local/bin"

      TEST_ISOLATE_ACTIVATION_PATH=1 run_activation "$test_dir" "$profile" \
        || fail "missing-$missing $profile handoff exited nonzero"
      diff -u \
        <(printf 'update-agent-tools\n') \
        "$test_dir/command-log" \
        || fail "missing $missing did not trigger the $profile bootstrap handoff"
      rm -rf "$test_dir"
    done < <(bootstrap_probed_commands "$profile")
  done
}

@test "test_failed_install_fails_the_bootstrap_handoff" {
  local profile
  local test_dir

  for profile in "${profiles[@]}"; do
    test_dir="$(mktemp -d)"
    mkdir -p "$test_dir/.local/bin"
    printf '#!%s\nexit 23\n' "$REAL_BASH" >"$test_dir/.local/bin/update-agent-tools"
    chmod +x "$test_dir/.local/bin/update-agent-tools"

    if run_activation "$test_dir" "$profile"; then
      fail "failed agent-tool installation was accepted by the $profile bootstrap handoff"
    fi
  done
}

@test "test_bootstrap_handoff_runs_after_the_profile_exists" {
  local after
  local profile

  for profile in "${profiles[@]}"; do
    after="$(activation_ordering "$profile")" \
      || fail "could not read the $profile bootstrap handoff ordering"

    jq -e 'index("installPackages")' >/dev/null <<<"$after" \
      || fail "$profile handoff must run after installPackages, or home.packages tools are missing from the profile it reads"
  done
}

readonly updater_host_tools=(flock curl unzip git)

@test "test_updater_host_tools_are_reachable_from_the_bootstrap_handoff" {
  local profile
  local test_dir

  for profile in "${profiles[@]}"; do
    test_dir="$(mktemp -d)"
    mkdir -p "$test_dir/.local/bin"
    printf '#!%s\n' "$REAL_BASH" >"$test_dir/.local/bin/update-agent-tools"
    cat >>"$test_dir/.local/bin/update-agent-tools" <<'STUB'
set -euo pipefail

for tool in $UPDATER_HOST_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || { printf '%s\n' "$tool" >"$COMMAND_LOG.missing"; exit 23; }
done
printf 'update-agent-tools%s\n' "${*:+ $*}" >>"$COMMAND_LOG"
STUB
    chmod +x "$test_dir/.local/bin/update-agent-tools"

    UPDATER_HOST_TOOLS="${updater_host_tools[*]}" TEST_DROP_PROFILE_PATH=1 \
      run_activation "$test_dir" "$profile" \
      || fail "$profile handoff ran the updater without $(cat "$test_dir/command-log.missing" 2>/dev/null || printf 'its host tools') on PATH"
  done
}

@test "test_bootstrap_dry_run_does_not_install_missing_tools" {
  local profile
  local test_dir

  for profile in "${profiles[@]}"; do
    test_dir="$BATS_TEST_TMPDIR/home-$profile"
    mkdir -p "$test_dir/.local/bin"
    # shellcheck disable=SC2016
    printf '#!%s\nprintf installed >"$HOME/installed"\n' "$REAL_BASH" \
      >"$test_dir/.local/bin/update-agent-tools"
    chmod +x "$test_dir/.local/bin/update-agent-tools"

    TEST_DRY_RUN_CMD=echo TEST_ISOLATE_ACTIVATION_PATH=1 run_activation "$test_dir" "$profile"

    [[ ! -e "$test_dir/installed" ]] \
      || fail "$profile dry run installed the missing tools"
  done
}
