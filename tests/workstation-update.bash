#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly COMMAND="$REPO_ROOT/dot_local/bin/executable_workstation-update"
REAL_CHEZMOI="$(command -v chezmoi)"
readonly REAL_CHEZMOI
readonly CANONICAL_ORIGIN='git@github.com:faviann/dotfiles.git'

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

write_agent_tools_fixture() {
  local path="$1"
  local version="$2"

  printf '#!/usr/bin/env bash\nset -euo pipefail\nreadonly FIXTURE_VERSION=%q\n' \
    "$version" >"$path"
  cat >>"$path" <<'STUB'
printf 'update-agent-tools %s' "$FIXTURE_VERSION" >>"$AGENT_TOOLS_LOG"
printf ' %q' "$@" >>"$AGENT_TOOLS_LOG"
printf '\n' >>"$AGENT_TOOLS_LOG"
printf 'update-agent-tools %s' "$FIXTURE_VERSION" >>"$PHASE_LOG"
printf ' %q' "$@" >>"$PHASE_LOG"
printf '\n' >>"$PHASE_LOG"

if [[ -n "${TEST_AGENT_GATE:-}" ]]; then
  : >"$TEST_AGENT_GATE.ready"
  while [[ ! -e "$TEST_AGENT_GATE.release" ]]; do
    /usr/bin/sleep 0.01
  done
fi

if [[ "${TEST_AGENT_CHECK_FAIL:-0}" == 1 ]]; then
  printf 'update-agent-tools: discovery phase failed: AoE; correct the problem, then rerun workstation-update\n' >&2
  exit 31
fi

if [[ "${TEST_AGENT_ACP_RUNNING:-0}" == 1 && "$*" != *'--yes'* ]]; then
  printf 'update-agent-tools: 1 running ACP session would be disrupted; rerun workstation-update --yes to authorize replacement\n' >&2
  exit 33
fi

if [[ "${TEST_AGENT_OUTDATED:-0}" == 1 ]]; then
  printf 'agent-tools mutation %s\n' "$FIXTURE_VERSION" >>"$AGENT_TOOLS_LOG"
  if [[ "${TEST_AGENT_UPDATE_FAIL:-0}" == 1 ]]; then
    printf 'injected agent-tool update failure\n' >&2
    exit 32
  fi
  : >"$HOME/agent-tools-updated"
fi
STUB
  chmod +x "$path"
}

make_fixture() {
  local test_dir="$1"
  local home="$test_dir/home"
  local remote="$test_dir/remote.git"
  local seed="$test_dir/seed"
  local source="$test_dir/discovered/source"
  local global_config="$test_dir/gitconfig"

  mkdir -p "$home/stubs" "$home/state" \
    "$home/.local/state/workstation-setup" \
    "$(dirname "$source")"
  : >"$home/.local/state/workstation-setup/complete"
  : >"$global_config"
  git config --file "$global_config" user.name 'Test Operator'
  git config --file "$global_config" user.email 'operator@example.test'

  GIT_CONFIG_GLOBAL="$global_config" \
    git init --bare --quiet --initial-branch=main "$remote"
  GIT_CONFIG_GLOBAL="$global_config" \
    git init --quiet --initial-branch=main "$seed"
  mkdir -p "$seed/dot_local/bin"
  printf 'ignored-local\n' >"$seed/.gitignore"
  write_agent_tools_fixture \
    "$seed/dot_local/bin/executable_update-agent-tools" v1
  printf '#!/usr/bin/env bash\nprintf "workstation update v1\\n"\n' \
    >"$seed/dot_local/bin/executable_workstation-update"
  printf 'managed v1\n' >"$seed/dot_managed"
  chmod +x "$seed/dot_local/bin/"executable_*
  GIT_CONFIG_GLOBAL="$global_config" git -C "$seed" add .
  GIT_CONFIG_GLOBAL="$global_config" \
    git -C "$seed" commit --quiet -m initial
  GIT_CONFIG_GLOBAL="$global_config" \
    git -C "$seed" remote add origin "file://$remote"
  GIT_CONFIG_GLOBAL="$global_config" \
    git -C "$seed" push --quiet --set-upstream origin main
  GIT_CONFIG_GLOBAL="$global_config" \
    git clone --quiet "file://$remote" "$source"
  GIT_CONFIG_GLOBAL="$global_config" \
    git -C "$source" remote set-url origin "$CANONICAL_ORIGIN"

  cat >"$home/stubs/chezmoi" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'chezmoi' >>"$COMMAND_LOG"
printf ' %q' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
printf 'chezmoi' >>"$PHASE_LOG"
printf ' %q' "$@" >>"$PHASE_LOG"
printf '\n' >>"$PHASE_LOG"
if [[ "${TEST_FAIL_DRY_RUN:-0}" == 1 \
  && "$*" == 'apply --dry-run --verbose' ]]; then
  printf 'injected dry-run failure\n' >&2
  exit 42
fi
if [[ "${TEST_FAIL_APPLY:-0}" == 1 && "$*" == apply ]]; then
  printf 'injected apply failure\n' >&2
  exit 43
fi
"$TEST_REAL_CHEZMOI" \
  --source "$SOURCE_REPO" \
  --destination "$HOME" \
  --config /dev/null \
  --config-format toml \
  --persistent-state "$XDG_STATE_HOME/chezmoistate.boltdb" \
  "$@"
if [[ "${TEST_DRIFT_AFTER_APPLY:-0}" == 1 \
  && "$1" == apply && "$*" != *'--dry-run'* ]]; then
  printf 'post-apply drift\n' >"$HOME/.managed"
fi
STUB

  cat >"$home/stubs/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${TEST_SSH_FETCH_FAIL:-0}" == 1 ]]; then
  printf 'injected SSH fetch failure\n' >&2
  exit 66
