#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly COMMAND="$REPO_ROOT/dot_local/bin/executable_workstation-update"
REAL_BASH="$(command -v bash)"
REAL_CHEZMOI="$(command -v chezmoi)"
REAL_GIT_UPLOAD_PACK="$(command -v git-upload-pack)"
readonly REAL_BASH REAL_CHEZMOI REAL_GIT_UPLOAD_PACK
readonly CANONICAL_ORIGIN='git@github.com:faviann/dotfiles.git'

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

resolved_command_path() {
  local command_name
  local command_path
  local directory
  local separator=
  declare -A seen=()

  for command_name in "$@"; do
    command_path="$(command -v "$command_name")" \
      || fail "required test dependency not found: $command_name"
    directory="${command_path%/*}"
    [[ -z "${seen[$directory]:-}" ]] || continue
    printf '%s%s' "$separator" "$directory"
    separator=:
    seen["$directory"]=1
  done
}

COMMAND_PATH="$(resolved_command_path bash chmod date flock git grep jq mkdir mktemp mv rm sed sha256sum sleep stat timeout touch)"
readonly COMMAND_PATH

write_agent_tools_fixture() {
  local path="$1"
  local version="$2"

  printf '#!%s\nset -euo pipefail\nreadonly FIXTURE_VERSION=%q\n' \
    "$REAL_BASH" "$version" >"$path"
  cat >>"$path" <<'STUB'
printf 'update-agent-tools %s' "$FIXTURE_VERSION" >>"$AGENT_TOOLS_LOG"
printf ' %q' "$@" >>"$AGENT_TOOLS_LOG"
printf '\n' >>"$AGENT_TOOLS_LOG"
printf 'update-agent-tools %s' "$FIXTURE_VERSION" >>"$PHASE_LOG"
printf ' %q' "$@" >>"$PHASE_LOG"
printf '\n' >>"$PHASE_LOG"

agent_state_file="$XDG_STATE_HOME/update-agent-tools/state.json"
if [[ "${1:-}" == '--record-freshness-failure' ]]; then
  mkdir -p "${agent_state_file%/*}"
  current_state='{}'
  [[ ! -f "$agent_state_file" ]] || current_state="$(<"$agent_state_file")"
  jq -n \
    --argjson current "$current_state" \
    --arg now "$UPDATE_AGENT_TOOLS_NOW" \
    '$current + {last_attempt: $now, check_status: "failed"}' \
    >"$agent_state_file.next"
  mv "$agent_state_file.next" "$agent_state_file"
  exit 0
fi

if [[ "${1:-}" == '--freshness-check-if-due' ]]; then
  if [[ -f "$agent_state_file" \
    && "$(jq -r '.check_status // ""' "$agent_state_file")" == failed ]]; then
    last_attempt="$(jq -r '.last_attempt // ""' "$agent_state_file")"
    if [[ -n "$last_attempt" \
      && "$(date -u -d "$UPDATE_AGENT_TOOLS_NOW" +%s)" \
        -lt "$(date -u -d "$last_attempt + 1 hour" +%s)" ]]; then
      jq -r '.cached_version_result // empty' "$agent_state_file"
      exit 0
    fi
  fi
  printf 'attempt\n' >>"$AGENT_FRESHNESS_ATTEMPT_LOG"
fi

if [[ -n "${TEST_AGENT_GATE:-}" ]]; then
  : >"$TEST_AGENT_GATE.ready"
  while [[ ! -e "$TEST_AGENT_GATE.release" ]]; do
    sleep 0.01
  done
fi

if [[ "${1:-}" == '--freshness-check-if-due' ]]; then
  printf '%s' "${TEST_AGENT_FRESHNESS_STDOUT:-}"
  printf '%s' "${TEST_AGENT_FRESHNESS_STDERR:-}" >&2
  mkdir -p "${agent_state_file%/*}"
  current_state='{}'
  [[ ! -f "$agent_state_file" ]] || current_state="$(<"$agent_state_file")"
  if [[ "${TEST_AGENT_FRESHNESS_STATUS:-0}" == 0 ]]; then
    jq -n \
      --argjson current "$current_state" \
      --arg now "$UPDATE_AGENT_TOOLS_NOW" \
      --arg result "${TEST_AGENT_FRESHNESS_STDOUT%$'\n'}" \
      '$current + {
        last_attempt: $now,
        last_successful_check: $now,
        cached_version_result: $result,
        check_status: "success"
      }' >"$agent_state_file.next"
  else
    jq -n \
      --argjson current "$current_state" \
      --arg now "$UPDATE_AGENT_TOOLS_NOW" \
      '$current + {last_attempt: $now, check_status: "failed"}' \
      >"$agent_state_file.next"
  fi
  mv "$agent_state_file.next" "$agent_state_file"
  exit "${TEST_AGENT_FRESHNESS_STATUS:-0}"
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
  printf '#!%s\nprintf "workstation update v1\\n"\n' "$REAL_BASH" \
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

  printf '#!%s\n' "$REAL_BASH" >"$home/stubs/chezmoi"
  cat >>"$home/stubs/chezmoi" <<'STUB'
set -euo pipefail
printf 'chezmoi' >>"$COMMAND_LOG"
printf ' %q' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
printf 'chezmoi' >>"$PHASE_LOG"
printf ' %q' "$@" >>"$PHASE_LOG"
printf '\n' >>"$PHASE_LOG"
if [[ "$*" == 'source-path' \
  && "${TEST_CHEZMOI_FRESHNESS_DELAY_SECONDS:-0}" != 0 ]]; then
  sleep "$TEST_CHEZMOI_FRESHNESS_DELAY_SECONDS"
