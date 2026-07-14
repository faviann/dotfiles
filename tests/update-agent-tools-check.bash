#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly COMMAND="$REPO_ROOT/dot_local/bin/executable_update-agent-tools"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_stubs() {
  local stub_dir="$1"

  mkdir -p "$stub_dir"

  cat >"$stub_dir/aoe" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == "--version" ]]; then
  printf 'aoe %s\n' "$AOE_CURRENT"
  exit 0
fi

printf 'unexpected aoe invocation: %s\n' "$*" >&2
exit 64
STUB

  cat >"$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == "-fsSL https://api.github.com/repos/njbrake/agent-of-empires/releases/latest" ]]; then
  printf 'curl release\n' >>"$QUERY_LOG"
  if [[ -n "${CURL_GATE:-}" ]] \
    && mkdir "$CURL_GATE.claim" 2>/dev/null; then
    : >"$CURL_GATE.ready"
    while [[ ! -e "$CURL_GATE.release" ]]; do
      sleep 0.01
    done
  fi
  if [[ "${CURL_FAIL:-0}" == "1" ]]; then
    printf 'release registry unavailable\n' >&2
    exit 22
  fi
  printf '{"tag_name":"v%s"}\n' "$AOE_LATEST"
  exit 0
fi

printf 'unexpected curl invocation: %s\n' "$*" >&2
exit 64
STUB

  cat >"$stub_dir/npm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf 'npm %s\n' "$*" >>"$COMMAND_LOG"

if [[ "$1" == "view" && "${NPM_FAIL_PACKAGE:-}" == "$2" ]]; then
  printf 'npm registry unavailable\n' >&2
  exit 1
fi

if [[ "$1" == "view" && "${NPM_EMPTY_PACKAGE:-}" == "$2" ]]; then
  exit 0
fi

if [[ "$*" == "config get prefix" ]]; then
  printf '%s/.local\n' "$HOME"
  exit 0
fi

if [[ "$*" == "list --global --json --all" ]]; then
  if [[ "${NPM_FIXTURE:-complete}" == "missing" ]]; then
    cat <<EOF
{
  "dependencies": {
    "@openai/codex": {"version": "${CODEX_CURRENT}"},
    "@anthropic-ai/claude-code": {"version": "${CLAUDE_CURRENT}"},
    "@earendil-works/pi-coding-agent": {"version": "${PI_CURRENT}"},
    "@agentclientprotocol/codex-acp": {
      "version": "${CODEX_ACP_CURRENT}",
      "dependencies": {"@openai/codex": {"version": "${BUNDLED_CODEX_CURRENT}"}}
    },
    "pi-acp": {"version": "${PI_ACP_CURRENT}"}
  }
}
EOF
    exit 0
  fi

  cat <<EOF
{
  "dependencies": {
    "@openai/codex": {"version": "${CODEX_CURRENT}"},
    "@anthropic-ai/claude-code": {"version": "${CLAUDE_CURRENT}"},
    "@earendil-works/pi-coding-agent": {"version": "${PI_CURRENT}"},
    "@agentclientprotocol/codex-acp": {
      "version": "${CODEX_ACP_CURRENT}",
      "dependencies": {"@openai/codex": {"version": "${BUNDLED_CODEX_CURRENT}"}}
    },
    "@agentclientprotocol/claude-agent-acp": {"version": "${CLAUDE_ACP_CURRENT}"},
    "pi-acp": {"version": "${PI_ACP_CURRENT}"}
  }
}
EOF
  exit 0
fi

if [[ "$*" == "view @agentclientprotocol/codex-acp@latest dependencies.@openai/codex" ]]; then
  printf '%s\n' "$BUNDLED_CODEX_RANGE"
  exit 0
fi

if [[ "$*" == "view @openai/codex@$BUNDLED_CODEX_RANGE version --json" ]]; then
  printf '%s\n' "$BUNDLED_CODEX_VERSIONS_JSON"
  exit 0
fi