fi
exec /usr/bin/git-upload-pack "$TEST_REMOTE_REPO"
STUB
  chmod +x "$home/stubs/chezmoi" "$home/stubs/ssh"
}

run_update() {
  local test_dir="$1"
  shift

  HOME="$test_dir/home" \
    XDG_STATE_HOME="$test_dir/home/state" \
    PATH="$test_dir/home/stubs:/usr/bin:/bin" \
    COMMAND_LOG="$test_dir/home/command-log" \
    TEST_REAL_CHEZMOI="$REAL_CHEZMOI" \
    SOURCE_REPO="$test_dir/discovered/source" \
    TEST_REMOTE_REPO="$test_dir/remote.git" \
    GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_SSH_VARIANT=ssh \
    GIT_TERMINAL_PROMPT=0 \
    TEST_SSH_FETCH_FAIL="${TEST_SSH_FETCH_FAIL:-0}" \
    TEST_FAIL_DRY_RUN="${TEST_FAIL_DRY_RUN:-0}" \
    TEST_FAIL_APPLY="${TEST_FAIL_APPLY:-0}" \
    TEST_DRIFT_AFTER_APPLY="${TEST_DRIFT_AFTER_APPLY:-0}" \
    AGENT_TOOLS_LOG="$test_dir/home/agent-tools-log" \
    PHASE_LOG="$test_dir/home/phase-log" \
    TEST_AGENT_CHECK_FAIL="${TEST_AGENT_CHECK_FAIL:-0}" \
    TEST_AGENT_ACP_RUNNING="${TEST_AGENT_ACP_RUNNING:-0}" \
    TEST_AGENT_OUTDATED="${TEST_AGENT_OUTDATED:-0}" \
    TEST_AGENT_UPDATE_FAIL="${TEST_AGENT_UPDATE_FAIL:-0}" \
    TEST_AGENT_GATE="${TEST_AGENT_GATE:-}" \
    bash "$COMMAND" "$@" </dev/null \
      >"$test_dir/home/stdout" 2>"$test_dir/home/stderr"
}

run_chezmoi() {
  local test_dir="$1"
  shift

  HOME="$test_dir/home" \
    XDG_STATE_HOME="$test_dir/home/state" \
    "$REAL_CHEZMOI" \
      --source "$test_dir/discovered/source" \
      --destination "$test_dir/home" \
      --config /dev/null \
      --config-format toml \
      --persistent-state "$test_dir/home/state/chezmoistate.boltdb" \
      "$@"
}

source_commit() {
  GIT_CONFIG_GLOBAL="$1/gitconfig" \
    git -C "$1/discovered/source" rev-parse HEAD
}

write_applied_marker() {
  local test_dir="$1"

  mkdir -p "$test_dir/home/state/workstation-update"
  source_commit "$test_dir" \
    >"$test_dir/home/state/workstation-update/applied-commit"
}

publish_managed_version() {
  local test_dir="$1"
  local version="$2"
  local seed="$test_dir/seed"

  printf 'managed %s\n' "$version" >"$seed/dot_managed"
  write_agent_tools_fixture \
    "$seed/dot_local/bin/executable_update-agent-tools" "$version"
  printf '#!/usr/bin/env bash\nprintf "workstation update %s\\n"\n' "$version" \
    >"$seed/dot_local/bin/executable_workstation-update"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" git -C "$seed" add .
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$seed" commit --quiet -m "publish $version"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$seed" push --quiet origin main
}

assert_update_fails_with() {
  local test_dir="$1"
  local expected="$2"

  if run_update "$test_dir"; then
    fail "update unexpectedly succeeded; expected: $expected"
  fi
  grep -Fq "$expected" "$test_dir/home/stderr" \
    || fail "missing diagnostic '$expected': $(<"$test_dir/home/stderr")"
}