fi
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

  printf '#!%s\n' "$REAL_BASH" >"$home/stubs/ssh"
  cat >>"$home/stubs/ssh" <<'STUB'
set -euo pipefail
printf 'fetch\n' >>"$FETCH_LOG"
if [[ "${TEST_SSH_FETCH_FAIL:-0}" == 1 ]]; then
  printf 'injected SSH fetch failure\n' >&2
  exit 66
fi
if [[ -n "${TEST_SSH_GATE:-}" ]]; then
  : >"$TEST_SSH_GATE.ready"
  while [[ ! -e "$TEST_SSH_GATE.release" ]]; do
    sleep 0.01
  done
fi
exec "$TEST_REAL_GIT_UPLOAD_PACK" "$TEST_REMOTE_REPO"
STUB
  chmod +x "$home/stubs/chezmoi" "$home/stubs/ssh"
}

run_update() {
  local test_dir="$1"
  local test_now="${WORKSTATION_UPDATE_NOW:-2026-07-15T00:00:00Z}"
  shift

  HOME="$test_dir/home" \
    XDG_STATE_HOME="$test_dir/home/state" \
    PATH="$test_dir/home/stubs:$COMMAND_PATH" \
    COMMAND_LOG="$test_dir/home/command-log" \
    TEST_REAL_CHEZMOI="$REAL_CHEZMOI" \
    TEST_REAL_GIT_UPLOAD_PACK="$REAL_GIT_UPLOAD_PACK" \
    SOURCE_REPO="$test_dir/discovered/source" \
    TEST_REMOTE_REPO="$test_dir/remote.git" \
    FETCH_LOG="$test_dir/home/fetch-log" \
    GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_SSH_VARIANT=ssh \
    GIT_TERMINAL_PROMPT=0 \
    TEST_SSH_FETCH_FAIL="${TEST_SSH_FETCH_FAIL:-0}" \
    TEST_FAIL_DRY_RUN="${TEST_FAIL_DRY_RUN:-0}" \
    TEST_FAIL_APPLY="${TEST_FAIL_APPLY:-0}" \
    TEST_DRIFT_AFTER_APPLY="${TEST_DRIFT_AFTER_APPLY:-0}" \
    TEST_CHEZMOI_FRESHNESS_DELAY_SECONDS="${TEST_CHEZMOI_FRESHNESS_DELAY_SECONDS:-0}" \
    AGENT_TOOLS_LOG="$test_dir/home/agent-tools-log" \
    AGENT_FRESHNESS_ATTEMPT_LOG="$test_dir/home/agent-freshness-attempt-log" \
    PHASE_LOG="$test_dir/home/phase-log" \
    TEST_AGENT_CHECK_FAIL="${TEST_AGENT_CHECK_FAIL:-0}" \
    TEST_AGENT_ACP_RUNNING="${TEST_AGENT_ACP_RUNNING:-0}" \
    TEST_AGENT_OUTDATED="${TEST_AGENT_OUTDATED:-0}" \
    TEST_AGENT_UPDATE_FAIL="${TEST_AGENT_UPDATE_FAIL:-0}" \
    TEST_AGENT_GATE="${TEST_AGENT_GATE:-}" \
    TEST_AGENT_FRESHNESS_STDOUT="${TEST_AGENT_FRESHNESS_STDOUT:-}" \
    TEST_AGENT_FRESHNESS_STDERR="${TEST_AGENT_FRESHNESS_STDERR:-}" \
    TEST_AGENT_FRESHNESS_STATUS="${TEST_AGENT_FRESHNESS_STATUS:-0}" \
    TEST_SSH_GATE="${TEST_SSH_GATE:-}" \
    WORKSTATION_UPDATE_NOW="$test_now" \
    UPDATE_AGENT_TOOLS_NOW="$test_now" \
    WORKSTATION_FRESHNESS_DEADLINE_SECONDS="${WORKSTATION_FRESHNESS_DEADLINE_SECONDS:-15}" \
    WORKSTATION_FRESHNESS_SUPERVISOR_CLEANUP_DELAY_SECONDS="${WORKSTATION_FRESHNESS_SUPERVISOR_CLEANUP_DELAY_SECONDS:-0}" \
    WORKSTATION_FRESHNESS_SUPERVISOR_DELAY_STARTED_MARKER="${WORKSTATION_FRESHNESS_SUPERVISOR_DELAY_STARTED_MARKER:-}" \
    bash "$COMMAND" "$@" </dev/null \
      >"$test_dir/home/stdout" 2>"$test_dir/home/stderr"
}

test_freshness_combines_dotfiles_and_agent_updates_without_mutation() {
  local before_head
  local before_target
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  before_head="$(source_commit "$test_dir")"
  before_target="$(<"$test_dir/home/.managed")"
  publish_managed_version "$test_dir" v2
  rm -f "$test_dir/home/agent-tools-log"

  TEST_AGENT_FRESHNESS_STDOUT=$'AoE: 1.2.2 -> 1.2.3\n' \
    run_update "$test_dir" --freshness \
    || fail "combined freshness failed: $(<"$test_dir/home/stderr")"

  diff -u \
    <(printf '%s\n' \
      'Workstation maintenance available:' \
      'Dotfiles: 1 commit (sanitized below)' \
      "  $(git -C "$test_dir/discovered/source" rev-parse --short "$before_head")..$(git -C "$test_dir/seed" rev-parse --short HEAD)" \
      'Agent tools:' \
      '  AoE: 1.2.2 -> 1.2.3' \
      'Run: workstation-update') \
    "$test_dir/home/stdout" \
    || fail 'combined freshness notice changed'
  [[ ! -s "$test_dir/home/stderr" ]] \
    || fail "combined freshness wrote stderr: $(<"$test_dir/home/stderr")"
  [[ "$(source_commit "$test_dir")" == "$before_head" ]] \
    || fail 'freshness changed the checked-out commit'
  [[ "$(<"$test_dir/home/.managed")" == "$before_target" ]] \
    || fail 'freshness changed a managed target'
  [[ "$(grep -c '^Run: workstation-update$' "$test_dir/home/stdout")" -eq 1 ]] \
    || fail 'freshness did not render exactly one unified action'
  diff -u \
    <(printf '%s\n' 'update-agent-tools v1 --freshness-check-if-due') \
    "$test_dir/home/agent-tools-log" \
    || fail 'freshness did not use the internal agent-tool interface'
}