if [[ "$1" == "view" && "$3" == "version" ]]; then
  printf 'npm %s\n' "$*" >>"$QUERY_LOG"
  case "$2" in
    '@openai/codex@latest') printf '%s\n' "$CODEX_LATEST" ;;
    '@anthropic-ai/claude-code@latest') printf '%s\n' "$CLAUDE_LATEST" ;;
    '@earendil-works/pi-coding-agent@latest') printf '%s\n' "$PI_LATEST" ;;
    '@agentclientprotocol/codex-acp@latest') printf '%s\n' "$CODEX_ACP_LATEST" ;;
    '@agentclientprotocol/claude-agent-acp@latest') printf '%s\n' "$CLAUDE_ACP_LATEST" ;;
    'pi-acp@latest') printf '%s\n' "$PI_ACP_LATEST" ;;
    *) printf 'unexpected npm package: %s\n' "$2" >&2; exit 64 ;;
  esac
  exit 0
fi

printf 'unexpected npm invocation: %s\n' "$*" >&2
exit 64
STUB

  chmod +x "$stub_dir/aoe" "$stub_dir/curl" "$stub_dir/npm"
}

run_tool() {
  local home="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3

  HOME="$home" \
    XDG_STATE_HOME="${TEST_XDG_STATE_HOME-$home/state}" \
    PATH="$home/stubs:/usr/bin:/bin" \
    QUERY_LOG="$home/query-log" \
    COMMAND_LOG="$home/command-log" \
    UPDATE_AGENT_TOOLS_NOW="${UPDATE_AGENT_TOOLS_NOW:-2026-07-14T00:00:00Z}" \
    CURL_FAIL="${CURL_FAIL:-0}" \
    CURL_GATE="${CURL_GATE:-}" \
    NPM_EMPTY_PACKAGE="${NPM_EMPTY_PACKAGE:-}" \
    NPM_FAIL_PACKAGE="${NPM_FAIL_PACKAGE:-}" \
    NPM_FIXTURE="${NPM_FIXTURE:-complete}" \
    AOE_CURRENT="${AOE_CURRENT:-1.2.3}" \
    AOE_LATEST="${AOE_LATEST:-1.2.3}" \
    CODEX_CURRENT="${CODEX_CURRENT:-2.3.4}" \
    CODEX_LATEST="${CODEX_LATEST:-2.3.4}" \
    CLAUDE_CURRENT="${CLAUDE_CURRENT:-3.4.5}" \
    CLAUDE_LATEST="${CLAUDE_LATEST:-3.4.5}" \
    PI_CURRENT="${PI_CURRENT:-4.5.6}" \
    PI_LATEST="${PI_LATEST:-4.5.6}" \
    CODEX_ACP_CURRENT="${CODEX_ACP_CURRENT:-5.6.7}" \
    CODEX_ACP_LATEST="${CODEX_ACP_LATEST:-5.6.7}" \
    CLAUDE_ACP_CURRENT="${CLAUDE_ACP_CURRENT:-6.7.8}" \
    CLAUDE_ACP_LATEST="${CLAUDE_ACP_LATEST:-6.7.8}" \
    PI_ACP_CURRENT="${PI_ACP_CURRENT:-7.8.9}" \
    PI_ACP_LATEST="${PI_ACP_LATEST:-7.8.9}" \
    BUNDLED_CODEX_CURRENT="${BUNDLED_CODEX_CURRENT:-2.3.4}" \
    BUNDLED_CODEX_RANGE="${BUNDLED_CODEX_RANGE:-^2.3.0}" \
    BUNDLED_CODEX_VERSIONS_JSON="${BUNDLED_CODEX_VERSIONS_JSON:-[\"2.3.3\",\"2.3.4\"]}" \
    bash "$COMMAND" "$@" >"$stdout_file" 2>"$stderr_file"
}

run_check() {
  run_tool "$1" "$2" "$3" --check
}