test_setup_must_be_complete_before_source_discovery() {
  local test_dir
  local status=0

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  mkdir -p "$test_dir/home/stubs"

  cat >"$test_dir/home/stubs/chezmoi" <<'STUB'
#!/usr/bin/env bash
printf 'chezmoi %s\n' "$*" >>"$COMMAND_LOG"
exit 64
STUB
  chmod +x "$test_dir/home/stubs/chezmoi"

  HOME="$test_dir/home" \
    XDG_STATE_HOME="$test_dir/home/state" \
    PATH="$test_dir/home/stubs:/usr/bin:/bin" \
    COMMAND_LOG="$test_dir/home/command-log" \
    bash "$COMMAND" \
      >"$test_dir/home/stdout" 2>"$test_dir/home/stderr" || status=$?

  [[ "$status" -ne 0 ]] || fail 'incomplete setup was accepted'
  grep -Fq 'workstation-update: setup phase failed: setup is incomplete' \
    "$test_dir/home/stderr" \
    || fail "missing setup diagnostic: $(<"$test_dir/home/stderr")"
  [[ ! -e "$test_dir/home/command-log" ]] \
    || fail 'source discovery ran before the setup gate'
}

test_first_run_adopts_verified_equal_history() {
  local test_dir
  local expected_commit
  local marker

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  rm -f "$test_dir/home/command-log"
  expected_commit="$(source_commit "$test_dir")"
  marker="$test_dir/home/state/workstation-update/applied-commit"

  run_update "$test_dir" \
    || fail "verified first run failed: $(<"$test_dir/home/stderr")"

  [[ -f "$marker" ]] || fail 'verified first run did not create a marker'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'verified first run did not adopt the current commit'
  [[ "$(<"$test_dir/home/.managed")" == 'managed v1' ]] \
    || fail 'verified first run changed an already-current target'
  diff -u \
    <(printf '%s\n' 'chezmoi source-path' 'chezmoi verify') \
    "$test_dir/home/command-log" \
    || fail 'verified first run invoked apply'
}

test_current_agent_tools_are_checked_without_mutation() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  rm -f "$test_dir/home/command-log"

  run_update "$test_dir" \
    || fail "current agent-tool check failed: $(<"$test_dir/home/stderr")"

  diff -u \
    <(printf '%s\n' 'update-agent-tools v1 --update-if-needed') \
    "$test_dir/home/agent-tools-log" \
    || fail 'current agent-tool phase did not use the managed executable'
  [[ ! -e "$test_dir/home/agent-tools-updated" ]] \
    || fail 'current agent tools were mutated'
}

test_yes_forwards_only_agent_disruption_consent() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  rm -f "$test_dir/home/command-log"

  run_update "$test_dir" --yes \
    || fail "--yes update failed: $(<"$test_dir/home/stderr")"

  diff -u \
    <(printf '%s\n' 'update-agent-tools v1 --update-if-needed --yes') \
    "$test_dir/home/agent-tools-log" \
    || fail '--yes was not forwarded as agent-tool disruption consent'
  ! grep -F -- '--yes' "$test_dir/home/command-log" >/dev/null \
    || fail '--yes was forwarded to chezmoi'
}

test_agent_consent_refusal_names_only_the_unified_retry() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  rm -f "$test_dir/home/command-log"

  if TEST_AGENT_OUTDATED=1 TEST_AGENT_ACP_RUNNING=1 \
    run_update "$test_dir"; then
    fail 'agent consent refusal exited zero'
  fi

  grep -Fq 'rerun workstation-update --yes to authorize replacement' \
    "$test_dir/home/stderr" \
    || fail 'agent consent refusal did not name the unified --yes retry'
  ! grep -Fq 'rerun with --yes' "$test_dir/home/stderr" \
    || fail 'agent consent refusal named the subordinate retry'
  ! grep -Fq 'update-agent-tools --yes' "$test_dir/home/stderr" \
    || fail 'agent consent refusal exposed the subordinate command'
  [[ ! -e "$test_dir/home/agent-tools-updated" ]] \
    || fail 'agent consent refusal mutated the toolchain'

  TEST_AGENT_OUTDATED=1 TEST_AGENT_ACP_RUNNING=1 \
    run_update "$test_dir" --yes \
    || fail "unified --yes retry failed: $(<"$test_dir/home/stderr")"
  [[ -e "$test_dir/home/agent-tools-updated" ]] \
    || fail 'unified --yes retry did not update the toolchain'
}

test_agent_discovery_failure_preserves_applied_dotfiles_for_retry() {
  local expected_commit
  local marker
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  publish_managed_version "$test_dir" v2
  expected_commit="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/seed" rev-parse HEAD)"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  rm -f "$test_dir/home/command-log"

  if TEST_AGENT_CHECK_FAIL=1 run_update "$test_dir"; then
    fail 'agent discovery failure exited zero'
  fi

  [[ "$(source_commit "$test_dir")" == "$expected_commit" ]] \
    || fail 'agent discovery failure rolled back dotfiles history'
  [[ "$(<"$test_dir/home/.managed")" == 'managed v2' ]] \
    || fail 'agent discovery failure rolled back applied dotfiles'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'agent discovery failure discarded dotfiles success'
  [[ ! -e "$test_dir/home/agent-tools-updated" ]] \
    || fail 'agent discovery failure mutated the toolchain'
  grep -Fq 'agent-tools phase failed: update-agent-tools' \
    "$test_dir/home/stderr" \
    || fail 'agent discovery failure did not identify the pipeline phase'
  grep -Fq 'discovery phase failed: AoE' "$test_dir/home/stderr" \
    || fail 'agent discovery failure did not identify its component'
  grep -Fq 'rerun workstation-update' "$test_dir/home/stderr" \
    || fail 'agent discovery failure did not recommend the unified retry'
}