test_freshness_always_reports_local_blockers_and_incomplete_maintenance() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  publish_managed_version "$test_dir" v2
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" fetch --quiet "$test_dir/remote.git" \
      '+refs/heads/main:refs/remotes/origin/main'
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" merge --quiet --ff-only origin/main
  printf 'local operator work\n' >>"$test_dir/discovered/source/dot_managed"
  mkdir -p "$test_dir/home/state/update-agent-tools"
  printf '%s\n' \
    '{"activation_failure":{"phase":"activation","component":"AoE service restart"}}' \
    >"$test_dir/home/state/update-agent-tools/state.json"

  run_update "$test_dir" --freshness \
    || fail "local freshness failed: $(<"$test_dir/home/stderr")"

  grep -Fqx 'Dotfiles blocker: source repository has local content' \
    "$test_dir/home/stdout" \
    || fail 'freshness omitted the always-current dirty-source blocker'
  grep -Fqx 'Dotfiles: fetched source has not been successfully applied' \
    "$test_dir/home/stdout" \
    || fail 'freshness omitted the durable unapplied-commit state'
  grep -Fqx 'Agent tools: unfinished activation for AoE service restart' \
    "$test_dir/home/stdout" \
    || fail 'freshness omitted unresolved activation failure state'
  [[ "$(grep -c '^Run: workstation-update$' "$test_dir/home/stdout")" -eq 1 ]] \
    || fail 'local/incomplete notice did not contain one action'
}

test_freshness_sources_age_independently() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"

  WORKSTATION_UPDATE_NOW="2026-07-15T00:00:00Z" \
    run_update "$test_dir" --freshness \
    || fail "initial freshness failed: $(<"$test_dir/home/stderr")"
  [[ ! -s "$test_dir/home/stdout" ]] \
    || fail 'healthy initial freshness was not silent'

  publish_managed_version "$test_dir" v2
  TEST_AGENT_FRESHNESS_STDOUT=$'AoE: 1.2.2 -> 1.2.3\n' \
    WORKSTATION_UPDATE_NOW="2026-07-15T23:59:59Z" \
    run_update "$test_dir" --freshness \
    || fail "independent agent freshness failed: $(<"$test_dir/home/stderr")"

  diff -u \
    <(printf '%s\n' \
      'Workstation maintenance available:' \
      'Agent tools:' \
      '  AoE: 1.2.2 -> 1.2.3' \
      'Run: workstation-update') \
    "$test_dir/home/stdout" \
    || fail 'fresh agent result was suppressed by the dotfiles cache interval'
  [[ "$(wc -l <"$test_dir/home/fetch-log")" -eq 1 ]] \
    || fail 'fresh dotfiles result was queried again before 24 hours'

  WORKSTATION_UPDATE_NOW="2026-07-16T00:00:00Z" \
    run_update "$test_dir" --freshness \
    || fail "due dotfiles freshness failed: $(<"$test_dir/home/stderr")"
  grep -Fqx 'Dotfiles: 1 commit (sanitized below)' "$test_dir/home/stdout" \
    || fail 'dotfiles source did not become due independently at 24 hours'
  [[ "$(wc -l <"$test_dir/home/fetch-log")" -eq 2 ]] \
    || fail 'due dotfiles result did not query the remote once'
}

test_freshness_failures_retain_each_source_result() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  publish_managed_version "$test_dir" v2

  TEST_AGENT_FRESHNESS_STDOUT=$'AoE: 1.2.2 -> 1.2.3\n' \
    WORKSTATION_UPDATE_NOW="2026-07-15T00:00:00Z" \
    run_update "$test_dir" --freshness \
    || fail "initial stale-result setup failed: $(<"$test_dir/home/stderr")"

  publish_managed_version "$test_dir" v3
  mkdir -p "$test_dir/home/state/update-agent-tools"
  printf '%s\n' \
    '{"last_successful_check":"2026-07-15T00:00:00Z","cached_version_result":"Claude Code CLI: 3.4.4 -> 3.4.5","check_status":"failed","activation_failure":null}' \
    >"$test_dir/home/state/update-agent-tools/state.json"

  TEST_SSH_FETCH_FAIL=1 \
    TEST_AGENT_FRESHNESS_STATUS=1 \
    WORKSTATION_UPDATE_NOW="2026-07-16T00:00:00Z" \
    run_update "$test_dir" --freshness \
    || fail "partial freshness failure escaped the notice boundary"

  grep -Fqx 'Dotfiles: 1 commit (sanitized below)' "$test_dir/home/stdout" \
    || fail 'failed dotfiles check erased its cached update result'
  grep -Fqx \
    'Dotfiles: freshness check failed; using result from 2026-07-15T00:00:00Z' \
    "$test_dir/home/stdout" \
    || fail 'failed dotfiles check did not mark its cached result stale'
  grep -Fqx '  Claude Code CLI: 3.4.4 -> 3.4.5' "$test_dir/home/stdout" \
    || fail 'failed agent check erased its cached update result'
  grep -Fqx \
    'Agent tools: freshness check failed; using result from 2026-07-15T00:00:00Z' \
    "$test_dir/home/stdout" \
    || fail 'failed agent check did not mark its cached result stale'
  [[ "$(grep -c '^Run: workstation-update$' "$test_dir/home/stdout")" -eq 1 ]] \
    || fail 'partial failures produced multiple recovery actions'

  TEST_SSH_FETCH_FAIL=1 \
    WORKSTATION_UPDATE_NOW="2026-07-16T00:59:59Z" \
    run_update "$test_dir" --freshness \
    || fail 'failed dotfiles source escaped during its retry interval'
  [[ "$(wc -l <"$test_dir/home/fetch-log")" -eq 2 ]] \
    || fail 'failed dotfiles source retried before one hour'
  grep -Fqx \
    'Agent tools: freshness check failed; using result from 2026-07-15T00:00:00Z' \
    "$test_dir/home/stdout" \
    || fail 'cached failed agent status stopped rendering before its retry'

  TEST_SSH_FETCH_FAIL=1 \
    WORKSTATION_UPDATE_NOW="2026-07-16T01:00:00Z" \
    run_update "$test_dir" --freshness \
    || fail 'due failed dotfiles source escaped after its retry interval'
  [[ "$(wc -l <"$test_dir/home/fetch-log")" -eq 3 ]] \
    || fail 'failed dotfiles source did not retry after one hour'
}