test_due_check_runs_once_per_success_interval() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if ! AOE_CURRENT="1.2.2" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-14T10:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-1" "$test_dir/stderr-1" --check-if-due; then
    fail "initial due check exited nonzero: $(<"$test_dir/stderr-1")"
  fi
  [[ "$(<"$test_dir/stdout-1")" == "AoE: 1.2.2 -> 1.2.3" ]] \
    || fail "initial due check did not report the current result"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 7 ]] \
    || fail "initial due check did not perform all release queries"

  UPDATE_AGENT_TOOLS_NOW="2026-07-15T09:59:59Z" \
    run_tool "$test_dir" "$test_dir/stdout-2" "$test_dir/stderr-2" --check-if-due \
    || fail "not-yet-due check exited nonzero: $(<"$test_dir/stderr-2")"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 7 ]] \
    || fail "not-yet-due check queried a registry or release"
  [[ "$(<"$test_dir/stdout-2")" == "AoE: 1.2.2 -> 1.2.3" ]] \
    || fail "not-yet-due check did not reuse the cached result"

  UPDATE_AGENT_TOOLS_NOW="2026-07-15T10:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-3" "$test_dir/stderr-3" --check-if-due \
    || fail "due-again check exited nonzero: $(<"$test_dir/stderr-3")"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 14 ]] \
    || fail "due-again check did not perform fresh release queries"
}

test_state_uses_local_state_fallback() {
  local test_dir
  local state_file
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/.local/state/update-agent-tools/state.json"

  TEST_XDG_STATE_HOME="" \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --check-if-due \
    || fail "fallback-state check exited nonzero: $(<"$test_dir/stderr")"
  [[ -f "$state_file" ]] \
    || fail "check state did not use the local-state fallback"
  jq -e '
    has("last_attempt")
    and has("last_successful_check")
    and has("cached_version_result")
    and has("last_successful_activation")
    and has("activation_failure")
  ' "$state_file" >/dev/null \
    || fail "fallback state did not contain the command-contract fields"
}

test_concurrent_due_checks_are_serialized() {
  local first_pid
  local second_pid
  local state_dir
  local test_dir
  local wait_count=0
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_dir="$test_dir/state/update-agent-tools"

  CURL_GATE="$test_dir/curl-gate" \
    run_tool "$test_dir" "$test_dir/stdout-1" "$test_dir/stderr-1" --check-if-due &
  first_pid=$!
  while [[ ! -e "$test_dir/curl-gate.ready" && $wait_count -lt 500 ]]; do
    sleep 0.01
    wait_count=$((wait_count + 1))
  done
  [[ -e "$test_dir/curl-gate.ready" ]] \
    || fail "first concurrent check did not reach the release query"

  run_tool "$test_dir" "$test_dir/stdout-2" "$test_dir/stderr-2" --check-if-due &
  second_pid=$!
  sleep 0.05
  : >"$test_dir/curl-gate.release"
  wait "$first_pid" || fail "first concurrent check exited nonzero"
  wait "$second_pid" || fail "second concurrent check exited nonzero"

  [[ "$(wc -l <"$test_dir/query-log")" -eq 7 ]] \
    || fail "concurrent due checks performed duplicate release queries"
  jq -e '.check_status == "success"' "$state_dir/state.json" >/dev/null \
    || fail "concurrent checks left invalid state"
  if compgen -G "$state_dir/state.json.tmp.*" >/dev/null; then
    fail "atomic state write left a temporary file"
  fi
}

test_update_and_check_modes_share_the_state_lock() {
  local lock_fd
  local state_dir
  local test_dir
  local update_pid
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_dir="$test_dir/state/update-agent-tools"
  mkdir -p "$state_dir"

  exec {lock_fd}>"$state_dir/lock"
  flock "$lock_fd"
  run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" &
  update_pid=$!
  sleep 0.05
  [[ ! -e "$test_dir/command-log" ]] \
    || fail "update mode passed the shared lock while it was held"

  flock -u "$lock_fd"
  exec {lock_fd}>&-
  if wait "$update_pid"; then
    fail "stubbed update unexpectedly succeeded"
  fi
  [[ -s "$test_dir/command-log" ]] \
    || fail "update mode did not continue after the shared lock was released"
}