test_concurrent_update_is_rejected_without_queueing() {
  local first_pid
  local gate
  local test_dir
  local wait_attempt

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  rm -f "$test_dir/home/command-log"
  gate="$test_dir/agent-gate"

  TEST_AGENT_GATE="$gate" run_update "$test_dir" &
  first_pid=$!
  wait_attempt=1
  while [[ ! -e "$gate.ready" && "$wait_attempt" -le 500 ]]; do
    /usr/bin/sleep 0.01
    wait_attempt=$((wait_attempt + 1))
  done
  if [[ ! -e "$gate.ready" ]]; then
    : >"$gate.release"
    wait "$first_pid" || true
    fail 'first update did not reach the concurrency gate'
  fi

  if run_update "$test_dir"; then
    : >"$gate.release"
    wait "$first_pid" || true
    fail 'concurrent update was queued or accepted'
  fi
  grep -Fq 'lock phase failed: workstation-update is already running' \
    "$test_dir/home/stderr" \
    || fail 'concurrent rejection did not identify the lock phase'

  : >"$gate.release"
  wait "$first_pid" \
    || fail 'first update failed after releasing the concurrency gate'
  [[ "$(grep -c '^chezmoi source-path$' \
    "$test_dir/home/command-log")" -eq 1 ]] \
    || fail 'concurrent update reached source discovery before rejection'
}

test_outdated_agent_tools_use_the_latest_verified_updater() {
  local expected_commit
  local marker
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  publish_managed_version "$test_dir" v2
  expected_commit="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/seed" rev-parse HEAD)"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  rm -f "$test_dir/home/command-log" "$test_dir/home/phase-log"

  TEST_AGENT_OUTDATED=1 run_update "$test_dir" \
    || fail "outdated agent-tool update failed: $(<"$test_dir/home/stderr")"

  [[ -e "$test_dir/home/agent-tools-updated" ]] \
    || fail 'outdated agent tools were not updated'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'outdated agent-tool update lost the verified dotfiles marker'
  diff -u \
    <(printf '%s\n' \
      'chezmoi source-path' \
      'chezmoi apply --dry-run --verbose' \
      'chezmoi apply' \
      'chezmoi verify' \
      'update-agent-tools v2 --update-if-needed') \
    "$test_dir/home/phase-log" \
    || fail 'agent-tool update did not follow verified dotfiles in order'
  diff -u \
    <(printf '%s\n' \
      'update-agent-tools v2 --update-if-needed' \
      'agent-tools mutation v2') \
    "$test_dir/home/agent-tools-log" \
    || fail 'outdated update did not use the latest managed updater'
}

test_agent_update_failure_retries_without_reapplying_dotfiles() {
  local expected_commit
  local marker
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  expected_commit="$(source_commit "$test_dir")"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  rm -f "$test_dir/home/command-log" "$test_dir/home/phase-log"

  if TEST_AGENT_OUTDATED=1 TEST_AGENT_UPDATE_FAIL=1 \
    run_update "$test_dir"; then
    fail 'agent-tool update failure exited zero'
  fi

  [[ "$(source_commit "$test_dir")" == "$expected_commit" ]] \
    || fail 'agent-tool update failure changed dotfiles history'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'agent-tool update failure discarded dotfiles success'
  [[ ! -e "$test_dir/home/agent-tools-updated" ]] \
    || fail 'failed agent-tool update was accepted as complete'
  grep -Fq 'agent-tools phase failed: update-agent-tools' \
    "$test_dir/home/stderr" \
    || fail 'agent-tool update failure did not identify its phase'
  grep -Fq 'rerun workstation-update' "$test_dir/home/stderr" \
    || fail 'agent-tool update failure did not recommend unified retry'

  rm -f "$test_dir/home/command-log" "$test_dir/home/phase-log"
  TEST_AGENT_OUTDATED=1 run_update "$test_dir" \
    || fail "agent-tool retry failed: $(<"$test_dir/home/stderr")"

  [[ -e "$test_dir/home/agent-tools-updated" ]] \
    || fail 'agent-tool retry did not complete the update'
  ! grep -Fq 'chezmoi apply' "$test_dir/home/phase-log" \
    || fail 'agent-tool retry unnecessarily reapplied dotfiles'
  [[ "$(grep -c '^update-agent-tools v1 --update-if-needed$' \
    "$test_dir/home/agent-tools-log")" -eq 2 ]] \
    || fail 'agent-tool work was not retried through workstation-update'
}