test_due_freshness_sources_run_concurrently() {
  local freshness_pid
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"

  TEST_AGENT_GATE="$test_dir/agent-gate" \
    TEST_SSH_GATE="$test_dir/ssh-gate" \
    run_update "$test_dir" --freshness &
  freshness_pid=$!

  for _ in {1..200}; do
    if [[ -e "$test_dir/agent-gate.ready" \
      && -e "$test_dir/ssh-gate.ready" ]]; then
      break
    fi
    sleep 0.01
  done
  if [[ ! -e "$test_dir/agent-gate.ready" \
    || ! -e "$test_dir/ssh-gate.ready" ]]; then
    touch "$test_dir/agent-gate.release" "$test_dir/ssh-gate.release"
    wait "$freshness_pid" || true
    fail 'due freshness sources did not both start before either completed'
  fi

  touch "$test_dir/agent-gate.release" "$test_dir/ssh-gate.release"
  wait "$freshness_pid" \
    || fail "concurrent freshness failed: $(<"$test_dir/home/stderr")"
  [[ ! -s "$test_dir/home/stdout" && ! -s "$test_dir/home/stderr" ]] \
    || fail 'healthy concurrent freshness was not silent'
}

test_combined_freshness_deadline_bounds_both_sources() {
  local elapsed_milliseconds
  local finished_at
  local started_at
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"

  started_at="$(date +%s%N)"
  TEST_AGENT_GATE="$test_dir/agent-gate" \
    TEST_SSH_GATE="$test_dir/ssh-gate" \
    TEST_CHEZMOI_FRESHNESS_DELAY_SECONDS=0.3 \
    WORKSTATION_FRESHNESS_DEADLINE_SECONDS=1 \
    run_update "$test_dir" --freshness \
    || fail 'bounded freshness failure escaped the login boundary'
  finished_at="$(date +%s%N)"
  elapsed_milliseconds=$(( (finished_at - started_at) / 1000000 ))

  (( elapsed_milliseconds < 1400 )) \
    || fail "combined freshness exceeded its controlled deadline: ${elapsed_milliseconds}ms"
  grep -Fqx \
    'Dotfiles: freshness check failed; no successful result is available' \
    "$test_dir/home/stdout" \
    || fail 'deadline did not isolate the timed-out dotfiles source'
  grep -Fqx \
    'Agent tools: freshness check failed; no successful result is available' \
    "$test_dir/home/stdout" \
    || fail 'deadline did not isolate the timed-out agent source'
  [[ "$(grep -c '^Run: workstation-update$' "$test_dir/home/stdout")" -eq 1 ]] \
    || fail 'deadline failures did not share one recovery action'
}

test_freshness_history_blockers_are_local_when_fetch_fails() {
  local before_head
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  printf 'unpublished work\n' >"$test_dir/discovered/source/dot_unpublished"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" add dot_unpublished
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" commit --quiet -m unpublished
  before_head="$(source_commit "$test_dir")"

  TEST_SSH_FETCH_FAIL=1 \
    run_update "$test_dir" --freshness \
    || fail 'local history blocker escaped when fetch failed'

  grep -Fqx 'Dotfiles blocker: main is ahead by 1 commit(s)' \
    "$test_dir/home/stdout" \
    || fail 'fetch failure suppressed the always-current local history blocker'
  [[ "$(source_commit "$test_dir")" == "$before_head" ]] \
    || fail 'freshness changed an ahead local commit'
}