test_failed_check_preserves_cache_and_retries_after_one_hour() {
  local test_dir
  local expected_failure
  local state_file
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  AOE_CURRENT="1.2.2" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-14T10:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-1" "$test_dir/stderr-1" --check-if-due \
    || fail "cache-seeding check exited nonzero: $(<"$test_dir/stderr-1")"
  [[ "$(<"$test_dir/stdout-1")" == "AoE: 1.2.2 -> 1.2.3" ]] \
    || fail "cache-seeding check wrote unexpected output"

  expected_failure='update-agent-tools: agent-tool update check failed; last successful check: 2026-07-14T10:00:00Z; next retry: 2026-07-15T11:00:00Z'
  if CURL_FAIL=1 \
    UPDATE_AGENT_TOOLS_NOW="2026-07-15T10:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-2" "$test_dir/stderr-2" --check-if-due; then
    fail "failed registry check exited zero"
  fi
  [[ ! -s "$test_dir/stdout-2" ]] \
    || fail "failed registry check presented cached output as current"
  diff -u <(printf '%s\n' "$expected_failure") "$test_dir/stderr-2" \
    || fail "failed registry check output did not match"
  jq -e '
    .last_attempt == "2026-07-15T10:00:00Z"
    and .last_successful_check == "2026-07-14T10:00:00Z"
    and .cached_version_result == "AoE: 1.2.2 -> 1.2.3"
    and .check_status == "failed"
    and .last_successful_activation == null
    and .activation_failure == null
  ' "$state_file" >/dev/null \
    || fail "failed registry check did not preserve complete state"

  UPDATE_AGENT_TOOLS_NOW="2026-07-15T10:59:59Z" \
    run_tool "$test_dir" "$test_dir/stdout-3" "$test_dir/stderr-3" --check-if-due \
    || fail "pre-retry check exited nonzero"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 8 ]] \
    || fail "pre-retry check queried a registry or release"
  [[ ! -s "$test_dir/stdout-3" ]] \
    || fail "pre-retry check presented cached output as current"
  diff -u <(printf '%s\n' "$expected_failure") "$test_dir/stderr-3" \
    || fail "pre-retry failure output did not match"

  UPDATE_AGENT_TOOLS_NOW="2026-07-15T11:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-4" "$test_dir/stderr-4" --check-if-due \
    || fail "one-hour retry exited nonzero: $(<"$test_dir/stderr-4")"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 15 ]] \
    || fail "one-hour retry did not perform fresh release queries"
}

test_empty_npm_version_is_a_failed_check() {
  local expected_failure
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  AOE_CURRENT="1.2.2" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-12T08:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-1" "$test_dir/stderr-1" --check-if-due \
    || fail "empty-npm cache seed exited nonzero: $(<"$test_dir/stderr-1")"

  expected_failure='update-agent-tools: agent-tool update check failed; last successful check: 2026-07-12T08:00:00Z; next retry: 2026-07-13T09:00:00Z'
  if NPM_EMPTY_PACKAGE="@openai/codex@latest" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-13T08:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-2" "$test_dir/stderr-2" --check-if-due; then
    fail "empty npm version was committed as a successful check"
  fi
  [[ ! -s "$test_dir/stdout-2" ]] \
    || fail "empty npm version presented cached output as current"
  diff -u <(printf '%s\n' "$expected_failure") "$test_dir/stderr-2" \
    || fail "empty npm version failure output did not match"
  jq -e '
    .last_attempt == "2026-07-13T08:00:00Z"
    and .last_successful_check == "2026-07-12T08:00:00Z"
    and .cached_version_result == "AoE: 1.2.2 -> 1.2.3"
    and .check_status == "failed"
  ' "$state_file" >/dev/null \
    || fail "empty npm version replaced the last known-good state"
}