test_unsupported_arguments_fail_before_maintenance() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"

  if run_update "$test_dir" --force; then
    fail 'unsupported argument was accepted'
  fi

  grep -Fq \
    'argument phase failed: expected no arguments or --yes; unsupported argument: --force' \
    "$test_dir/home/stderr" \
    || fail 'unsupported argument did not fail clearly'
  [[ ! -e "$test_dir/home/command-log" \
    && ! -e "$test_dir/home/agent-tools-log" ]] \
    || fail 'unsupported argument reached dotfiles or agent maintenance'

  if run_update "$test_dir" --yes --force; then
    fail 'unsupported multi-argument shape was accepted'
  fi

  grep -Fq \
    'argument phase failed: expected no arguments or --yes; unsupported argument: --force' \
    "$test_dir/home/stderr" \
    || fail 'multi-argument failure did not identify the offending argument'
}

test_dotfiles_failure_prevents_agent_tool_checks() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  publish_managed_version "$test_dir" v2
  rm -f "$test_dir/home/command-log" "$test_dir/home/agent-tools-log"

  if TEST_FAIL_APPLY=1 TEST_AGENT_OUTDATED=1 run_update "$test_dir"; then
    fail 'dotfiles apply failure exited zero'
  fi

  grep -Fq 'apply phase failed: chezmoi apply' "$test_dir/home/stderr" \
    || fail 'dotfiles failure did not identify the apply phase'
  grep -Fq 'rerun workstation-update' "$test_dir/home/stderr" \
    || fail 'dotfiles failure did not recommend unified retry'
  [[ ! -e "$test_dir/home/agent-tools-log" ]] \
    || fail 'dotfiles failure reached the agent-tool phase'
  [[ ! -e "$test_dir/home/agent-tools-updated" ]] \
    || fail 'dotfiles failure mutated the agent toolchain'
}

test_repository_structure_is_validated_before_fetch() {
  local test_dir
  local old_remote_tip
  local scenario

  for scenario in \
    wrong-origin multiple-origin rewritten-origin wrong-branch detached \
    missing-upstream; do
    test_dir="$(mktemp -d)"
    make_fixture "$test_dir"
    old_remote_tip="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" rev-parse origin/main)"
    publish_managed_version "$test_dir" v2

    case "$scenario" in
      wrong-origin)
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" remote set-url origin \
            git@github.com:someone-else/dotfiles.git
        assert_update_fails_with "$test_dir" 'origin must be'
        ;;
      multiple-origin)
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" remote set-url origin \
            "file://$test_dir/remote.git"
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" config --add \
            remote.origin.url "$CANONICAL_ORIGIN"
        assert_update_fails_with "$test_dir" \
          'origin must have exactly one URL'
        ;;
      rewritten-origin)
        git config --file "$test_dir/gitconfig" \
          "url.file://$test_dir/remote.git.insteadOf" "$CANONICAL_ORIGIN"
        assert_update_fails_with "$test_dir" \
          'effective origin must be canonical'
        ;;
      wrong-branch)
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" switch --quiet -c topic
        assert_update_fails_with "$test_dir" 'branch must be main'
        ;;
      detached)
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" switch --quiet --detach
        assert_update_fails_with "$test_dir" 'detached HEAD'
        ;;
      missing-upstream)
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" branch --unset-upstream
        assert_update_fails_with "$test_dir" 'upstream must be origin/main'
        ;;
    esac

    [[ "$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" rev-parse origin/main)" \
      == "$old_remote_tip" ]] \
      || fail "$scenario fetched before structural validation"
    if [[ -e "$test_dir/home/command-log" ]]; then
      ! grep -Fq ' apply' "$test_dir/home/command-log" \
        || fail "$scenario reached chezmoi apply"
    fi
    rm -rf "$test_dir"
  done
}