test_timed_out_agent_freshness_retries_after_one_hour() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  mkdir -p "$test_dir/home/state/update-agent-tools"
  printf '%s\n' \
    '{"last_attempt":"2026-07-14T00:00:00Z","last_successful_check":"2026-07-14T00:00:00Z","cached_version_result":"AoE: 1.2.2 -> 1.2.3","check_status":"success","activation_failure":null}' \
    >"$test_dir/home/state/update-agent-tools/state.json"

  TEST_AGENT_GATE="$test_dir/agent-gate" \
    WORKSTATION_UPDATE_NOW="2026-07-15T00:00:00Z" \
    WORKSTATION_FRESHNESS_DEADLINE_SECONDS=1 \
    run_update "$test_dir" --freshness \
    || fail 'timed-out agent freshness escaped the notice boundary'
  [[ "$(wc -l <"$test_dir/home/agent-freshness-attempt-log")" -eq 1 ]] \
    || fail 'initial timed-out agent check did not make one attempt'
  grep -Fqx '  AoE: 1.2.2 -> 1.2.3' "$test_dir/home/stdout" \
    || fail 'agent timeout erased the last successful result'
  grep -Fqx \
    'Agent tools: freshness check failed; using result from 2026-07-14T00:00:00Z' \
    "$test_dir/home/stdout" \
    || fail 'agent timeout did not render retained knowledge as stale'
  jq -e '
    .last_attempt == "2026-07-15T00:00:00Z"
    and .check_status == "failed"
    and .cached_version_result == "AoE: 1.2.2 -> 1.2.3"
  ' "$test_dir/home/state/update-agent-tools/state.json" >/dev/null \
    || fail "agent timeout did not persist retry state: $(<"$test_dir/home/state/update-agent-tools/state.json")"

  WORKSTATION_UPDATE_NOW="2026-07-15T00:59:59Z" \
    run_update "$test_dir" --freshness \
    || fail 'cached timed-out agent status escaped before retry'
  [[ "$(wc -l <"$test_dir/home/agent-freshness-attempt-log")" -eq 1 ]] \
    || fail 'timed-out agent source retried before one hour'
  grep -Fqx \
    'Agent tools: freshness check failed; using result from 2026-07-14T00:00:00Z' \
    "$test_dir/home/stdout" \
    || fail "timed-out agent failure stopped rendering before retry: stdout=$(<"$test_dir/home/stdout"); agent-log=$(<"$test_dir/home/agent-tools-log"); state=$(<"$test_dir/home/state/update-agent-tools/state.json")"

  TEST_AGENT_FRESHNESS_STDOUT=$'Claude Code CLI: 3.4.4 -> 3.4.5\n' \
    WORKSTATION_UPDATE_NOW="2026-07-15T01:00:00Z" \
    run_update "$test_dir" --freshness \
    || fail 'timed-out agent source did not recover at retry time'
  [[ "$(wc -l <"$test_dir/home/agent-freshness-attempt-log")" -eq 2 ]] \
    || fail 'timed-out agent source did not retry exactly at one hour'
  grep -Fqx '  Claude Code CLI: 3.4.4 -> 3.4.5' "$test_dir/home/stdout" \
    || fail 'agent retry did not replace retained knowledge with fresh success'
}

test_freshness_outer_deadline_bounds_stalled_local_preflight() {
  local action_count
  local elapsed_milliseconds
  local finished_at
  local started_at
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"

  started_at="$(date +%s%N)"
  TEST_CHEZMOI_FRESHNESS_DELAY_SECONDS=2 \
    WORKSTATION_FRESHNESS_DEADLINE_SECONDS=1 \
    run_update "$test_dir" --freshness \
    || fail 'stalled local preflight escaped the freshness boundary'
  finished_at="$(date +%s%N)"
  elapsed_milliseconds=$(( (finished_at - started_at) / 1000000 ))

  (( elapsed_milliseconds < 1400 )) \
    || fail "local preflight exceeded the overall deadline: ${elapsed_milliseconds}ms"
  action_count="$(grep -c '^Run: workstation-update$' \
    "$test_dir/home/stdout" || true)"
  [[ "$action_count" -eq 1 ]] \
    || fail 'outer deadline did not emit exactly one recovery action'
  diff -u \
    <(printf '%s\n' \
      'Workstation maintenance available:' \
      'Workstation freshness check timed out' \
      'Run: workstation-update') \
    "$test_dir/home/stdout" \
    || fail 'outer deadline emitted a partial or incoherent fallback notice'
  [[ ! -s "$test_dir/home/stderr" ]] \
    || fail 'outer deadline leaked worker diagnostics'
}

test_freshness_git_reads_do_not_refresh_the_index() {
  local after_index_identity
  local after_index_sha
  local before_head
  local before_index_identity
  local before_index_sha
  local expected_remote_head
  local fetch_head_path
  local fetch_head_state
  local index_path
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  before_head="$(source_commit "$test_dir")"
  publish_managed_version "$test_dir" v2
  expected_remote_head="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/seed" rev-parse HEAD)"
  index_path="$test_dir/discovered/source/.git/index"
  fetch_head_path="$test_dir/discovered/source/.git/FETCH_HEAD"
  touch -d '2030-01-01T00:00:00Z' \
    "$test_dir/discovered/source/dot_managed"
  before_index_sha="$(sha256sum "$index_path")"
  before_index_identity="$(stat -c '%i:%Y:%s' "$index_path")"
  fetch_head_state=absent
  if [[ -f "$fetch_head_path" ]]; then
    fetch_head_state="$(sha256sum "$fetch_head_path")"
  fi

  run_update "$test_dir" --freshness \
    || fail 'non-refreshing freshness check failed'

  after_index_sha="$(sha256sum "$index_path")"
  after_index_identity="$(stat -c '%i:%Y:%s' "$index_path")"
  [[ "$after_index_sha" == "$before_index_sha" \
    && "$after_index_identity" == "$before_index_identity" ]] \
    || fail 'freshness Git reads refreshed or rewrote the index'
  [[ "$(source_commit "$test_dir")" == "$before_head" ]] \
    || fail 'freshness changed the checked-out commit while checking the index'
  if [[ "$fetch_head_state" == absent ]]; then
    [[ ! -e "$fetch_head_path" ]] \
      || fail 'freshness created FETCH_HEAD metadata'
  else
    [[ "$(sha256sum "$fetch_head_path")" == "$fetch_head_state" ]] \
      || fail 'freshness rewrote FETCH_HEAD metadata'
  fi
  [[ "$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" rev-parse origin/main)" \
    == "$expected_remote_head" ]] \
    || fail 'disabled optional locks prevented the permitted remote-tracking fetch'
}