test_npm_registry_failure_preserves_cache_and_retries_after_one_hour() {
  local expected_failure
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  AOE_CURRENT="1.2.2" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-10T06:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-1" "$test_dir/stderr-1" --check-if-due \
    || fail "npm-failure cache seed exited nonzero: $(<"$test_dir/stderr-1")"

  expected_failure='update-agent-tools: agent-tool update check failed; last successful check: 2026-07-10T06:00:00Z; next retry: 2026-07-11T07:00:00Z'
  if NPM_FAIL_PACKAGE="@anthropic-ai/claude-code@latest" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-11T06:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-2" "$test_dir/stderr-2" --check-if-due; then
    fail "npm registry failure exited zero"
  fi
  [[ ! -s "$test_dir/stdout-2" ]] \
    || fail "npm registry failure presented cached output as current"
  diff -u <(printf '%s\n' "$expected_failure") "$test_dir/stderr-2" \
    || fail "npm registry failure output did not match"
  jq -e '
    .last_attempt == "2026-07-11T06:00:00Z"
    and .last_successful_check == "2026-07-10T06:00:00Z"
    and .cached_version_result == "AoE: 1.2.2 -> 1.2.3"
    and .check_status == "failed"
  ' "$state_file" >/dev/null \
    || fail "npm registry failure replaced the last known-good state"

  UPDATE_AGENT_TOOLS_NOW="2026-07-11T06:59:59Z" \
    run_tool "$test_dir" "$test_dir/stdout-3" "$test_dir/stderr-3" --check-if-due \
    || fail "npm pre-retry check exited nonzero"
  diff -u <(printf '%s\n' "$expected_failure") "$test_dir/stderr-3" \
    || fail "npm pre-retry failure output did not match"
  [[ "$(jq -r '.last_attempt' "$state_file")" == "2026-07-11T06:00:00Z" ]] \
    || fail "npm pre-retry check performed an early attempt"

  UPDATE_AGENT_TOOLS_NOW="2026-07-11T07:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-4" "$test_dir/stderr-4" --check-if-due \
    || fail "npm one-hour retry exited nonzero: $(<"$test_dir/stderr-4")"
  jq -e '
    .last_attempt == "2026-07-11T07:00:00Z"
    and .last_successful_check == "2026-07-11T07:00:00Z"
    and .check_status == "success"
  ' "$state_file" >/dev/null \
    || fail "npm registry failure did not retry at one hour"
}

test_current_toolchain_is_silent() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  mkdir -p "$test_dir/.local/bin"
  for binary in codex claude pi; do
    printf 'sentinel-%s\n' "$binary" >"$test_dir/.local/bin/$binary"
  done

  if ! run_check "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "current toolchain check exited nonzero: $(<"$test_dir/stderr")"
  fi

  [[ ! -s "$test_dir/stdout" ]] \
    || fail "current toolchain check wrote stdout: $(<"$test_dir/stdout")"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "current toolchain check wrote stderr: $(<"$test_dir/stderr")"
  for binary in codex claude pi; do
    [[ "$(<"$test_dir/.local/bin/$binary")" == "sentinel-$binary" ]] \
      || fail "current toolchain check changed the installed $binary binary"
  done
}

test_outdated_components_report_exact_versions() {
  local test_dir
  local expected
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if ! AOE_CURRENT="1.2.2" \
    CODEX_CURRENT="2.3.3" \
    CLAUDE_CURRENT="3.4.4" \
    PI_CURRENT="4.5.5" \
    CODEX_ACP_CURRENT="5.6.6" \
    CLAUDE_ACP_CURRENT="6.7.7" \
    PI_ACP_CURRENT="7.8.8" \
    BUNDLED_CODEX_CURRENT="2.3.2" \
    run_check "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "outdated toolchain check exited nonzero: $(<"$test_dir/stderr")"
  fi

  expected="$(cat <<'EOF'
AoE: 1.2.2 -> 1.2.3
Codex CLI (standalone): 2.3.3 -> 2.3.4
Claude Code CLI: 3.4.4 -> 3.4.5
Pi agent CLI: 4.5.5 -> 4.5.6
codex-acp adapter: 5.6.6 -> 5.6.7
claude-agent-acp adapter: 6.7.7 -> 6.7.8
pi-acp adapter: 7.8.8 -> 7.8.9
Codex runtime (codex-acp): 2.3.2 -> 2.3.4
EOF
)"
  diff -u <(printf '%s\n' "$expected") "$test_dir/stdout" \
    || fail "outdated toolchain output did not match"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "outdated toolchain check wrote stderr: $(<"$test_dir/stderr")"
}