test_all_source_extras_and_unfinished_operations_are_preserved() {
  local test_dir
  local scenario
  local before_head
  local before_status
  local after_status
  local before_index_flags
  local after_index_flags
  local hidden_content
  local before_remote_tip
  local notes_partial
  local notes_ref
  local notes_worktree

  for scenario in \
    staged modified deleted untracked ignored assume-unchanged \
    skip-worktree unfinished-notes unfinished; do
    test_dir="$(mktemp -d)"
    make_fixture "$test_dir"

    case "$scenario" in
      staged)
        printf 'staged local work\n' \
          >>"$test_dir/discovered/source/dot_managed"
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" add dot_managed
        ;;
      modified)
        printf 'modified local work\n' \
          >>"$test_dir/discovered/source/dot_managed"
        ;;
      deleted)
        rm "$test_dir/discovered/source/dot_managed"
        ;;
      untracked)
        printf 'untracked local work\n' \
          >"$test_dir/discovered/source/local-notes"
        ;;
      ignored)
        printf 'ignored local work\n' \
          >"$test_dir/discovered/source/ignored-local"
        ;;
      assume-unchanged)
        printf 'hidden assume-unchanged work\n' \
          >>"$test_dir/discovered/source/dot_managed"
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" update-index \
            --assume-unchanged dot_managed
        ;;
      skip-worktree)
        printf 'hidden skip-worktree work\n' \
          >>"$test_dir/discovered/source/dot_managed"
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" update-index \
            --skip-worktree dot_managed
        ;;
      unfinished-notes)
        notes_partial="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" rev-parse \
            --path-format=absolute --git-path NOTES_MERGE_PARTIAL)"
        notes_ref="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" rev-parse \
            --path-format=absolute --git-path NOTES_MERGE_REF)"
        notes_worktree="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" rev-parse \
            --path-format=absolute --git-path NOTES_MERGE_WORKTREE)"
        printf 'partial notes merge\n' >"$notes_partial"
        printf 'refs/notes/commits\n' >"$notes_ref"
        mkdir "$notes_worktree"
        ;;
      unfinished)
        mkdir "$test_dir/discovered/source/.git/rebase-merge"
        ;;
    esac

    before_remote_tip="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" rev-parse origin/main)"
    publish_managed_version "$test_dir" v2
    before_head="$(source_commit "$test_dir")"
    before_status="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" status \
        --porcelain=v1 --untracked-files=all --ignored)"
    before_index_flags="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" ls-files -v dot_managed)"
    hidden_content=''
    if [[ "$scenario" == assume-unchanged \
      || "$scenario" == skip-worktree ]]; then
      hidden_content="$(<"$test_dir/discovered/source/dot_managed")"
      assert_update_fails_with "$test_dir" 'non-default index flags'
    elif [[ "$scenario" == unfinished \
      || "$scenario" == unfinished-notes ]]; then
      assert_update_fails_with "$test_dir" 'unfinished Git operation'
    else
      assert_update_fails_with "$test_dir" \
        'source repository has local content'
    fi
    after_status="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" status \
        --porcelain=v1 --untracked-files=all --ignored)"
    after_index_flags="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" ls-files -v dot_managed)"
    [[ "$(source_commit "$test_dir")" == "$before_head" ]] \
      || fail "$scenario changed the checked-out commit"
    [[ "$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" rev-parse origin/main)" \
      == "$before_remote_tip" ]] \
      || fail "$scenario fetched before rejecting local source state"
    [[ "$after_status" == "$before_status" ]] \
      || fail "$scenario changed the index, worktree, or extra content"
    [[ "$after_index_flags" == "$before_index_flags" ]] \
      || fail "$scenario changed the index flags"
    if [[ "$scenario" == assume-unchanged \
      || "$scenario" == skip-worktree ]]; then
      [[ "$(<"$test_dir/discovered/source/dot_managed")" \
        == "$hidden_content" ]] \
        || fail "$scenario changed the hidden local content"
    fi
    if [[ "$scenario" == unfinished ]]; then
      [[ -d "$test_dir/discovered/source/.git/rebase-merge" ]] \
        || fail 'unfinished operation metadata was discarded'
    elif [[ "$scenario" == unfinished-notes ]]; then
      [[ -f "$notes_partial" && -f "$notes_ref" \
        && -d "$notes_worktree" ]] \
        || fail 'unfinished notes-merge metadata was discarded'
    fi
    rm -rf "$test_dir"
  done
}

test_fetch_and_unsafe_history_fail_diagnostically() {
  local test_dir

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"
  TEST_SSH_FETCH_FAIL=1 \
    assert_update_fails_with "$test_dir" 'fetch phase failed'
  rm -rf "$test_dir"

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"
  printf 'unpublished\n' >"$test_dir/discovered/source/dot_unpublished"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" add dot_unpublished
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" commit --quiet -m unpublished
  assert_update_fails_with "$test_dir" 'ahead of origin/main by 1 commit(s)'
  rm -rf "$test_dir"

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"
  printf 'unpublished\n' >"$test_dir/discovered/source/dot_unpublished"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" add dot_unpublished
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" commit --quiet -m unpublished
  publish_managed_version "$test_dir" v2
  assert_update_fails_with "$test_dir" 'has diverged from origin/main'
  rm -rf "$test_dir"
}

test_behind_history_fast_forwards_then_applies_in_order() {
  local test_dir
  local expected_commit
  local marker

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  rm -f "$test_dir/home/command-log"
  publish_managed_version "$test_dir" v2
  expected_commit="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/seed" rev-parse HEAD)"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  cat >"$test_dir/discovered/source/.git/hooks/post-merge" <<HOOK
#!/usr/bin/env bash
printf 'post-merge invoked\n' >'$test_dir/post-merge-ran'
exit 97
HOOK
  chmod +x "$test_dir/discovered/source/.git/hooks/post-merge"

  run_update "$test_dir" \
    || fail "behind update failed: $(<"$test_dir/home/stderr")"

  [[ ! -e "$test_dir/post-merge-ran" ]] \
    || fail 'strictly behind update invoked merge behavior'
  [[ "$(source_commit "$test_dir")" == "$expected_commit" ]] \
    || fail 'strictly behind main was not fast-forwarded to origin/main'
  [[ -z "$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" status \
      --porcelain=v1 --untracked-files=all --ignored)" ]] \
    || fail 'fast-forwarded source did not finish clean'
  [[ "$(<"$test_dir/home/.managed")" == 'managed v2' ]] \
    || fail 'fast-forwarded source was not applied'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'verified fast-forward did not update the marker'
  diff -u \
    <(printf '%s\n' \
      'chezmoi source-path' \
      'chezmoi apply --dry-run --verbose' \
      'chezmoi apply' \
      'chezmoi verify') \
    "$test_dir/home/command-log" \
    || fail 'required apply did not run dry-run, apply, verify in order'
}