test_dotfiles_timeout_preserves_completed_agent_and_cached_dotfiles_results() {
  local before_head
  local before_index_identity
  local before_index_sha
  local before_source_content
  local before_target
  local cached_remote
  local cached_remote_short
  local index_path
  local local_short
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  before_head="$(source_commit "$test_dir")"
  before_source_content="$(<"$test_dir/discovered/source/dot_managed")"
  before_target="$(<"$test_dir/home/.managed")"
  index_path="$test_dir/discovered/source/.git/index"
  before_index_sha="$(sha256sum "$index_path")"
  before_index_identity="$(stat -c '%i:%Y:%s' "$index_path")"

  publish_managed_version "$test_dir" v2
  WORKSTATION_UPDATE_NOW="2026-07-15T00:00:00Z" \
    run_update "$test_dir" --freshness \
    || fail 'cached dotfiles result setup failed'
  cached_remote="$(jq -r '.cached_remote_commit' \
    "$test_dir/home/state/workstation-update/dotfiles-freshness.json")"
  local_short="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" rev-parse --short "$before_head")"
  cached_remote_short="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" rev-parse --short "$cached_remote")"
  publish_managed_version "$test_dir" v3

  TEST_SSH_GATE="$test_dir/ssh-gate" \
    TEST_AGENT_FRESHNESS_STDOUT=$'Claude Code CLI: 3.4.4 -> 3.4.5\n' \
    WORKSTATION_UPDATE_NOW="2026-07-16T00:00:00Z" \
    WORKSTATION_FRESHNESS_DEADLINE_SECONDS=1 \
    run_update "$test_dir" --freshness \
    || fail 'dotfiles timeout escaped the freshness boundary'

  jq -e '
    .last_attempt == "2026-07-16T00:00:00Z"
    and .last_successful_check == "2026-07-16T00:00:00Z"
    and .cached_version_result == "Claude Code CLI: 3.4.4 -> 3.4.5"
    and .check_status == "success"
  ' "$test_dir/home/state/update-agent-tools/state.json" >/dev/null \
    || fail 'completed agent source was overwritten as timed out'
  jq -e '
    .last_attempt == "2026-07-16T00:00:00Z"
    and .last_successful_check == "2026-07-15T00:00:00Z"
    and .attempt_status == "failed"
  ' "$test_dir/home/state/workstation-update/dotfiles-freshness.json" >/dev/null \
    || fail "timed-out dotfiles source did not record its one-hour retry state: $(<"$test_dir/home/state/workstation-update/dotfiles-freshness.json")"
  diff -u \
    <(printf '%s\n' \
      'Workstation maintenance available:' \
      'Agent tools:' \
      '  Claude Code CLI: 3.4.4 -> 3.4.5' \
      'Dotfiles: 1 commit (sanitized below)' \
      "  $local_short..$cached_remote_short" \
      'Dotfiles: freshness check failed; using result from 2026-07-15T00:00:00Z' \
      'Run: workstation-update') \
    "$test_dir/home/stdout" \
    || fail 'dotfiles timeout suppressed or duplicated retained source results'
  [[ "$(source_commit "$test_dir")" == "$before_head" ]] \
    || fail 'dotfiles timeout changed the checked-out commit'
  [[ "$(sha256sum "$index_path")" == "$before_index_sha" \
    && "$(stat -c '%i:%Y:%s' "$index_path")" == "$before_index_identity" ]] \
    || fail 'dotfiles timeout changed the index'
  [[ "$(<"$test_dir/discovered/source/dot_managed")" == "$before_source_content" ]] \
    || fail 'dotfiles timeout changed the worktree'
  [[ "$(<"$test_dir/home/.managed")" == "$before_target" ]] \
    || fail 'dotfiles timeout changed a managed target'
}

test_agent_timeout_preserves_newly_completed_dotfiles_result() {
  local before_head
  local before_index_identity
  local before_index_sha
  local before_source_content
  local before_target
  local expected_remote
  local index_path
  local local_short
  local remote_short
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  WORKSTATION_UPDATE_NOW="2026-07-15T00:00:00Z" \
    TEST_AGENT_FRESHNESS_STDOUT=$'AoE: 1.2.2 -> 1.2.3\n' \
    run_update "$test_dir" --freshness \
    || fail 'agent-timeout cache setup failed'

  before_head="$(source_commit "$test_dir")"
  before_source_content="$(<"$test_dir/discovered/source/dot_managed")"
  before_target="$(<"$test_dir/home/.managed")"
  index_path="$test_dir/discovered/source/.git/index"
  before_index_sha="$(sha256sum "$index_path")"
  before_index_identity="$(stat -c '%i:%Y:%s' "$index_path")"
  publish_managed_version "$test_dir" v2
  expected_remote="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/seed" rev-parse HEAD)"
  local_short="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" rev-parse --short "$before_head")"
  remote_short="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/seed" rev-parse --short "$expected_remote")"

  TEST_AGENT_GATE="$test_dir/agent-gate" \
    WORKSTATION_UPDATE_NOW="2026-07-16T00:00:00Z" \
    WORKSTATION_FRESHNESS_DEADLINE_SECONDS=1 \
    run_update "$test_dir" --freshness \
    || fail 'agent timeout escaped the freshness boundary'

  jq -e --arg remote "$expected_remote" '
    .last_attempt == "2026-07-16T00:00:00Z"
    and .last_successful_check == "2026-07-16T00:00:00Z"
    and .cached_remote_commit == $remote
    and .attempt_status == "success"
  ' "$test_dir/home/state/workstation-update/dotfiles-freshness.json" >/dev/null \
    || fail 'completed dotfiles source was overwritten as timed out'
  jq -e '
    .last_attempt == "2026-07-16T00:00:00Z"
    and .last_successful_check == "2026-07-15T00:00:00Z"
    and .cached_version_result == "AoE: 1.2.2 -> 1.2.3"
    and .check_status == "failed"
  ' "$test_dir/home/state/update-agent-tools/state.json" >/dev/null \
    || fail 'timed-out agent source did not preserve its retry state and cached result'
  diff -u \
    <(printf '%s\n' \
      'Workstation maintenance available:' \
      'Agent tools:' \
      '  AoE: 1.2.2 -> 1.2.3' \
      'Dotfiles: 1 commit (sanitized below)' \
      "  $local_short..$remote_short" \
      'Agent tools: freshness check failed; using result from 2026-07-15T00:00:00Z' \
      'Run: workstation-update') \
    "$test_dir/home/stdout" \
    || fail 'agent timeout suppressed the newly completed dotfiles result'
  [[ "$(source_commit "$test_dir")" == "$before_head" ]] \
    || fail 'agent timeout changed the checked-out commit'
  [[ "$(sha256sum "$index_path")" == "$before_index_sha" \
    && "$(stat -c '%i:%Y:%s' "$index_path")" == "$before_index_identity" ]] \
    || fail 'agent timeout changed the index'
  [[ "$(<"$test_dir/discovered/source/dot_managed")" == "$before_source_content" \
    && "$(<"$test_dir/home/.managed")" == "$before_target" ]] \
    || fail 'agent timeout changed the worktree or managed target'
}