test_missing_components_are_reported() {
  local test_dir
  local expected
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  rm "$test_dir/stubs/aoe"

  if ! NPM_FIXTURE="missing" \
    run_check "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "missing toolchain check exited nonzero: $(<"$test_dir/stderr")"
  fi

  expected="$(cat <<'EOF'
AoE: missing -> 1.2.3
claude-agent-acp adapter: missing -> 6.7.8
EOF
)"
  diff -u <(printf '%s\n' "$expected") "$test_dir/stdout" \
    || fail "missing toolchain output did not match"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "missing toolchain check wrote stderr: $(<"$test_dir/stderr")"
}

test_nested_codex_runtime_is_a_distinct_scope() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if ! BUNDLED_CODEX_CURRENT="2.3.3" \
    run_check "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "nested Codex check exited nonzero: $(<"$test_dir/stderr")"
  fi

  diff -u \
    <(printf 'Codex runtime (codex-acp): 2.3.3 -> 2.3.4\n') \
    "$test_dir/stdout" \
    || fail "nested Codex output did not match"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "nested Codex check wrote stderr: $(<"$test_dir/stderr")"
}

test_nested_codex_uses_latest_adapter_compatible_target() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if ! CODEX_CURRENT="2.4.0" \
    CODEX_LATEST="2.4.0" \
    BUNDLED_CODEX_CURRENT="2.3.3" \
    BUNDLED_CODEX_RANGE="^2.3.0" \
    BUNDLED_CODEX_VERSIONS_JSON='["2.3.3","2.3.4"]' \
    run_check "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "adapter-compatible Codex check exited nonzero: $(<"$test_dir/stderr")"
  fi

  diff -u \
    <(printf 'Codex runtime (codex-acp): 2.3.3 -> 2.3.4\n') \
    "$test_dir/stdout" \
    || fail "adapter-compatible Codex output did not match"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "adapter-compatible Codex check wrote stderr: $(<"$test_dir/stderr")"
}

test_nested_codex_accepts_a_single_compatible_version() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if ! CODEX_CURRENT="2.4.0" \
    CODEX_LATEST="2.4.0" \
    BUNDLED_CODEX_CURRENT="2.3.3" \
    BUNDLED_CODEX_RANGE="~2.3.4" \
    BUNDLED_CODEX_VERSIONS_JSON='"2.3.4"' \
    run_check "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "single-version Codex check exited nonzero: $(<"$test_dir/stderr")"
  fi

  diff -u \
    <(printf 'Codex runtime (codex-acp): 2.3.3 -> 2.3.4\n') \
    "$test_dir/stdout" \
    || fail "single-version Codex output did not match"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "single-version Codex check wrote stderr: $(<"$test_dir/stderr")"
}

test_nested_codex_ignores_compatible_prereleases() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if ! CODEX_CURRENT="2.4.0" \
    CODEX_LATEST="2.4.0" \
    BUNDLED_CODEX_CURRENT="2.3.3" \
    BUNDLED_CODEX_RANGE="^2.3.0 || >=2.5.0-beta.0 <2.5.0" \
    BUNDLED_CODEX_VERSIONS_JSON='["2.3.3","2.3.4","2.5.0-beta.1"]' \
    run_check "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "stable nested Codex check exited nonzero: $(<"$test_dir/stderr")"
  fi

  diff -u \
    <(printf 'Codex runtime (codex-acp): 2.3.3 -> 2.3.4\n') \
    "$test_dir/stdout" \
    || fail "stable nested Codex output did not match"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "stable nested Codex check wrote stderr: $(<"$test_dir/stderr")"
}

test_due_check_runs_once_per_success_interval
test_state_uses_local_state_fallback
test_concurrent_due_checks_are_serialized
test_update_and_check_modes_share_the_state_lock
test_failed_check_preserves_cache_and_retries_after_one_hour
test_empty_npm_version_is_a_failed_check
test_npm_registry_failure_preserves_cache_and_retries_after_one_hour
test_current_toolchain_is_silent
test_outdated_components_report_exact_versions
test_missing_components_are_reported
test_nested_codex_runtime_is_a_distinct_scope
test_nested_codex_uses_latest_adapter_compatible_target
test_nested_codex_accepts_a_single_compatible_version
test_nested_codex_ignores_compatible_prereleases
printf 'PASS: update-agent-tools --check\n'