test_failed_ref_transaction_is_safe_to_retry() {
  local test_dir
  local old_commit
  local new_commit
  local old_index_tree
  local old_source_content
  local old_marker
  local marker
  local ref_path

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  old_commit="$(source_commit "$test_dir")"
  old_index_tree="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" write-tree)"
  old_source_content="$(<"$test_dir/discovered/source/dot_managed")"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  old_marker="$(<"$marker")"
  publish_managed_version "$test_dir" v2
  new_commit="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/seed" rev-parse HEAD)"
  ref_path="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" rev-parse \
      --path-format=absolute --git-path refs/heads/main)"
  : >"$ref_path.lock"
  rm -f "$test_dir/home/command-log"

  assert_update_fails_with "$test_dir" \
    'history phase failed: cannot prepare guarded main update'

  [[ "$(source_commit "$test_dir")" == "$old_commit" ]] \
    || fail 'failed ref preparation changed HEAD'
  [[ "$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" write-tree)" \
    == "$old_index_tree" ]] \
    || fail 'failed ref preparation changed the index'
  [[ "$(<"$test_dir/discovered/source/dot_managed")" \
    == "$old_source_content" ]] \
    || fail 'failed ref preparation changed source content'
  [[ -z "$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" status \
      --porcelain=v1 --untracked-files=all --ignored)" ]] \
    || fail 'failed ref preparation changed the worktree'
  [[ "$(<"$marker")" == "$old_marker" ]] \
    || fail 'failed ref preparation changed the applied marker'
  if [[ -e "$test_dir/home/command-log" ]]; then
    ! grep -Fq ' apply' "$test_dir/home/command-log" \
      || fail 'failed ref preparation reached chezmoi apply'
  fi

  rm "$ref_path.lock"
  rm -f "$test_dir/home/command-log"
  run_update "$test_dir" \
    || fail "safe ref retry failed: $(<"$test_dir/home/stderr")"

  [[ "$(source_commit "$test_dir")" == "$new_commit" ]] \
    || fail 'safe ref retry did not fast-forward main'
  [[ "$(<"$test_dir/home/.managed")" == 'managed v2' ]] \
    || fail 'safe ref retry did not apply the new target state'
  [[ "$(<"$marker")" == "$new_commit" ]] \
    || fail 'safe ref retry did not record verified success'
}

test_missing_maintenance_executable_enters_the_apply_path() {
  local test_dir
  local marker
  local expected_commit

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  expected_commit="$(source_commit "$test_dir")"
  rm "$test_dir/home/.local/bin/workstation-update"
  rm -f "$test_dir/home/command-log"

  assert_update_fails_with "$test_dir" 'dry-run phase failed'

  [[ ! -e "$test_dir/home/.local/bin/workstation-update" ]] \
    || fail 'unattended apply replaced a locally deleted executable'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'failed executable repair changed the prior marker'
  grep -Fqx 'chezmoi apply --dry-run --verbose' \
    "$test_dir/home/command-log" \
    || fail 'missing maintenance executable did not require apply'
}

test_drifted_maintenance_executable_enters_the_apply_path() {
  local test_dir
  local expected_commit
  local marker

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  expected_commit="$(source_commit "$test_dir")"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  printf 'operator-maintained version\n' \
    >"$test_dir/home/.local/bin/update-agent-tools"
  rm -f "$test_dir/home/command-log"

  assert_update_fails_with "$test_dir" 'dry-run phase failed'

  [[ "$(<"$test_dir/home/.local/bin/update-agent-tools")" \
    == 'operator-maintained version' ]] \
    || fail 'unattended apply overwrote a drifted maintenance executable'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'drifted executable failure changed the prior marker'
  grep -Fqx 'chezmoi apply --dry-run --verbose' \
    "$test_dir/home/command-log" \
    || fail 'drifted maintenance executable did not require apply'
}

test_matching_marker_does_not_reconcile_unrelated_target_drift() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  printf 'unrelated operator change\n' >"$test_dir/home/.managed"
  rm -f "$test_dir/home/command-log"

  run_update "$test_dir" \
    || fail "matching-marker check failed: $(<"$test_dir/home/stderr")"

  [[ "$(<"$test_dir/home/.managed")" == 'unrelated operator change' ]] \
    || fail 'matching marker reconciled unrelated target drift'
  ! grep -Fq ' apply' "$test_dir/home/command-log" \
    || fail 'matching marker applied unrelated target drift'
}