test_timeout_notice_preserves_local_blockers_and_incomplete_maintenance() {
  local elapsed_milliseconds
  local finished_at
  local started_at
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  publish_managed_version "$test_dir" v2
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" fetch --quiet "$test_dir/remote.git" \
      '+refs/heads/main:refs/remotes/origin/main'
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" merge --quiet --ff-only origin/main
  printf 'unpublished work\n' \
    >"$test_dir/discovered/source/dot_unpublished"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" add dot_unpublished
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" commit --quiet -m unpublished
  printf 'local operator work\n' >>"$test_dir/discovered/source/dot_managed"
  mkdir -p "$test_dir/home/state/update-agent-tools"
  printf '%s\n' \
    '{"last_attempt":"2026-07-14T00:00:00Z","last_successful_check":"2026-07-14T00:00:00Z","cached_version_result":"AoE: 1.2.2 -> 1.2.3","check_status":"success","activation_failure":{"phase":"activation","component":"AoE service restart"}}' \
    >"$test_dir/home/state/update-agent-tools/state.json"

  started_at="$(date +%s%N)"
  TEST_AGENT_GATE="$test_dir/agent-gate" \
    WORKSTATION_FRESHNESS_DEADLINE_SECONDS=1 \
    WORKSTATION_FRESHNESS_SUPERVISOR_CLEANUP_DELAY_SECONDS=2 \
    WORKSTATION_FRESHNESS_SUPERVISOR_DELAY_STARTED_MARKER="$test_dir/supervisor-cleanup-started" \
    run_update "$test_dir" --freshness \
    || fail 'local-state timeout escaped the freshness boundary'
  finished_at="$(date +%s%N)"
  elapsed_milliseconds=$(( (finished_at - started_at) / 1000000 ))

  diff -u \
    <(printf '%s\n' \
      'Workstation maintenance available:' \
      'Agent tools:' \
      '  AoE: 1.2.2 -> 1.2.3' \
      'Agent tools: freshness check failed; using result from 2026-07-14T00:00:00Z' \
      'Dotfiles blocker: source repository has local content' \
      'Dotfiles: fetched source has not been successfully applied' \
      'Dotfiles blocker: main is ahead by 1 commit(s)' \
      'Agent tools: unfinished activation for AoE service restart' \
      'Run: workstation-update') \
    "$test_dir/home/stdout" \
    || fail 'timeout notice dropped local blockers or incomplete maintenance'
  [[ "$(grep -c '^Run: workstation-update$' "$test_dir/home/stdout")" -eq 1 ]] \
    || fail 'local-state timeout rendered more than one action'
  [[ -e "$test_dir/supervisor-cleanup-started" ]] \
    || fail 'controlled supervisor cleanup delay was not exercised'
  (( elapsed_milliseconds >= 900 && elapsed_milliseconds < 1400 )) \
    || fail "outer fallback was not bounded around slow cleanup: ${elapsed_milliseconds}ms"
}

test_timeout_fallback_marks_persisted_dotfiles_failure_stale() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  publish_managed_version "$test_dir" v2
  WORKSTATION_UPDATE_NOW="2026-07-15T00:00:00Z" \
    run_update "$test_dir" --freshness \
    || fail 'persisted dotfiles failure cache setup failed'
  TEST_SSH_FETCH_FAIL=1 \
    WORKSTATION_UPDATE_NOW="2026-07-16T00:00:00Z" \
    run_update "$test_dir" --freshness \
    || fail 'persisted dotfiles failure setup escaped freshness'

  TEST_AGENT_GATE="$test_dir/agent-gate" \
    WORKSTATION_UPDATE_NOW="2026-07-16T00:30:00Z" \
    WORKSTATION_FRESHNESS_DEADLINE_SECONDS=1 \
    run_update "$test_dir" --freshness \
    || fail 'agent timeout escaped persisted dotfiles failure fallback'

  [[ "$(grep -c '^Dotfiles: freshness check failed; using result from 2026-07-15T00:00:00Z$' \
    "$test_dir/home/stdout")" -eq 1 ]] \
    || fail 'timeout fallback omitted or duplicated persisted dotfiles stale status'
  grep -Fqx 'Dotfiles: 1 commit (sanitized below)' "$test_dir/home/stdout" \
    || fail 'timeout fallback suppressed retained dotfiles update knowledge'
  [[ "$(grep -c '^Run: workstation-update$' "$test_dir/home/stdout")" -eq 1 ]] \
    || fail 'persisted dotfiles failure fallback rendered multiple actions'
}

test_timeout_fallback_marks_persisted_agent_failure_stale() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  mkdir -p "$test_dir/home/state/update-agent-tools"
  printf '%s\n' \
    '{"last_attempt":"2026-07-15T00:00:00Z","last_successful_check":"2026-07-14T00:00:00Z","cached_version_result":"AoE: 1.2.2 -> 1.2.3","check_status":"failed","activation_failure":null}' \
    >"$test_dir/home/state/update-agent-tools/state.json"

  TEST_SSH_GATE="$test_dir/ssh-gate" \
    WORKSTATION_UPDATE_NOW="2026-07-15T00:30:00Z" \
    WORKSTATION_FRESHNESS_DEADLINE_SECONDS=1 \
    run_update "$test_dir" --freshness \
    || fail 'dotfiles timeout escaped persisted agent failure fallback'

  [[ "$(grep -c '^Agent tools: freshness check failed; using result from 2026-07-14T00:00:00Z$' \
    "$test_dir/home/stdout")" -eq 1 ]] \
    || fail 'timeout fallback omitted or duplicated persisted agent stale status'
  grep -Fqx '  AoE: 1.2.2 -> 1.2.3' "$test_dir/home/stdout" \
    || fail 'timeout fallback suppressed retained agent update knowledge'
  [[ "$(grep -c '^Run: workstation-update$' "$test_dir/home/stdout")" -eq 1 ]] \
    || fail 'persisted agent failure fallback rendered multiple actions'
}

test_freshness_accumulates_independent_local_blockers() {
  local before_head
  local before_index_sha
  local before_source_content
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  printf 'unpublished work\n' >"$test_dir/discovered/source/dot_unpublished"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" add dot_unpublished
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" commit --quiet -m unpublished
  printf 'dirty local work\n' >>"$test_dir/discovered/source/dot_managed"
  mkdir "$test_dir/discovered/source/.git/rebase-merge"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" remote set-url origin \
      'git@github.com:unexpected/dotfiles.git'
  before_head="$(source_commit "$test_dir")"
  before_index_sha="$(sha256sum "$test_dir/discovered/source/.git/index")"
  before_source_content="$(<"$test_dir/discovered/source/dot_managed")"

  run_update "$test_dir" --freshness \
    || fail 'independent local blocker evaluation escaped freshness'

  for expected in \
    'Dotfiles blocker: repository origin is not canonical' \
    'Dotfiles blocker: unfinished Git operation' \
    'Dotfiles blocker: source repository has local content' \
    'Dotfiles: fetched source has not been successfully applied' \
    'Dotfiles blocker: main is ahead by 1 commit(s)'; do
    grep -Fqx "$expected" "$test_dir/home/stdout" \
      || fail "freshness omitted independently evaluable local state: $expected"
  done
  [[ "$(grep -c '^Run: workstation-update$' "$test_dir/home/stdout")" -eq 1 ]] \
    || fail 'independent local blockers rendered multiple actions'
  [[ ! -e "$test_dir/home/fetch-log" ]] \
    || fail 'unsafe local blockers allowed a freshness fetch'
  [[ "$(source_commit "$test_dir")" == "$before_head" \
    && "$(sha256sum "$test_dir/discovered/source/.git/index")" == "$before_index_sha" \
    && "$(<"$test_dir/discovered/source/dot_managed")" == "$before_source_content" ]] \
    || fail 'independent local blocker evaluation mutated Git state or the worktree'
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
  printf '#!%s\nprintf "workstation update %s\\n"\n' \
    "$REAL_BASH" "$version" \
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

  printf '#!%s\n' "$REAL_BASH" >"$test_dir/home/stubs/chezmoi"
  cat >>"$test_dir/home/stubs/chezmoi" <<'STUB'
printf 'chezmoi %s\n' "$*" >>"$COMMAND_LOG"
exit 64
STUB
  chmod +x "$test_dir/home/stubs/chezmoi"

  HOME="$test_dir/home" \
    XDG_STATE_HOME="$test_dir/home/state" \
    PATH="$test_dir/home/stubs:$COMMAND_PATH" \
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
    sleep 0.01
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
#!$REAL_BASH
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

# shellcheck source=tests/lib/suite-dispatch.bash
source "$REPO_ROOT/tests/lib/suite-dispatch.bash"

readonly test_cases=(
  test_freshness_combines_dotfiles_and_agent_updates_without_mutation
  test_freshness_always_reports_local_blockers_and_incomplete_maintenance
  test_freshness_sources_age_independently
  test_freshness_failures_retain_each_source_result
  test_due_freshness_sources_run_concurrently
  test_combined_freshness_deadline_bounds_both_sources
  test_freshness_history_blockers_are_local_when_fetch_fails
  test_timed_out_agent_freshness_retries_after_one_hour
  test_freshness_outer_deadline_bounds_stalled_local_preflight
  test_freshness_git_reads_do_not_refresh_the_index
  test_dotfiles_timeout_preserves_completed_agent_and_cached_dotfiles_results
  test_agent_timeout_preserves_newly_completed_dotfiles_result
  test_timeout_notice_preserves_local_blockers_and_incomplete_maintenance
  test_timeout_fallback_marks_persisted_dotfiles_failure_stale
  test_timeout_fallback_marks_persisted_agent_failure_stale
  test_freshness_accumulates_independent_local_blockers
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
)

suite_dispatch 'workstation update' "$@"