test_first_run_with_drift_enters_the_apply_path() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"

  run_update "$test_dir" \
    || fail "first-run apply failed: $(<"$test_dir/home/stderr")"

  [[ "$(<"$test_dir/home/.managed")" == 'managed v1' ]] \
    || fail 'first-run drift was not applied'
  diff -u \
    <(printf '%s\n' \
      'chezmoi source-path' \
      'chezmoi verify' \
      'chezmoi apply --dry-run --verbose' \
      'chezmoi apply' \
      'chezmoi verify') \
    "$test_dir/home/command-log" \
    || fail 'failed first-run verification did not enter the apply path'
}

test_unattended_overwrite_and_phase_failures_preserve_the_marker() {
  local test_dir
  local old_commit
  local marker

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  old_commit="$(source_commit "$test_dir")"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  publish_managed_version "$test_dir" v2
  printf 'operator change\n' >"$test_dir/home/.managed"
  rm -f "$test_dir/home/command-log"

  assert_update_fails_with "$test_dir" 'dry-run phase failed'
  [[ "$(<"$marker")" == "$old_commit" ]] \
    || fail 'failed unattended overwrite changed the prior marker'
  [[ "$(<"$test_dir/home/.managed")" == 'operator change' ]] \
    || fail 'unattended apply overwrote a locally modified target'
  ! grep -Fq -- '--force' "$test_dir/home/command-log" \
    || fail 'unattended apply authorized overwrite with force'

  printf 'managed v1\n' >"$test_dir/home/.managed"
  rm -f "$test_dir/home/command-log"
  run_update "$test_dir" \
    || fail "safe apply retry failed: $(<"$test_dir/home/stderr")"
  [[ "$(<"$test_dir/home/.managed")" == 'managed v2' ]] \
    || fail 'safe retry did not converge the corrected target'
  [[ "$(<"$marker")" == "$(source_commit "$test_dir")" ]] \
    || fail 'safe retry did not record verified success'
}

test_dry_run_and_verification_failures_are_safe_to_retry() {
  local test_dir
  local old_commit
  local marker

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  old_commit="$(source_commit "$test_dir")"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  publish_managed_version "$test_dir" v2
  rm -f "$test_dir/home/command-log"

  TEST_FAIL_DRY_RUN=1 \
    assert_update_fails_with "$test_dir" 'dry-run phase failed'
  [[ "$(<"$marker")" == "$old_commit" ]] \
    || fail 'dry-run failure changed the prior marker'
  [[ "$(<"$test_dir/home/.managed")" == 'managed v1' ]] \
    || fail 'dry-run failure changed a managed target'

  rm -f "$test_dir/home/command-log"
  TEST_FAIL_APPLY=1 \
    assert_update_fails_with "$test_dir" 'apply phase failed'
  [[ "$(<"$marker")" == "$old_commit" ]] \
    || fail 'apply failure changed the prior marker'
  [[ "$(<"$test_dir/home/.managed")" == 'managed v1' ]] \
    || fail 'injected apply failure changed a managed target'

  rm -f "$test_dir/home/command-log"
  TEST_DRIFT_AFTER_APPLY=1 \
    assert_update_fails_with "$test_dir" 'verification phase failed'
  [[ "$(<"$marker")" == "$old_commit" ]] \
    || fail 'verification failure changed the prior marker'
  [[ "$(<"$test_dir/home/.managed")" == 'post-apply drift' ]] \
    || fail 'verification fault injection did not create target drift'

  printf 'managed v2\n' >"$test_dir/home/.managed"
  rm -f "$test_dir/home/command-log"
  run_update "$test_dir" \
    || fail "verification retry failed: $(<"$test_dir/home/stderr")"
  [[ "$(<"$marker")" == "$(source_commit "$test_dir")" ]] \
    || fail 'verification retry did not record success'
  [[ -z "$(find "$(dirname "$marker")" -name '*.tmp.*' -print -quit)" ]] \
    || fail 'atomic marker update left a temporary file'
  rm -rf "$test_dir"
}

test_setup_must_be_complete_before_source_discovery
test_first_run_adopts_verified_equal_history
test_current_agent_tools_are_checked_without_mutation
test_yes_forwards_only_agent_disruption_consent
test_agent_consent_refusal_names_only_the_unified_retry
test_agent_discovery_failure_preserves_applied_dotfiles_for_retry
test_concurrent_update_is_rejected_without_queueing
test_outdated_agent_tools_use_the_latest_verified_updater
test_agent_update_failure_retries_without_reapplying_dotfiles
test_unsupported_arguments_fail_before_maintenance
test_dotfiles_failure_prevents_agent_tool_checks
test_repository_structure_is_validated_before_fetch
test_all_source_extras_and_unfinished_operations_are_preserved
test_fetch_and_unsafe_history_fail_diagnostically
test_behind_history_fast_forwards_then_applies_in_order
test_failed_ref_transaction_is_safe_to_retry
test_missing_maintenance_executable_enters_the_apply_path
test_drifted_maintenance_executable_enters_the_apply_path
test_matching_marker_does_not_reconcile_unrelated_target_drift
test_first_run_with_drift_enters_the_apply_path
test_unattended_overwrite_and_phase_failures_preserve_the_marker
test_dry_run_and_verification_failures_are_safe_to_retry

printf 'PASS: workstation update\n'
