#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly COMMAND="$REPO_ROOT/dot_local/bin/executable_update-agent-tools"
readonly CHECK_STATUS_UPDATES_AVAILABLE=10
REAL_BASH="$(command -v bash)"
REAL_DATE="$(command -v date)"
readonly REAL_BASH REAL_DATE

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Engine declarations the npm registry serves by default: one Bun floor the
# installed release clears, one Node floor the profile clears.
DEFAULT_OMP_ENGINES='{"bun":">=1.0.0"}'
DEFAULT_PI_ENGINES='{"node":">=20.0.0"}'
readonly DEFAULT_OMP_ENGINES DEFAULT_PI_ENGINES

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

COMMAND_PATH="$(resolved_command_path \
  bash chmod cut find flock grep head install jq ln mkdir mktemp mv rm sed \
  sha256sum sort tail unzip)"
readonly COMMAND_PATH

make_stubs() {
  local stub_dir="$1"
  local home

  mkdir -p "$stub_dir"
  home="$(dirname "$stub_dir")"
  mkdir -p "$home/.local/bin"

  printf '#!%s\n' "$REAL_BASH" >"$home/.local/bin/aoe"
  cat >>"$home/.local/bin/aoe" <<'STUB'
set -euo pipefail

if [[ "$*" == "--version" ]]; then
  if [[ -e "$HOME/aoe-updated" ]]; then
    printf 'aoe %s\n' "$AOE_LATEST"
  else
    printf 'aoe %s\n' "$AOE_CURRENT"
  fi
  exit 0
fi

printf 'aoe %s\n' "$*" >>"$COMMAND_LOG"

if [[ "$*" == "update --yes" ]]; then
  if [[ "${AOE_UPDATE_FAIL:-0}" == "1" ]]; then
    exit 1
  fi
  : >"$HOME/aoe-updated"
  exit 0
fi

if [[ "$*" == "acp doctor" ]]; then
  doctor_count=0
  if [[ -f "$HOME/doctor-count" ]]; then
    doctor_count="$(<"$HOME/doctor-count")"
  fi
  doctor_count=$((doctor_count + 1))
  printf '%s\n' "$doctor_count" >"$HOME/doctor-count"
  if [[ "${AOE_DOCTOR_FAIL_CALL:-0}" == "$doctor_count" ]]; then
    exit 1
  fi
  if [[ "${AOE_DOCTOR_FAIL_AFTER:-0}" -gt 0 \
    && "$doctor_count" -ge "${AOE_DOCTOR_FAIL_AFTER}" ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "$*" == "ps --acp --dead --json" ]]; then
  ps_count=0
  if [[ -f "$HOME/acp-ps-count" ]]; then
    ps_count="$(<"$HOME/acp-ps-count")"
  fi
  ps_count=$((ps_count + 1))
  printf '%s\n' "$ps_count" >"$HOME/acp-ps-count"
  jq -c --argjson index "$((ps_count - 1))" '
    if length == 0 then []
    elif $index < length then .[$index]
    else .[-1]
    end
  ' <<<"$ACP_PS_SEQUENCE_JSON"
  exit 0
fi

if [[ "$1" == "acp" && "$2" == "restart" && $# -eq 3 ]]; then
  [[ "${ACP_RESTART_FAIL:-0}" != "1" ]]
  exit
fi

printf 'unexpected aoe invocation: %s\n' "$*" >&2
exit 64
STUB

  printf '#!%s\n' "$REAL_BASH" >"$stub_dir/curl"
  cat >>"$stub_dir/curl" <<'STUB'
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

if [[ "$*" == "-fsSL https://api.github.com/repos/oven-sh/bun/releases/latest" ]]; then
  printf 'curl bun release\n' >>"$QUERY_LOG"
  if [[ "${BUN_RELEASE_FAIL:-0}" == "1" ]]; then
    printf 'bun release registry unavailable\n' >&2
    exit 22
  fi
  if [[ -n "${BUN_RELEASE_JSON:-}" ]]; then
    printf '%s\n' "$BUN_RELEASE_JSON"
    exit 0
  fi
  bun_digest="${BUN_DIGEST_OVERRIDE:-sha256:$(sha256sum "$HOME/bun-archive/bun.zip" | cut -d ' ' -f 1)}"
  printf '{"tag_name":"bun-v%s","assets":[' "$BUN_LATEST"
  printf '{"name":"bun-linux-x64-baseline.zip","browser_download_url":"https://example.invalid/baseline.zip","digest":"%s"},' \
    "$bun_digest"
  printf '{"name":"bun-linux-x64.zip","browser_download_url":"https://example.invalid/avx2.zip","digest":"%s"}' \
    "$bun_digest"
  printf ']}\n'
  exit 0
fi

if [[ "$1" == "-fsSL" && "$2" == "-o" ]]; then
  printf 'curl bun archive %s\n' "$4" >>"$QUERY_LOG"
  printf 'bun install %s\n' "$4" >>"$COMMAND_LOG"
  if [[ "${BUN_ARCHIVE_FAIL:-0}" == "1" ]]; then
    printf 'bun archive unavailable\n' >&2
    exit 22
  fi
  cp "$HOME/bun-archive/bun.zip" "$3"
  : >"$HOME/bun-installed"
  exit 0
fi

printf 'unexpected curl invocation: %s\n' "$*" >&2
exit 64
STUB

  printf '#!%s\n' "$REAL_BASH" >"$stub_dir/npm"
  cat >>"$stub_dir/npm" <<'STUB'
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
  if [[ "${NPM_LIST_EMPTY:-0}" == "1" ]]; then
    exit 0
  fi
  codex_current="$CODEX_CURRENT"
  claude_current="$CLAUDE_CURRENT"
  pi_current="$PI_CURRENT"
  opencode_current="$OPENCODE_CURRENT"
  omp_current="$OMP_CURRENT"
  codex_acp_current="$CODEX_ACP_CURRENT"
  claude_acp_current="$CLAUDE_ACP_CURRENT"
  pi_acp_current="$PI_ACP_CURRENT"
  bundled_codex_current="$BUNDLED_CODEX_CURRENT"
  if [[ -e "$HOME/npm-installed" ]]; then
    codex_current="$CODEX_LATEST"
    claude_current="$CLAUDE_LATEST"
    pi_current="$PI_LATEST"
    opencode_current="$OPENCODE_LATEST"
    omp_current="$OMP_LATEST"
    codex_acp_current="$CODEX_ACP_LATEST"
    claude_acp_current="$CLAUDE_ACP_LATEST"
    pi_acp_current="$PI_ACP_LATEST"
    bundled_codex_current="$(jq -r 'if type == "array" then .[-1] else . end' <<<"$BUNDLED_CODEX_VERSIONS_JSON")"
    if [[ -n "${CODEX_POST_INSTALL:-}" ]]; then
      codex_current="$CODEX_POST_INSTALL"
    fi
  fi
  if [[ "${NPM_FIXTURE:-complete}" == "missing" ]]; then
    cat <<EOF
{
  "dependencies": {
    "@openai/codex": {"version": "${codex_current}"},
    "@anthropic-ai/claude-code": {"version": "${claude_current}"},
    "@earendil-works/pi-coding-agent": {"version": "${pi_current}"},
    "opencode-ai": {"version": "${opencode_current}"},
    "@oh-my-pi/pi-coding-agent": {"version": "${omp_current}"},
    "@agentclientprotocol/codex-acp": {
      "version": "${codex_acp_current}",
      "dependencies": {"@openai/codex": {"version": "${bundled_codex_current}"}}
    },
    "pi-acp": {"version": "${pi_acp_current}"}
  }
}
EOF
    exit 0
  fi

  cat <<EOF
{
  "dependencies": {
    "@openai/codex": {"version": "${codex_current}"},
    "@anthropic-ai/claude-code": {"version": "${claude_current}"},
    "@earendil-works/pi-coding-agent": {"version": "${pi_current}"},
    "opencode-ai": {"version": "${opencode_current}"},
    "@oh-my-pi/pi-coding-agent": {"version": "${omp_current}"},
    "@agentclientprotocol/codex-acp": {
      "version": "${codex_acp_current}",
      "dependencies": {"@openai/codex": {"version": "${bundled_codex_current}"}}
    },
    "@agentclientprotocol/claude-agent-acp": {"version": "${claude_acp_current}"},
    "pi-acp": {"version": "${pi_acp_current}"}
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

if [[ "$1" == "view" && "$3" == "engines" && "$4" == "--json" ]]; then
  case "$2" in
    '@oh-my-pi/pi-coding-agent@latest') engines="$OMP_ENGINES" ;;
    '@earendil-works/pi-coding-agent@latest') engines="$PI_ENGINES" ;;
    *) engines="$OTHER_ENGINES" ;;
  esac
  [[ -z "$engines" ]] || printf '%s\n' "$engines"
  exit 0
fi

if [[ "$1" == "view" && "$3" == "version" ]]; then
  printf 'npm %s\n' "$*" >>"$QUERY_LOG"
  case "$2" in
    '@openai/codex@latest') printf '%s\n' "$CODEX_LATEST" ;;
    '@anthropic-ai/claude-code@latest') printf '%s\n' "$CLAUDE_LATEST" ;;
    '@earendil-works/pi-coding-agent@latest') printf '%s\n' "$PI_LATEST" ;;
    'opencode-ai@latest') printf '%s\n' "$OPENCODE_LATEST" ;;
    '@oh-my-pi/pi-coding-agent@latest') printf '%s\n' "$OMP_LATEST" ;;
    '@agentclientprotocol/codex-acp@latest') printf '%s\n' "$CODEX_ACP_LATEST" ;;
    '@agentclientprotocol/claude-agent-acp@latest') printf '%s\n' "$CLAUDE_ACP_LATEST" ;;
    'pi-acp@latest') printf '%s\n' "$PI_ACP_LATEST" ;;
    *) printf 'unexpected npm package: %s\n' "$2" >&2; exit 64 ;;
  esac
  exit 0
fi

if [[ "$1" == "install" && "$2" == "--global" ]]; then
  package="$3"
  if [[ "${NPM_REQUIRE_CLEARED_SHIMS:-0}" == "1" ]]; then
    for stale_binary in codex claude pi opencode omp; do
      stale_path="$HOME/.local/bin/$stale_binary"
      if [[ -e "$stale_path" || -L "$stale_path" ]] \
        && grep -Fx 'stale-shim' "$stale_path" >/dev/null 2>&1; then
        printf 'stale shim blocked npm install: %s\n' "$stale_binary" >&2
        exit 1
      fi
    done
  fi
  if [[ "${NPM_INSTALL_FAIL_PACKAGE:-}" == "$package" ]]; then
    exit 1
  fi
  case "$package" in
    '@openai/codex@latest') binary=codex ;;
    '@anthropic-ai/claude-code@latest') binary=claude ;;
    '@earendil-works/pi-coding-agent@latest') binary=pi ;;
    'opencode-ai@latest') binary=opencode ;;
    '@oh-my-pi/pi-coding-agent@latest') binary=omp ;;
    '@agentclientprotocol/codex-acp@latest') binary=codex-acp ;;
    '@agentclientprotocol/claude-agent-acp@latest') binary=claude-agent-acp ;;
    'pi-acp@latest') binary=pi-acp ;;
    *) printf 'unexpected npm install package: %s\n' "$package" >&2; exit 64 ;;
  esac
  if [[ "$binary" != "${NPM_OMIT_BINARY:-}" ]]; then
    printf '#!%s\nprintf "%s %%s\\n" "$*" >>"$COMMAND_LOG"\nexit 0\n' \
      "$TEST_REAL_BASH" "$binary" \
      >"$HOME/.local/bin/$binary"
    chmod +x "$HOME/.local/bin/$binary"
  fi
  if [[ "$package" == "@oh-my-pi/pi-coding-agent@latest" ]]; then
    : >"$HOME/npm-installed"
  fi
  exit 0
fi

printf 'unexpected npm invocation: %s\n' "$*" >&2
exit 64
STUB

  printf '#!%s\n' "$REAL_BASH" >"$stub_dir/systemctl"
  cat >>"$stub_dir/systemctl" <<'STUB'
set -euo pipefail

printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"
if [[ "$*" == "--user restart aoe-serve.service" ]]; then
  [[ "${SYSTEMCTL_RESTART_FAIL:-0}" != "1" ]]
  exit
fi
if [[ "$*" == "--user is-active --quiet aoe-serve.service" ]]; then
  [[ "${SYSTEMCTL_INACTIVE:-0}" != "1" ]]
  exit
fi
exit 64
STUB

  printf '#!%s\n' "$REAL_BASH" >"$stub_dir/sleep"
  cat >>"$stub_dir/sleep" <<'STUB'
set -euo pipefail
printf 'sleep %s\n' "$*" >>"$COMMAND_LOG"
STUB

  printf '#!%s\n' "$REAL_BASH" >"$stub_dir/date"
  cat >>"$stub_dir/date" <<'STUB'
set -euo pipefail
printf 'date %s\n' "$*" >>"$COMMAND_LOG"
exec "$TEST_REAL_DATE" "$@"
STUB

  printf '#!%s\n' "$REAL_BASH" >"$stub_dir/node"
  cat >>"$stub_dir/node" <<'STUB'
set -euo pipefail
printf 'v%s\n' "$NODE_VERSION"
STUB

  make_bun_archive "$home"
  # An ordinary workstation already has a Bun; tests that need it absent remove
  # it, the way the transition off the Nix-provided one leaves the host.
  cp "$home/bun-archive/bun-linux-x64-baseline/bun" "$home/.local/bin/bun"
  chmod +x "$home/.local/bin/bun"
  ln -sfn bun "$home/.local/bin/bunx"

  chmod +x "$home/.local/bin/aoe" "$stub_dir/curl" "$stub_dir/npm" \
    "$stub_dir/systemctl" "$stub_dir/sleep" "$stub_dir/date" "$stub_dir/node"
}

# The updater unpacks whatever the release serves, so the fixture has to be a
# real archive laid out the way Bun ships one: <archive-root>/bun.
make_bun_archive() {
  local home="$1"
  local root="$home/bun-archive"

  mkdir -p "$root/bun-linux-x64-baseline"
  printf '#!%s\n' "$REAL_BASH" >"$root/bun-linux-x64-baseline/bun"
  cat >>"$root/bun-linux-x64-baseline/bun" <<'STUB'
set -euo pipefail

if [[ "$*" == "--version" ]]; then
  if [[ -e "$HOME/bun-installed" ]]; then
    printf '%s\n' "$BUN_LATEST"
  else
    printf '%s\n' "$BUN_CURRENT"
  fi
  exit 0
fi

printf 'bun %s\n' "$*" >>"$COMMAND_LOG"
exit 0
STUB
  chmod +x "$root/bun-linux-x64-baseline/bun"
  ( cd "$root" && zip --quiet --recurse-paths bun.zip bun-linux-x64-baseline )
  printf 'flags : fpu sse2 sse4_2 bmi1\n' >"$home/cpuinfo-baseline"
  printf 'flags : fpu sse2 sse4_2 bmi1 avx2\n' >"$home/cpuinfo-avx2"
}


execute_tool() {
  local stdout_file="$1"
  local stderr_file="$2"
  local command_line
  shift 2

  if [[ "${TEST_RUN_IN_TTY:-0}" == "1" ]]; then
    printf -v command_line '%q ' bash "$COMMAND" "$@"
    printf '%s' "${TEST_TTY_INPUT:-}" \
      | script -qefc "$command_line" /dev/null \
        >"$stdout_file" 2>"$stderr_file"
  else
    bash "$COMMAND" "$@" </dev/null >"$stdout_file" 2>"$stderr_file"
  fi
}

run_tool() {
  local home="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3

  HOME="$home" \
    XDG_STATE_HOME="${TEST_XDG_STATE_HOME-$home/state}" \
    PATH="$home/.local/bin:$home/stubs:$COMMAND_PATH" \
    QUERY_LOG="$home/query-log" \
    COMMAND_LOG="$home/command-log" \
    TEST_REAL_BASH="$REAL_BASH" \
    TEST_REAL_DATE="$REAL_DATE" \
    UPDATE_AGENT_TOOLS_NOW="${UPDATE_AGENT_TOOLS_NOW:-2026-07-14T00:00:00Z}" \
    UPDATE_AGENT_TOOLS_ACTIVATION_NOW="${UPDATE_AGENT_TOOLS_ACTIVATION_NOW:-}" \
    CURL_FAIL="${CURL_FAIL:-0}" \
    CURL_GATE="${CURL_GATE:-}" \
    NPM_EMPTY_PACKAGE="${NPM_EMPTY_PACKAGE:-}" \
    NPM_FAIL_PACKAGE="${NPM_FAIL_PACKAGE:-}" \
    NPM_FIXTURE="${NPM_FIXTURE:-complete}" \
    NPM_LIST_EMPTY="${NPM_LIST_EMPTY:-0}" \
    NPM_INSTALL_FAIL_PACKAGE="${NPM_INSTALL_FAIL_PACKAGE:-}" \
    NPM_REQUIRE_CLEARED_SHIMS="${NPM_REQUIRE_CLEARED_SHIMS:-0}" \
    NPM_OMIT_BINARY="${NPM_OMIT_BINARY:-}" \
    AOE_UPDATE_FAIL="${AOE_UPDATE_FAIL:-0}" \
    AOE_DOCTOR_FAIL_CALL="${AOE_DOCTOR_FAIL_CALL:-0}" \
    AOE_DOCTOR_FAIL_AFTER="${AOE_DOCTOR_FAIL_AFTER:-0}" \
    ACP_PS_SEQUENCE_JSON="${ACP_PS_SEQUENCE_JSON:-[[]]}" \
    ACP_RESTART_FAIL="${ACP_RESTART_FAIL:-0}" \
    SYSTEMCTL_RESTART_FAIL="${SYSTEMCTL_RESTART_FAIL:-0}" \
    SYSTEMCTL_INACTIVE="${SYSTEMCTL_INACTIVE:-0}" \
    BUN_CURRENT="${BUN_CURRENT:-1.4.0}" \
    BUN_LATEST="${BUN_LATEST:-1.4.0}" \
    BUN_RELEASE_FAIL="${BUN_RELEASE_FAIL:-0}" \
    BUN_RELEASE_JSON="${BUN_RELEASE_JSON:-}" \
    BUN_ARCHIVE_FAIL="${BUN_ARCHIVE_FAIL:-0}" \
    BUN_DIGEST_OVERRIDE="${BUN_DIGEST_OVERRIDE:-}" \
    NODE_VERSION="${NODE_VERSION:-24.14.1}" \
    OMP_ENGINES="${OMP_ENGINES-$DEFAULT_OMP_ENGINES}" \
    PI_ENGINES="${PI_ENGINES-$DEFAULT_PI_ENGINES}" \
    OTHER_ENGINES="${OTHER_ENGINES-}" \
    UPDATE_AGENT_TOOLS_CPUINFO="${UPDATE_AGENT_TOOLS_CPUINFO:-$home/cpuinfo-baseline}" \
    AOE_CURRENT="${AOE_CURRENT:-1.2.3}" \
    AOE_LATEST="${AOE_LATEST:-1.2.3}" \
    CODEX_CURRENT="${CODEX_CURRENT:-2.3.4}" \
    CODEX_LATEST="${CODEX_LATEST:-2.3.4}" \
    CODEX_POST_INSTALL="${CODEX_POST_INSTALL:-}" \
    CLAUDE_CURRENT="${CLAUDE_CURRENT:-3.4.5}" \
    CLAUDE_LATEST="${CLAUDE_LATEST:-3.4.5}" \
    PI_CURRENT="${PI_CURRENT:-4.5.6}" \
    PI_LATEST="${PI_LATEST:-4.5.6}" \
    OPENCODE_CURRENT="${OPENCODE_CURRENT:-8.9.0}" \
    OPENCODE_LATEST="${OPENCODE_LATEST:-8.9.0}" \
    OMP_CURRENT="${OMP_CURRENT:-9.10.0}" \
    OMP_LATEST="${OMP_LATEST:-9.10.0}" \
    CODEX_ACP_CURRENT="${CODEX_ACP_CURRENT:-5.6.7}" \
    CODEX_ACP_LATEST="${CODEX_ACP_LATEST:-5.6.7}" \
    CLAUDE_ACP_CURRENT="${CLAUDE_ACP_CURRENT:-6.7.8}" \
    CLAUDE_ACP_LATEST="${CLAUDE_ACP_LATEST:-6.7.8}" \
    PI_ACP_CURRENT="${PI_ACP_CURRENT:-7.8.9}" \
    PI_ACP_LATEST="${PI_ACP_LATEST:-7.8.9}" \
    BUNDLED_CODEX_CURRENT="${BUNDLED_CODEX_CURRENT:-2.3.4}" \
    BUNDLED_CODEX_RANGE="${BUNDLED_CODEX_RANGE:-^2.3.0}" \
    BUNDLED_CODEX_VERSIONS_JSON="${BUNDLED_CODEX_VERSIONS_JSON:-[\"2.3.3\",\"2.3.4\"]}" \
    TEST_RUN_IN_TTY="${TEST_RUN_IN_TTY:-0}" \
    TEST_TTY_INPUT="${TEST_TTY_INPUT:-}" \
    execute_tool "$stdout_file" "$stderr_file" "$@"
}

run_check() {
  run_tool "$1" "$2" "$3" --check
}

test_machine_status_reports_current_by_exit_status_without_output() {
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --check-status \
    || fail "current machine status exited nonzero: $(<"$test_dir/stderr")"

  [[ ! -s "$test_dir/stdout" ]] \
    || fail "current machine status wrote stdout"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "current machine status wrote stderr"
  jq -e '
    .last_attempt == "2026-07-14T00:00:00Z"
    and .last_successful_check == "2026-07-14T00:00:00Z"
    and .cached_version_result == ""
    and .check_status == "success"
  ' "$state_file" >/dev/null \
    || fail "current machine status did not record fresh success"
}

test_machine_status_reports_outdated_by_exit_status_without_output() {
  local state_file
  local status
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  if AOE_CURRENT="1.2.2" \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --check-status; then
    fail "outdated machine status exited zero"
  else
    status=$?
  fi

  [[ "$status" -eq "$CHECK_STATUS_UPDATES_AVAILABLE" ]] \
    || fail "outdated machine status exited $status instead of $CHECK_STATUS_UPDATES_AVAILABLE"
  [[ ! -s "$test_dir/stdout" ]] \
    || fail "outdated machine status wrote stdout"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "outdated machine status wrote stderr"
  jq -e '
    .last_attempt == "2026-07-14T00:00:00Z"
    and .last_successful_check == "2026-07-14T00:00:00Z"
    and .cached_version_result == "AoE: 1.2.2 -> 1.2.3"
    and .check_status == "success"
  ' "$state_file" >/dev/null \
    || fail "outdated machine status did not record fresh success"
  if grep -Eq '^(aoe update|aoe ps --acp|aoe acp restart|npm install|systemctl )' \
    "$test_dir/command-log"; then
    fail "outdated machine status mutated or inspected ACP workers"
  fi
}

test_machine_status_reports_discovery_failure_and_preserves_freshness_state() {
  local state_file
  local status
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  AOE_CURRENT="1.2.2" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-13T00:00:00Z" \
    run_tool "$test_dir" "$test_dir/seed-stdout" "$test_dir/seed-stderr" --check \
    || fail "machine-status cache seed failed"

  if CURL_FAIL=1 \
    UPDATE_AGENT_TOOLS_NOW="2026-07-14T00:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --check-status; then
    fail "failed machine status exited zero"
  else
    status=$?
  fi

  [[ "$status" -eq 1 ]] \
    || fail "failed machine status exited $status instead of 1"
  [[ ! -s "$test_dir/stdout" ]] \
    || fail "failed machine status wrote stdout"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "failed machine status wrote stderr: $(<"$test_dir/stderr")"
  jq -e '
    .last_attempt == "2026-07-14T00:00:00Z"
    and .last_successful_check == "2026-07-13T00:00:00Z"
    and .cached_version_result == "AoE: 1.2.2 -> 1.2.3"
    and .check_status == "failed"
  ' "$state_file" >/dev/null \
    || fail "failed machine status did not preserve freshness state"
  if grep -Eq '^(aoe update|aoe ps --acp|aoe acp restart|npm install|systemctl )' \
    "$test_dir/command-log"; then
    fail "failed machine status mutated or inspected ACP workers"
  fi
}

test_machine_status_reports_unresolved_activation_failure_as_maintenance_needed() {
  local state_dir
  local state_file
  local status
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_dir="$test_dir/state/update-agent-tools"
  state_file="$state_dir/state.json"
  mkdir -p "$state_dir"
  printf '%s\n' '{
    "last_successful_activation":"2026-07-13T00:00:00Z",
    "activation_failure":{
      "phase":"activation",
      "component":"AoE service restart",
      "failed_at":"2026-07-13T01:00:00Z"
    }
  }' >"$state_file"

  if run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --check-status; then
    fail "machine status accepted an unresolved activation failure as current"
  else
    status=$?
  fi

  [[ "$status" -eq "$CHECK_STATUS_UPDATES_AVAILABLE" ]] \
    || fail "activation-failed machine status exited $status instead of $CHECK_STATUS_UPDATES_AVAILABLE"
  [[ ! -s "$test_dir/stdout" && ! -s "$test_dir/stderr" ]] \
    || fail "activation-failed machine status wrote output"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 10 ]] \
    || fail "activation-failed machine status did not perform fresh discovery"
  jq -e '
    .last_successful_check == "2026-07-14T00:00:00Z"
    and .cached_version_result == ""
    and .check_status == "success"
    and .activation_failure.phase == "activation"
    and .activation_failure.component == "AoE service restart"
  ' "$state_file" >/dev/null \
    || fail "activation-failed machine status did not preserve recovery state"
  if grep -Eq '^(aoe update|aoe ps --acp|aoe acp restart|npm install|systemctl )' \
    "$test_dir/command-log"; then
    fail "activation-failed machine status mutated or inspected ACP workers"
  fi
}

test_conditional_update_leaves_current_toolchain_and_acp_workers_alone() {
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  ACP_PS_SEQUENCE_JSON='[[{"session_id":"private-session","pid":101,"alive":true,"build_stale":false}]]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --update-if-needed \
    || fail "current conditional update failed: $(<"$test_dir/stderr")"

  [[ ! -s "$test_dir/stdout" ]] \
    || fail "current conditional update wrote stdout"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "current conditional update wrote stderr"
  jq -e '
    .last_successful_check == "2026-07-14T00:00:00Z"
    and .cached_version_result == ""
    and .check_status == "success"
  ' "$state_file" >/dev/null \
    || fail "current conditional update did not record fresh discovery"
  if grep -Eq '^(aoe update|aoe ps --acp|aoe acp restart|npm install|systemctl )' \
    "$test_dir/command-log"; then
    fail "current conditional update mutated or inspected ACP workers"
  fi
}

test_conditional_update_stops_before_mutation_when_discovery_fails() {
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  if CURL_FAIL=1 \
    ACP_PS_SEQUENCE_JSON='[[{"session_id":"private-session","pid":101,"alive":true,"build_stale":false}]]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --update-if-needed --yes; then
    fail "conditional update accepted failed discovery"
  fi

  [[ ! -s "$test_dir/stdout" ]] \
    || fail "failed conditional update wrote stdout"
  diff -u \
    <(printf '%s\n' \
      'update-agent-tools: discovery phase failed: AoE; correct the problem, then rerun workstation-update') \
    "$test_dir/stderr" \
    || fail "failed conditional update did not identify its component and unified recovery command"
  jq -e '
    .last_attempt == "2026-07-14T00:00:00Z"
    and .last_successful_check == null
    and .cached_version_result == ""
    and .check_status == "failed"
  ' "$state_file" >/dev/null \
    || fail "failed conditional update did not record discovery failure"
  if grep -Eq '^(aoe update|aoe ps --acp|aoe acp restart|npm install|systemctl )' \
    "$test_dir/command-log"; then
    fail "failed conditional update mutated or inspected ACP workers"
  fi
}

test_conditional_update_refreshes_the_whole_toolchain_when_outdated() {
  local discovery_line
  local inspection_line
  local mutation_line
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  AOE_CURRENT="1.2.2" \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --update-if-needed \
    || fail "outdated conditional update failed: $(<"$test_dir/stderr")"

  grep -Fx 'aoe update --yes' "$test_dir/command-log" >/dev/null \
    || fail "outdated conditional update did not update AoE"
  assert_complete_npm_refresh "$test_dir/command-log"
  assert_harness_versions_checked "$test_dir/command-log"
  grep -Fx 'systemctl --user restart aoe-serve.service' "$test_dir/command-log" >/dev/null \
    || fail "outdated conditional update did not activate the whole toolchain"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 22 ]] \
    || fail "outdated conditional update did not perform discovery and verification"
  discovery_line="$(grep -n '^npm view @openai/codex@latest version$' \
    "$test_dir/command-log" | head -n 1 | cut -d: -f1)"
  inspection_line="$(grep -n '^aoe ps --acp --dead --json$' \
    "$test_dir/command-log" | head -n 1 | cut -d: -f1)"
  mutation_line="$(grep -n '^aoe update --yes$' \
    "$test_dir/command-log" | cut -d: -f1)"
  [[ "$discovery_line" -lt "$inspection_line" && "$inspection_line" -lt "$mutation_line" ]] \
    || fail "conditional update did not discover before ACP inspection and mutation"
  jq -e '
    .last_successful_check == "2026-07-14T00:00:00Z"
    and .cached_version_result == ""
    and .check_status == "success"
    and .last_successful_activation == "2026-07-14T00:00:00Z"
    and .activation_failure == null
  ' "$state_file" >/dev/null \
    || fail "successful conditional update did not record current check and activation state"

  UPDATE_AGENT_TOOLS_NOW="2026-07-14T01:00:00Z" \
    run_tool "$test_dir" "$test_dir/after-stdout" "$test_dir/after-stderr" --check-if-due \
    || fail "post-update cached freshness check failed: $(<"$test_dir/after-stderr")"
  [[ ! -s "$test_dir/after-stdout" && ! -s "$test_dir/after-stderr" ]] \
    || fail "post-update cached freshness check replayed a stale update notice"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 22 ]] \
    || fail "post-update not-due freshness check queried registries"
}

test_conditional_update_requires_yes_for_unattended_acp_disruption() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if AOE_CURRENT="1.2.2" \
    ACP_PS_SEQUENCE_JSON='[[{"session_id":"private-session","pid":101,"alive":true,"build_stale":false}]]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --update-if-needed; then
    fail "unattended conditional update disrupted a worker without --yes"
  fi

  diff -u \
    <(printf 'update-agent-tools: 1 running ACP session would be disrupted; rerun workstation-update --yes to authorize replacement\n') \
    "$test_dir/stderr" \
    || fail "unattended conditional refusal was not actionable"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 10 ]] \
    || fail "unattended conditional refusal bypassed fresh discovery"
  if grep -Eq '^(aoe update|aoe acp restart|npm install|systemctl )' \
    "$test_dir/command-log"; then
    fail "unattended conditional refusal mutated the toolchain"
  fi
}

test_conditional_update_yes_authorizes_only_acp_disruption() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  AOE_CURRENT="1.2.2" \
    ACP_PS_SEQUENCE_JSON='[
      [{"session_id":"private-session","pid":101,"alive":true,"build_stale":false}],
      [{"session_id":"private-session","pid":201,"alive":true,"build_stale":false}]
    ]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --update-if-needed --yes \
    || fail "--yes conditional update failed: $(<"$test_dir/stderr")"

  [[ "$(wc -l <"$test_dir/query-log")" -eq 22 ]] \
    || fail "--yes conditional update bypassed discovery or verification"
  assert_complete_npm_refresh "$test_dir/command-log"
  grep -Fx 'systemctl --user restart aoe-serve.service' "$test_dir/command-log" >/dev/null \
    || fail "--yes conditional update did not complete activation"
  if grep -F 'running ACP' "$test_dir/stdout" "$test_dir/stderr" >/dev/null; then
    fail "--yes conditional update prompted for disruption authorization"
  fi
}

test_conditional_interactive_update_prompts_once_for_acp_disruption() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  TEST_RUN_IN_TTY=1 \
    TEST_TTY_INPUT=$'y\n' \
    AOE_CURRENT="1.2.2" \
    ACP_PS_SEQUENCE_JSON='[
      [{"session_id":"private-session","pid":101,"alive":true,"build_stale":false}],
      [{"session_id":"private-session","pid":201,"alive":true,"build_stale":false}]
    ]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --update-if-needed \
    || fail "interactive conditional update failed: $(<"$test_dir/stderr")"

  [[ "$(grep -c '1 running ACP session would be disrupted' "$test_dir/stdout")" -eq 1 ]] \
    || fail "interactive conditional update did not prompt exactly once"
  grep -Fx 'aoe update --yes' "$test_dir/command-log" >/dev/null \
    || fail "authorized interactive conditional update did not mutate"
}

test_conditional_update_retries_a_current_toolchain_after_activation_failure() {
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  if AOE_CURRENT="1.2.2" \
    SYSTEMCTL_RESTART_FAIL=1 \
    run_tool "$test_dir" "$test_dir/failed-stdout" "$test_dir/failed-stderr" --update-if-needed; then
    fail "conditional activation failure exited zero"
  fi
  jq -e '
    .activation_failure.phase == "activation"
    and .activation_failure.component == "AoE service restart"
  ' "$state_file" >/dev/null \
    || fail "conditional activation failure was not recorded"

  UPDATE_AGENT_TOOLS_NOW="2026-07-14T01:00:00Z" \
    run_tool "$test_dir" "$test_dir/retry-stdout" "$test_dir/retry-stderr" --update-if-needed \
    || fail "conditional activation recovery failed: $(<"$test_dir/retry-stderr")"

  [[ "$(grep -c '^aoe update --yes$' "$test_dir/command-log")" -eq 2 ]] \
    || fail "conditional recovery did not refresh AoE as a whole-unit retry"
  [[ "$(grep -c '^npm install --global ' "$test_dir/command-log")" -eq 16 ]] \
    || fail "conditional recovery skipped the whole npm refresh after versions became current"
  [[ "$(grep -c '^systemctl --user restart aoe-serve.service$' \
    "$test_dir/command-log")" -eq 2 ]] \
    || fail "conditional recovery did not retry activation"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 44 ]] \
    || fail "conditional recovery did not freshly discover and verify both attempts"
  jq -e '
    .last_successful_check == "2026-07-14T01:00:00Z"
    and .cached_version_result == ""
    and .check_status == "success"
    and .last_successful_activation == "2026-07-14T01:00:00Z"
    and .activation_failure == null
  ' "$state_file" >/dev/null \
    || fail "conditional recovery did not clear failure and record current state"
}

test_conditional_update_retries_after_pre_activation_failure_makes_versions_current() {
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  if AOE_CURRENT="1.2.2" \
    AOE_DOCTOR_FAIL_CALL=1 \
    run_tool "$test_dir" "$test_dir/failed-stdout" "$test_dir/failed-stderr" --update-if-needed; then
    fail "conditional pre-activation diagnostics failure exited zero"
  fi
  diff -u \
    <(printf 'update-agent-tools: pre-activation verification failed: AoE ACP diagnostics\n') \
    "$test_dir/failed-stderr" \
    || fail "conditional pre-activation failure changed its human error"
  if grep -q '^systemctl ' "$test_dir/command-log"; then
    fail "conditional pre-activation failure reached service activation"
  fi
  jq -e '
    .last_successful_activation == null
    and .activation_failure.phase == "maintenance"
    and .activation_failure.component == "agent-tool update"
    and .activation_failure.failed_at == "2026-07-14T00:00:00Z"
  ' "$state_file" >/dev/null \
    || fail "conditional pre-activation failure did not preserve incomplete maintenance state"

  UPDATE_AGENT_TOOLS_NOW="2026-07-14T01:00:00Z" \
    run_tool "$test_dir" "$test_dir/retry-stdout" "$test_dir/retry-stderr" --update-if-needed \
    || fail "conditional pre-activation recovery failed: $(<"$test_dir/retry-stderr")"

  [[ "$(grep -c '^aoe update --yes$' "$test_dir/command-log")" -eq 2 ]] \
    || fail "pre-activation recovery did not rerun the whole AoE update"
  [[ "$(grep -c '^npm install --global ' "$test_dir/command-log")" -eq 16 ]] \
    || fail "pre-activation recovery did not rerun the whole npm update"
  [[ "$(grep -c '^systemctl --user restart aoe-serve.service$' \
    "$test_dir/command-log")" -eq 1 ]] \
    || fail "pre-activation recovery did not activate exactly once after verification passed"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 44 ]] \
    || fail "pre-activation recovery did not freshly discover and verify both attempts"
  jq -e '
    .last_successful_check == "2026-07-14T01:00:00Z"
    and .cached_version_result == ""
    and .check_status == "success"
    and .last_successful_activation == "2026-07-14T01:00:00Z"
    and .activation_failure == null
  ' "$state_file" >/dev/null \
    || fail "pre-activation recovery did not clear incomplete maintenance state"
}

assert_complete_npm_refresh() {
  local command_log="$1"
  local actual
  local expected
  actual="$(mktemp)"
  expected="$(mktemp)"
  grep '^npm install --global ' "$command_log" >"$actual" || true
  cat >"$expected" <<'EOF'
npm install --global @openai/codex@latest
npm install --global @anthropic-ai/claude-code@latest
npm install --global @earendil-works/pi-coding-agent@latest
npm install --global opencode-ai@latest
npm install --global @oh-my-pi/pi-coding-agent@latest
npm install --global @agentclientprotocol/codex-acp@latest
npm install --global @agentclientprotocol/claude-agent-acp@latest
npm install --global pi-acp@latest
EOF
  diff -u "$expected" "$actual" \
    || fail "default update did not attempt all eight managed npm packages"
  rm -f "$actual" "$expected"
}

assert_harness_versions_checked() {
  local command_log="$1"
  local harness

  for harness in opencode omp pi; do
    grep -Fx "$harness --version" "$command_log" >/dev/null \
      || fail "complete update did not verify $harness --version"
  done
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
  [[ "$(<"$test_dir/stdout-1")" == $'AoE: 1.2.2 -> 1.2.3\nRun: update-agent-tools' ]] \
    || fail "initial due check did not report the current result"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 10 ]] \
    || fail "initial due check did not perform all release queries"

  UPDATE_AGENT_TOOLS_NOW="2026-07-15T09:59:59Z" \
    run_tool "$test_dir" "$test_dir/stdout-2" "$test_dir/stderr-2" --check-if-due \
    || fail "not-yet-due check exited nonzero: $(<"$test_dir/stderr-2")"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 10 ]] \
    || fail "not-yet-due check queried a registry or release"
  [[ "$(<"$test_dir/stdout-2")" == $'AoE: 1.2.2 -> 1.2.3\nRun: update-agent-tools' ]] \
    || fail "not-yet-due check did not reuse the cached result"

  UPDATE_AGENT_TOOLS_NOW="2026-07-15T10:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-3" "$test_dir/stderr-3" --check-if-due \
    || fail "due-again check exited nonzero: $(<"$test_dir/stderr-3")"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 20 ]] \
    || fail "due-again check did not perform fresh release queries"
}

test_internal_freshness_interface_reuses_cache_without_a_subordinate_action() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  AOE_CURRENT="1.2.2" \
    run_tool "$test_dir" "$test_dir/first-stdout" "$test_dir/first-stderr" --check-if-due \
    || fail "initial cached check failed: $(<"$test_dir/first-stderr")"

  AOE_CURRENT="1.2.2" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-14T01:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --freshness-check-if-due \
    || fail "internal freshness check failed: $(<"$test_dir/stderr")"

  diff -u <(printf '%s\n' 'AoE: 1.2.2 -> 1.2.3') "$test_dir/stdout" \
    || fail 'internal freshness interface exposed a subordinate action'
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "internal freshness interface wrote stderr: $(<"$test_dir/stderr")"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 10 ]] \
    || fail 'internal freshness interface bypassed the successful cache interval'
}

test_internal_freshness_interface_does_not_wait_for_maintenance() {
  local elapsed_milliseconds
  local finished_at
  local started_at
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'exec 8>&-; rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  mkdir -p "$test_dir/state/update-agent-tools"
  exec 8>"$test_dir/state/update-agent-tools/lock"
  flock 8

  started_at="$(date +%s%N)"
  if run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    --freshness-check-if-due; then
    fail 'internal freshness check waited through active maintenance'
  fi
  finished_at="$(date +%s%N)"
  elapsed_milliseconds=$(( (finished_at - started_at) / 1000000 ))

  (( elapsed_milliseconds < 1000 )) \
    || fail "internal freshness lock rejection was not prompt: ${elapsed_milliseconds}ms"
  grep -Fqx \
    'update-agent-tools: freshness check unavailable: agent-tool maintenance is already running' \
    "$test_dir/stderr" \
    || fail 'internal freshness lock rejection changed its bounded diagnostic'
  [[ ! -s "$test_dir/stdout" ]] \
    || fail 'internal freshness lock rejection wrote stdout'
}

test_internal_timeout_record_preserves_last_successful_result() {
  local state_file
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"
  mkdir -p "${state_file%/*}"
  printf '%s\n' \
    '{"last_attempt":"2026-07-14T00:00:00Z","last_successful_check":"2026-07-14T00:00:00Z","cached_version_result":"AoE: 1.2.2 -> 1.2.3","check_status":"success","last_successful_activation":"2026-07-01T00:00:00Z","activation_failure":null}' \
    >"$state_file"

  UPDATE_AGENT_TOOLS_NOW="2026-07-15T00:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
      --record-freshness-failure \
    || fail "internal timeout record failed: $(<"$test_dir/stderr")"

  jq -e '
    .last_attempt == "2026-07-15T00:00:00Z"
    and .last_successful_check == "2026-07-14T00:00:00Z"
    and .cached_version_result == "AoE: 1.2.2 -> 1.2.3"
    and .check_status == "failed"
    and .last_successful_activation == "2026-07-01T00:00:00Z"
    and .activation_failure == null
  ' "$state_file" >/dev/null \
    || fail 'internal timeout record did not retain the successful result and activation state'
  [[ ! -s "$test_dir/stdout" && ! -s "$test_dir/stderr" ]] \
    || fail 'internal timeout record produced presentation output'
  if grep -Eq '^(npm|aoe|systemctl) ' "$test_dir/command-log"; then
    fail 'internal timeout record reached discovery or mutation commands'
  fi
  [[ ! -e "$test_dir/query-log" ]] \
    || fail 'internal timeout record queried a registry'
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

test_state_writes_replace_the_state_file_atomically() {
  local first_inode
  local second_inode
  local state_dir
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_dir="$test_dir/state/update-agent-tools"
  state_file="$state_dir/state.json"

  AOE_CURRENT="1.2.2" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-06T02:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-1" "$test_dir/stderr-1" --check \
    || fail "first atomic-state check exited nonzero: $(<"$test_dir/stderr-1")"
  first_inode="$(stat -c %i "$state_file")"

  AOE_CURRENT="1.2.2" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-06T03:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-2" "$test_dir/stderr-2" --check \
    || fail "second atomic-state check exited nonzero: $(<"$test_dir/stderr-2")"
  second_inode="$(stat -c %i "$state_file")"

  [[ "$first_inode" != "$second_inode" ]] \
    || fail "successful state writes rewrote the state file in place"
  jq -e '
    .last_attempt == "2026-07-06T03:00:00Z"
    and .last_successful_check == "2026-07-06T03:00:00Z"
    and .cached_version_result == "AoE: 1.2.2 -> 1.2.3"
    and .check_status == "success"
  ' "$state_file" >/dev/null \
    || fail "replacement state file did not contain the final successful result"
  if compgen -G "$state_dir/state.json.tmp.*" >/dev/null; then
    fail "atomic replacement left a temporary state artifact"
  fi
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

  [[ "$(wc -l <"$test_dir/query-log")" -eq 10 ]] \
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
  wait "$update_pid" \
    || fail "update mode failed after the shared lock was released"
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
  [[ "$(<"$test_dir/stdout-1")" == $'AoE: 1.2.2 -> 1.2.3\nRun: update-agent-tools' ]] \
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
  [[ "$(wc -l <"$test_dir/query-log")" -eq 12 ]] \
    || fail "pre-retry check queried a registry or release"
  [[ ! -s "$test_dir/stdout-3" ]] \
    || fail "pre-retry check presented cached output as current"
  diff -u <(printf '%s\n' "$expected_failure") "$test_dir/stderr-3" \
    || fail "pre-retry failure output did not match"

  UPDATE_AGENT_TOOLS_NOW="2026-07-15T11:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-4" "$test_dir/stderr-4" --check-if-due \
    || fail "one-hour retry exited nonzero: $(<"$test_dir/stderr-4")"
  [[ "$(wc -l <"$test_dir/query-log")" -eq 22 ]] \
    || fail "one-hour retry did not perform fresh release queries"
}

test_malformed_aoe_release_is_a_failed_check() {
  local expected_failure
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  AOE_CURRENT="1.2.2" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-08T04:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-1" "$test_dir/stderr-1" --check-if-due \
    || fail "malformed-AoE cache seed exited nonzero: $(<"$test_dir/stderr-1")"

  expected_failure='update-agent-tools: agent-tool update check failed; last successful check: 2026-07-08T04:00:00Z; next retry: 2026-07-09T05:00:00Z'
  if AOE_LATEST="not-a-version" \
    UPDATE_AGENT_TOOLS_NOW="2026-07-09T04:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-2" "$test_dir/stderr-2" --check-if-due; then
    fail "malformed AoE release was committed as a successful check"
  fi
  [[ ! -s "$test_dir/stdout-2" ]] \
    || fail "malformed AoE release presented cached output as current"
  diff -u <(printf '%s\n' "$expected_failure") "$test_dir/stderr-2" \
    || fail "malformed AoE release failure output did not match"
  jq -e '
    .last_attempt == "2026-07-09T04:00:00Z"
    and .last_successful_check == "2026-07-08T04:00:00Z"
    and .cached_version_result == "AoE: 1.2.2 -> 1.2.3"
    and .check_status == "failed"
  ' "$state_file" >/dev/null \
    || fail "malformed AoE release replaced the last known-good state"

  UPDATE_AGENT_TOOLS_NOW="2026-07-09T04:59:59Z" \
    run_tool "$test_dir" "$test_dir/stdout-3" "$test_dir/stderr-3" --check-if-due \
    || fail "malformed-AoE pre-retry check exited nonzero"
  diff -u <(printf '%s\n' "$expected_failure") "$test_dir/stderr-3" \
    || fail "malformed-AoE pre-retry output did not match"
  [[ "$(jq -r '.last_attempt' "$state_file")" == "2026-07-09T04:00:00Z" ]] \
    || fail "malformed-AoE pre-retry check performed an early attempt"

  UPDATE_AGENT_TOOLS_NOW="2026-07-09T05:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-4" "$test_dir/stderr-4" --check-if-due \
    || fail "malformed-AoE one-hour retry exited nonzero: $(<"$test_dir/stderr-4")"
  jq -e '
    .last_attempt == "2026-07-09T05:00:00Z"
    and .last_successful_check == "2026-07-09T05:00:00Z"
    and .check_status == "success"
  ' "$state_file" >/dev/null \
    || fail "malformed AoE release did not retry at one hour"
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
    OPENCODE_CURRENT="8.8.9" \
    OMP_CURRENT="9.9.9" \
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
OpenCode CLI: 8.8.9 -> 8.9.0
Oh My Pi CLI: 9.9.9 -> 9.10.0
codex-acp adapter: 5.6.6 -> 5.6.7
claude-agent-acp adapter: 6.7.7 -> 6.7.8
pi-acp adapter: 7.8.8 -> 7.8.9
Codex runtime (codex-acp): 2.3.2 -> 2.3.4
Run: update-agent-tools
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
  rm "$test_dir/.local/bin/aoe"

  if ! NPM_FIXTURE="missing" \
    run_check "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "missing toolchain check exited nonzero: $(<"$test_dir/stderr")"
  fi

  expected="$(cat <<'EOF'
AoE: missing -> 1.2.3
claude-agent-acp adapter: missing -> 6.7.8
Run: update-agent-tools
EOF
)"
  diff -u <(printf '%s\n' "$expected") "$test_dir/stdout" \
    || fail "missing toolchain output did not match"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "missing toolchain check wrote stderr: $(<"$test_dir/stderr")"
}

test_default_update_refreshes_and_activates_the_complete_toolchain() {
  local health_line
  local state_file
  local test_dir
  local timestamp_line
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  UPDATE_AGENT_TOOLS_ACTIVATION_NOW="2026-07-14T00:03:00Z" \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "complete update exited nonzero: $(<"$test_dir/stderr")"

  grep -Fx 'aoe update --yes' "$test_dir/command-log" >/dev/null \
    || fail "complete update did not use AoE self-update"
  assert_complete_npm_refresh "$test_dir/command-log"
  assert_harness_versions_checked "$test_dir/command-log"
  [[ "$(grep -c '^aoe acp doctor$' "$test_dir/command-log")" -eq 2 ]] \
    || fail "complete update did not run pre- and post-activation ACP diagnostics"
  grep -Fx 'systemctl --user restart aoe-serve.service' "$test_dir/command-log" >/dev/null \
    || fail "complete update did not restart the AoE service"
  grep -Fx 'systemctl --user is-active --quiet aoe-serve.service' "$test_dir/command-log" >/dev/null \
    || fail "complete update did not verify the AoE service"
  health_line="$(grep -n '^aoe acp doctor$' "$test_dir/command-log" | tail -n 1 | cut -d: -f1)"
  timestamp_line="$(grep -n '^date -u -d 2026-07-14T00:03:00Z +%Y-%m-%dT%H:%M:%SZ$' \
    "$test_dir/command-log" | cut -d: -f1)"
  [[ -n "$timestamp_line" && "$timestamp_line" -gt "$health_line" ]] \
    || fail "successful activation timestamp was not acquired after health passed"
  jq -e '
    .last_successful_activation == "2026-07-14T00:03:00Z"
    and .activation_failure == null
  ' "$state_file" >/dev/null \
    || fail "complete update did not record successful activation"
}

test_interactive_update_without_running_workers_does_not_prompt() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  TEST_RUN_IN_TTY=1 \
    ACP_PS_SEQUENCE_JSON='[[]]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "zero-worker interactive update failed: $(<"$test_dir/stderr")"

  if grep -F 'running ACP' "$test_dir/stdout" >/dev/null; then
    fail "zero-worker interactive update prompted for disruption authorization"
  fi
}

test_noninteractive_update_with_running_workers_requires_yes() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if ACP_PS_SEQUENCE_JSON='[[{"session_id":"private-session","pid":101,"alive":true,"build_stale":false}]]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "noninteractive update with a running worker exited zero"
  fi

  diff -u \
    <(printf 'update-agent-tools: 1 running ACP session would be disrupted; rerun with --yes to authorize replacement\n') \
    "$test_dir/stderr" \
    || fail "noninteractive refusal was not actionable or leaked worker metadata"
  if grep -Eq '^(aoe update|npm install|systemctl |aoe acp restart)' \
    "$test_dir/command-log"; then
    fail "noninteractive refusal mutated the installation or restarted a service or worker"
  fi
}

test_yes_authorizes_noninteractive_update_with_running_workers() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  ACP_PS_SEQUENCE_JSON='[
    [{"session_id":"private-session","pid":101,"alive":true,"build_stale":false}],
    [{"session_id":"private-session","pid":201,"alive":true,"build_stale":false}]
  ]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --yes \
    || fail "--yes update with a running worker failed: $(<"$test_dir/stderr")"

  grep -Fx 'aoe update --yes' "$test_dir/command-log" >/dev/null \
    || fail "--yes did not authorize update mutation"
  if grep -F 'running ACP' "$test_dir/stdout" "$test_dir/stderr" >/dev/null; then
    fail "--yes requested interactive disruption authorization"
  fi
}

test_interactive_decline_happens_once_before_mutation() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if TEST_RUN_IN_TTY=1 \
    TEST_TTY_INPUT=$'n\n' \
    ACP_PS_SEQUENCE_JSON='[[
      {"session_id":"private-session-a","pid":101,"alive":true,"build_stale":false,"title":"secret title"},
      {"session_id":"private-session-b","pid":102,"alive":true,"build_stale":false,"agent":"secret agent"}
    ]]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "declined interactive update exited zero"
  fi

  [[ "$(grep -c '2 running ACP sessions would be disrupted' "$test_dir/stdout")" -eq 1 ]] \
    || fail "interactive update did not prompt once with only the affected count"
  if grep -Eq 'private-session|secret title|secret agent' "$test_dir/stdout"; then
    fail "interactive confirmation exposed ACP session metadata"
  fi
  if grep -Eq '^(aoe update|npm install|systemctl |aoe acp restart)' \
    "$test_dir/command-log"; then
    fail "declined interactive update mutated the installation or restarted a service or worker"
  fi
}

test_workers_are_reconciled_by_identity_after_pre_activation_verification() {
  local capture_line
  local install_line
  local pre_activation_line
  local service_restart_line
  local test_dir
  local timestamp_line
  local worker_health_line
  local worker_restart_line
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  TEST_RUN_IN_TTY=1 \
    TEST_TTY_INPUT=$'y\n' \
    UPDATE_AGENT_TOOLS_ACTIVATION_NOW="2026-07-14T00:04:00Z" \
    ACP_PS_SEQUENCE_JSON='[
    [
      {"session_id":"session-a","pid":101,"alive":true,"build_stale":false},
      {"session_id":"session-b","pid":102,"alive":true,"build_stale":false},
      {"session_id":"session-b","pid":102,"alive":true,"build_stale":false}
    ],
    [
      {"session_id":"session-a","pid":201,"alive":true,"build_stale":false},
      {"session_id":"session-b","pid":102,"alive":true,"build_stale":true}
    ],
    [
      {"session_id":"session-a","pid":201,"alive":true,"build_stale":false},
      {"session_id":"session-b","pid":102,"alive":true,"build_stale":true}
    ],
    [
      {"session_id":"session-a","pid":201,"alive":true,"build_stale":false},
      {"session_id":"session-b","pid":202,"alive":true,"build_stale":false}
    ]
  ]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "worker reconciliation failed: $(<"$test_dir/stderr")"

  [[ "$(grep -c '2 running ACP sessions would be disrupted' "$test_dir/stdout")" -eq 1 ]] \
    || fail "interactive worker update did not request disruption authorization exactly once"
  if grep -Eq 'session-a|session-b' "$test_dir/stdout"; then
    fail "interactive worker update exposed captured identities"
  fi
  capture_line="$(grep -n '^aoe ps --acp --dead --json$' "$test_dir/command-log" \
    | head -n 1 | cut -d: -f1)"
  install_line="$(grep -n '^aoe update --yes$' "$test_dir/command-log" \
    | cut -d: -f1)"
  [[ "$capture_line" -lt "$install_line" ]] \
    || fail "running worker identities were not captured before update mutation"
  [[ "$(grep -c '^aoe acp restart session-b$' "$test_dir/command-log")" -eq 1 ]] \
    || fail "unchanged duplicate worker identity was not restarted exactly once"
  if grep -Fx 'aoe acp restart session-a' "$test_dir/command-log" >/dev/null; then
    fail "worker already replaced by AoE was restarted a second time"
  fi
  pre_activation_line="$(grep -n '^aoe acp doctor$' "$test_dir/command-log" \
    | head -n 1 | cut -d: -f1)"
  service_restart_line="$(grep -n '^systemctl --user restart aoe-serve.service$' \
    "$test_dir/command-log" | cut -d: -f1)"
  worker_restart_line="$(grep -n '^aoe acp restart session-b$' \
    "$test_dir/command-log" | cut -d: -f1)"
  [[ "$pre_activation_line" -lt "$service_restart_line" \
    && "$service_restart_line" -lt "$worker_restart_line" ]] \
    || fail "daemon or worker restart happened before pre-activation verification completed"
  worker_health_line="$(grep -n '^aoe ps --acp --dead --json$' "$test_dir/command-log" \
    | tail -n 1 | cut -d: -f1)"
  timestamp_line="$(grep -n '^date -u -d 2026-07-14T00:04:00Z +%Y-%m-%dT%H:%M:%SZ$' \
    "$test_dir/command-log" | cut -d: -f1)"
  [[ "$timestamp_line" -gt "$worker_health_line" ]] \
    || fail "successful activation was recorded before captured workers were healthy"
}

test_temporarily_unregistered_worker_is_reconciled_without_restart() {
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  ACP_RESTART_FAIL=1 \
    ACP_PS_SEQUENCE_JSON='[
      [{"session_id":"private-session","pid":101,"alive":true,"build_stale":false}],
      [],
      [{"session_id":"private-session","pid":201,"alive":true,"build_stale":false}]
    ]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --yes \
    || fail "temporarily unregistered worker was not reconciled: $(<"$test_dir/stderr")"

  if grep -Fx 'aoe acp restart private-session' \
    "$test_dir/command-log" >/dev/null; then
    fail "temporarily unregistered worker was restarted before it could re-register"
  fi
  [[ "$(grep -c '^aoe ps --acp --dead --json$' "$test_dir/command-log")" -eq 3 ]] \
    || fail "temporarily unregistered worker was not reconciled on a later snapshot"
  jq -e '
    .last_successful_activation != null
    and .activation_failure == null
  ' "$state_file" >/dev/null \
    || fail "re-registered healthy worker was not recorded as successful activation"
}

test_coexisting_old_and_replacement_identities_fail_health_without_restarting_again() {
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  if ACP_PS_SEQUENCE_JSON='[
    [{"session_id":"private-session","pid":101,"alive":true,"build_stale":false}],
    [
      {"session_id":"private-session","pid":101,"alive":true,"build_stale":true},
      {"session_id":"private-session","pid":201,"alive":true,"build_stale":false}
    ]
  ]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --yes; then
    fail "activation succeeded while a captured worker identity remained alive"
  fi

  if grep -Fx 'aoe acp restart private-session' \
    "$test_dir/command-log" >/dev/null; then
    fail "coexisting healthy replacement identity was restarted again"
  fi
  [[ "$(grep -c '^aoe ps --acp --dead --json$' "$test_dir/command-log")" -eq 12 ]] \
    || fail "captured identity exit was not awaited for the bounded health window"
  diff -u \
    <(printf 'update-agent-tools: post-activation verification failed: ACP session replacement\n') \
    "$test_dir/stderr" \
    || fail "coexisting captured identity failure lost its phase or component"
  jq -e '
    .last_successful_activation == null
    and .activation_failure.phase == "post-activation verification"
    and .activation_failure.component == "ACP session replacement"
  ' "$state_file" >/dev/null \
    || fail "coexisting captured identity was recorded as successful activation"
}

test_each_worker_restart_decision_uses_a_fresh_identity_snapshot() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  ACP_PS_SEQUENCE_JSON='[
    [
      {"session_id":"session-a","pid":101,"alive":true,"build_stale":false},
      {"session_id":"session-b","pid":102,"alive":true,"build_stale":false}
    ],
    [
      {"session_id":"session-a","pid":101,"alive":true,"build_stale":true},
      {"session_id":"session-b","pid":102,"alive":true,"build_stale":true}
    ],
    [
      {"session_id":"session-a","pid":201,"alive":true,"build_stale":false},
      {"session_id":"session-b","pid":202,"alive":true,"build_stale":false}
    ]
  ]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --yes \
    || fail "per-worker identity reconciliation failed: $(<"$test_dir/stderr")"

  [[ "$(grep -c '^aoe acp restart session-a$' "$test_dir/command-log")" -eq 1 ]] \
    || fail "first unchanged worker was not restarted exactly once"
  if grep -Fx 'aoe acp restart session-b' "$test_dir/command-log" >/dev/null; then
    fail "later worker auto-replaced during reconciliation was manually restarted"
  fi
  [[ "$(grep -c '^aoe ps --acp --dead --json$' "$test_dir/command-log")" -eq 4 ]] \
    || fail "restart decisions did not use immediate per-worker identity snapshots"
}

test_worker_replacement_health_failure_is_bounded_and_not_successful() {
  local state_dir
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_dir="$test_dir/state/update-agent-tools"
  state_file="$state_dir/state.json"
  mkdir -p "$state_dir"
  printf '%s\n' '{"last_successful_activation":"2026-07-01T00:00:00Z","activation_failure":null}' \
    >"$state_file"

  if ACP_PS_SEQUENCE_JSON='[[
      {"session_id":"private-session","pid":101,"alive":true,"build_stale":false}
    ]]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --yes; then
    fail "unhealthy unreplaced worker exited zero"
  fi

  diff -u \
    <(printf 'update-agent-tools: post-activation verification failed: ACP session replacement\n') \
    "$test_dir/stderr" \
    || fail "worker health failure did not identify the post-activation phase"
  [[ "$(grep -c '^aoe ps --acp --dead --json$' "$test_dir/command-log")" -eq 12 ]] \
    || fail "worker replacement health wait was not bounded"
  [[ "$(grep -c '^aoe acp restart private-session$' "$test_dir/command-log")" -eq 1 ]] \
    || fail "unhealthy worker was restarted more than once"
  jq -e '
    .last_successful_activation == "2026-07-01T00:00:00Z"
    and .activation_failure.phase == "post-activation verification"
    and .activation_failure.component == "ACP session replacement"
  ' "$state_file" >/dev/null \
    || fail "worker health failure wrote a success timestamp or lost recovery state"
}

test_final_service_health_failure_after_worker_replacement_is_bounded() {
  local state_dir
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_dir="$test_dir/state/update-agent-tools"
  state_file="$state_dir/state.json"
  mkdir -p "$state_dir"
  printf '%s\n' '{"last_successful_activation":"2026-07-01T00:00:00Z","activation_failure":null}' \
    >"$state_file"

  if AOE_DOCTOR_FAIL_AFTER=2 \
    UPDATE_AGENT_TOOLS_ACTIVATION_NOW="2026-07-14T00:05:00Z" \
    ACP_PS_SEQUENCE_JSON='[
      [{"session_id":"private-session","pid":101,"alive":true,"build_stale":false}],
      [{"session_id":"private-session","pid":101,"alive":true,"build_stale":true}],
      [{"session_id":"private-session","pid":201,"alive":true,"build_stale":false}]
    ]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --yes; then
    fail "final ACP diagnostics failure after worker replacement exited zero"
  fi

  diff -u \
    <(printf 'update-agent-tools: post-activation verification failed: AoE ACP diagnostics\n') \
    "$test_dir/stderr" \
    || fail "final diagnostics failure lost phase/component reporting"
  [[ "$(grep -c '^systemctl --user is-active --quiet aoe-serve.service$' \
    "$test_dir/command-log")" -eq 11 ]] \
    || fail "final daemon health verification was not bounded"
  [[ "$(grep -c '^aoe acp doctor$' "$test_dir/command-log")" -eq 11 ]] \
    || fail "final ACP diagnostics verification was not bounded"
  [[ "$(grep -c '^aoe acp restart private-session$' \
    "$test_dir/command-log")" -eq 1 ]] \
    || fail "post-preactivation diagnostics failure prevented required worker restart"
  if grep -Fx 'date -u -d 2026-07-14T00:05:00Z +%Y-%m-%dT%H:%M:%SZ' \
    "$test_dir/command-log" >/dev/null; then
    fail "failed final health verification acquired a success timestamp"
  fi
  jq -e '
    .last_successful_activation == "2026-07-01T00:00:00Z"
    and .activation_failure.phase == "post-activation verification"
    and .activation_failure.component == "AoE ACP diagnostics"
  ' "$state_file" >/dev/null \
    || fail "failed final health verification wrote success or lost recovery state"
}

test_partial_install_does_not_restart_the_service() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if NPM_INSTALL_FAIL_PACKAGE='@agentclientprotocol/claude-agent-acp@latest' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "partial installation exited zero"
  fi

  grep -Fx 'aoe update --yes' "$test_dir/command-log" >/dev/null \
    || fail "partial installation did not exercise the AoE-success/npm-failure boundary"
  diff -u \
    <(printf 'update-agent-tools: installation failed: claude-agent-acp adapter (@agentclientprotocol/claude-agent-acp@latest)\n') \
    "$test_dir/stderr" \
    || fail "partial installation did not identify its phase and component"
  [[ "$(grep -c '^npm install --global ' "$test_dir/command-log")" -eq 7 ]] \
    || fail "partial installation did not stop at the named failing component"
  if grep -q '^systemctl ' "$test_dir/command-log"; then
    fail "partial installation restarted or inspected the service"
  fi
}

test_default_update_removes_stale_cli_shims_before_npm_refresh() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  printf 'stale-shim\n' >"$test_dir/.local/bin/codex"
  printf 'stale-shim\n' >"$test_dir/stale-claude-target"
  ln -sf "$test_dir/stale-claude-target" "$test_dir/.local/bin/claude"
  printf 'stale-shim\n' >"$test_dir/.local/bin/pi"

  NPM_REQUIRE_CLEARED_SHIMS=1 \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "stale CLI shim replacement failed: $(<"$test_dir/stderr")"

  assert_complete_npm_refresh "$test_dir/command-log"
  for binary in codex claude pi; do
    [[ "$(head -n 1 "$test_dir/.local/bin/$binary")" == "#!$REAL_BASH" ]] \
      || fail "stale $binary shim survived the npm refresh"
  done
}

test_pre_activation_diagnostics_failure_does_not_restart_the_service() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if AOE_DOCTOR_FAIL_CALL=1 \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "pre-activation diagnostics failure exited zero"
  fi

  diff -u \
    <(printf 'update-agent-tools: pre-activation verification failed: AoE ACP diagnostics\n') \
    "$test_dir/stderr" \
    || fail "pre-activation failure did not identify its phase and component"
  if grep -q '^systemctl ' "$test_dir/command-log"; then
    fail "pre-activation diagnostics failure reached service activation"
  fi
}

test_pre_activation_command_resolution_failure_does_not_restart_the_service() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if NPM_OMIT_BINARY=codex-acp \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "pre-activation command-resolution failure exited zero"
  fi

  diff -u \
    <(printf 'update-agent-tools: pre-activation verification failed: codex-acp command must resolve to %s/.local/bin/codex-acp, got missing\n' "$test_dir") \
    "$test_dir/stderr" \
    || fail "command-resolution failure did not identify its phase and component"
  if grep -q '^systemctl ' "$test_dir/command-log"; then
    fail "command-resolution failure reached service activation"
  fi
}

test_pre_activation_version_failure_does_not_restart_the_service() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if CODEX_POST_INSTALL=2.3.3 \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "pre-activation version failure exited zero"
  fi

  diff -u \
    <(printf 'update-agent-tools: pre-activation verification failed: Codex CLI (standalone) version\n') \
    "$test_dir/stderr" \
    || fail "version failure did not identify its phase and component"
  if grep -q '^systemctl ' "$test_dir/command-log"; then
    fail "version failure reached service activation"
  fi
}

test_pre_activation_empty_package_inventory_names_its_component() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if NPM_LIST_EMPTY=1 \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "empty pre-activation npm inventory exited zero"
  fi

  diff -u \
    <(printf 'update-agent-tools: pre-activation verification failed: npm package inventory\n') \
    "$test_dir/stderr" \
    || fail "empty npm inventory did not report its phase and component exactly"
  if grep -q '^systemctl ' "$test_dir/command-log"; then
    fail "empty npm inventory reached service activation"
  fi
}

test_pre_activation_registry_failure_names_the_managed_component() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if NPM_FAIL_PACKAGE='@agentclientprotocol/claude-agent-acp@latest' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "component registry failure exited zero"
  fi

  diff -u \
    <(printf 'update-agent-tools: pre-activation verification failed: claude-agent-acp adapter\n') \
    "$test_dir/stderr" \
    || fail "component registry failure leaked output or lost its exact component"
  if grep -q '^systemctl ' "$test_dir/command-log"; then
    fail "component registry failure reached service activation"
  fi
}

test_post_activation_failure_retains_failure_without_rollback() {
  local state_dir
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_dir="$test_dir/state/update-agent-tools"
  state_file="$state_dir/state.json"
  mkdir -p "$state_dir"
  printf '%s\n' '{"last_successful_activation":"2026-07-01T00:00:00Z","activation_failure":null}' \
    >"$state_file"

  if AOE_DOCTOR_FAIL_AFTER=2 \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr"; then
    fail "post-activation diagnostics failure exited zero"
  fi

  diff -u \
    <(printf 'update-agent-tools: post-activation verification failed: AoE ACP diagnostics\n') \
    "$test_dir/stderr" \
    || fail "post-activation failure did not identify its phase and component"
  [[ "$(grep -c '^systemctl --user is-active --quiet aoe-serve.service$' "$test_dir/command-log")" -eq 10 ]] \
    || fail "post-activation health verification was not bounded"
  jq -e '
    .last_successful_activation == "2026-07-01T00:00:00Z"
    and .activation_failure.phase == "post-activation verification"
    and .activation_failure.component == "AoE ACP diagnostics"
    and .activation_failure.failed_at == "2026-07-14T00:00:00Z"
    and (has("version_snapshot") | not)
    and (has("rollback") | not)
  ' "$state_file" >/dev/null \
    || fail "post-activation failure changed the success timestamp or lost recovery state"
  if grep -Eiq 'rollback|version.snapshot|npm install .*@[0-9]' "$test_dir/command-log"; then
    fail "post-activation failure attempted rollback or retained a version snapshot"
  fi
}

test_activation_failure_is_recovered_by_a_full_rerun() {
  local state_file
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  state_file="$test_dir/state/update-agent-tools/state.json"

  if SYSTEMCTL_RESTART_FAIL=1 \
    UPDATE_AGENT_TOOLS_NOW="2026-07-14T01:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-1" "$test_dir/stderr-1"; then
    fail "service restart failure exited zero"
  fi
  jq -e '
    .last_successful_activation == null
    and .activation_failure.phase == "activation"
    and .activation_failure.component == "AoE service restart"
  ' "$state_file" >/dev/null \
    || fail "service restart failure was not retained"

  UPDATE_AGENT_TOOLS_NOW="2026-07-14T02:00:00Z" \
    run_tool "$test_dir" "$test_dir/stdout-2" "$test_dir/stderr-2" \
    || fail "activation recovery rerun exited nonzero: $(<"$test_dir/stderr-2")"
  [[ "$(grep -c '^aoe update --yes$' "$test_dir/command-log")" -eq 2 ]] \
    || fail "activation recovery did not refresh the whole unit on rerun"
  [[ "$(grep -c '^npm install --global ' "$test_dir/command-log")" -eq 16 ]] \
    || fail "activation recovery skipped npm refresh because packages were current"
  [[ "$(grep -c '^systemctl --user restart aoe-serve.service$' "$test_dir/command-log")" -eq 2 ]] \
    || fail "activation recovery did not retry service activation"
  jq -e '
    .last_successful_activation == "2026-07-14T02:00:00Z"
    and .activation_failure == null
  ' "$state_file" >/dev/null \
    || fail "successful recovery did not clear activation failure and write its timestamp"
}

test_standalone_and_bundled_codex_remain_separate_on_update() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  CODEX_CURRENT="2.4.0" \
    CODEX_LATEST="2.4.0" \
    BUNDLED_CODEX_CURRENT="2.3.3" \
    BUNDLED_CODEX_RANGE="^2.3.0" \
    BUNDLED_CODEX_VERSIONS_JSON='["2.3.3","2.3.4"]' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "separate Codex update exited nonzero: $(<"$test_dir/stderr")"

  assert_complete_npm_refresh "$test_dir/command-log"
  grep -Fx 'npm install --global @openai/codex@latest' "$test_dir/command-log" >/dev/null \
    || fail "standalone Codex was not installed independently"
  grep -Fx 'npm install --global @agentclientprotocol/codex-acp@latest' "$test_dir/command-log" >/dev/null \
    || fail "codex-acp was not installed independently"
  grep -Fx 'npm view @openai/codex@latest version' "$test_dir/command-log" >/dev/null \
    || fail "standalone Codex version was not verified independently"
  grep -Fx 'npm view @openai/codex@^2.3.0 version --json' "$test_dir/command-log" >/dev/null \
    || fail "codex-acp bundled runtime was not verified against its adapter-compatible range"
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
    <(printf 'Codex runtime (codex-acp): 2.3.3 -> 2.3.4\nRun: update-agent-tools\n') \
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
    <(printf 'Codex runtime (codex-acp): 2.3.3 -> 2.3.4\nRun: update-agent-tools\n') \
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
    <(printf 'Codex runtime (codex-acp): 2.3.3 -> 2.3.4\nRun: update-agent-tools\n') \
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
    <(printf 'Codex runtime (codex-acp): 2.3.3 -> 2.3.4\nRun: update-agent-tools\n') \
    "$test_dir/stdout" \
    || fail "stable nested Codex output did not match"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "stable nested Codex check wrote stderr: $(<"$test_dir/stderr")"
}

test_outdated_bun_runtime_is_installed_before_the_harnesses() {
  local bun_line
  local npm_line
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  BUN_CURRENT="1.3.13" BUN_LATEST="1.4.0" \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --update-if-needed \
    || fail "outdated Bun update failed: $(<"$test_dir/stderr")"

  grep -Fx 'bun install https://example.invalid/baseline.zip' \
    "$test_dir/command-log" >/dev/null \
    || fail "outdated Bun was not installed"
  bun_line="$(grep -n '^bun install ' "$test_dir/command-log" \
    | head -n 1 | cut -d: -f1)"
  npm_line="$(grep -n '^npm install --global ' "$test_dir/command-log" \
    | head -n 1 | cut -d: -f1)"
  [[ "$bun_line" -lt "$npm_line" ]] \
    || fail "Bun was installed after the harnesses that run under it"
  [[ "$(HOME="$test_dir" BUN_CURRENT="1.3.13" BUN_LATEST="1.4.0" \
    "$test_dir/.local/bin/bun" --version)" == "1.4.0" ]] \
    || fail "installed Bun did not replace the outdated one"
  [[ "$(readlink "$test_dir/.local/bin/bunx")" == "bun" ]] \
    || fail "installed Bun did not provide bunx"
}

test_missing_bun_runtime_is_reported_and_installed() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"
  rm -f "$test_dir/.local/bin/bun" "$test_dir/.local/bin/bunx"

  run_check "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "check with a missing Bun failed: $(<"$test_dir/stderr")"
  diff -u \
    <(printf 'Bun runtime: missing -> 1.4.0\nRun: update-agent-tools\n') \
    "$test_dir/stdout" \
    || fail "missing Bun was not reported as a component"

  run_tool "$test_dir" "$test_dir/update-stdout" "$test_dir/update-stderr" \
    --update-if-needed \
    || fail "update with a missing Bun failed: $(<"$test_dir/update-stderr")"
  [[ -x "$test_dir/.local/bin/bun" ]] \
    || fail "update did not install the missing Bun"
}

test_bun_archive_digest_mismatch_stops_before_the_harnesses_change() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if BUN_DIGEST_OVERRIDE="sha256:$(printf '0%.0s' {1..64})" \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --yes; then
    fail "a mismatched Bun archive digest was accepted"
  fi

  diff -u \
    <(printf 'update-agent-tools: installation failed: Bun runtime (archive digest mismatch)\n') \
    "$test_dir/stderr" \
    || fail "digest mismatch was not reported as an installation failure"
  if grep -Eq '^(npm install|systemctl )' "$test_dir/command-log"; then
    fail "digest mismatch still refreshed the harnesses"
  fi
  [[ ! -e "$test_dir/.local/bin/.bun.new" ]] \
    || fail "digest mismatch left a staged Bun behind"
}

test_bun_archive_matches_the_host_instruction_set() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --yes \
    || fail "pre-AVX2 update failed: $(<"$test_dir/stderr")"
  grep -Fx 'curl bun archive https://example.invalid/baseline.zip' \
    "$test_dir/query-log" >/dev/null \
    || fail "a pre-AVX2 host did not receive the baseline Bun archive"

  : >"$test_dir/query-log"
  UPDATE_AGENT_TOOLS_CPUINFO="$test_dir/cpuinfo-avx2" \
    run_tool "$test_dir" "$test_dir/avx2-stdout" "$test_dir/avx2-stderr" --yes \
    || fail "AVX2 update failed: $(<"$test_dir/avx2-stderr")"
  grep -Fx 'curl bun archive https://example.invalid/avx2.zip' \
    "$test_dir/query-log" >/dev/null \
    || fail "an AVX2 host did not receive the standard Bun archive"
}

test_harness_node_floor_above_the_profile_stops_before_mutation() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if PI_ENGINES='{"node":">=99.0.0"}' NODE_VERSION="24.14.1" \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --update-if-needed; then
    fail "an unsatisfiable Node floor was accepted"
  fi

  grep -Fq "discovery phase failed: Node runtime (Pi agent CLI needs node >=99.0.0, found 24.14.1; update the nixpkgs flake input to raise the profile's Node)" \
    "$test_dir/stderr" \
    || fail "unsatisfiable Node floor was not explained: $(<"$test_dir/stderr")"
  if grep -Eq '^(bun install|npm install|aoe update|systemctl )' \
    "$test_dir/command-log"; then
    fail "unsatisfiable Node floor still mutated the toolchain"
  fi
}

test_harness_bun_floor_above_the_latest_release_stops_before_mutation() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  if OMP_ENGINES='{"bun":">=99.0.0"}' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --update-if-needed; then
    fail "a Bun floor no release satisfies was accepted"
  fi

  grep -Fq 'discovery phase failed: Bun runtime (Oh My Pi CLI needs bun >=99.0.0, found 1.4.0; no Bun release satisfies it yet)' \
    "$test_dir/stderr" \
    || fail "unsatisfiable Bun floor was not explained: $(<"$test_dir/stderr")"
  if grep -Eq '^(bun install|npm install|aoe update|systemctl )' \
    "$test_dir/command-log"; then
    fail "unsatisfiable Bun floor still mutated the toolchain"
  fi
}

# A floor the updater cannot parse must not become a refusal: an unreadable range
# is the registry's novelty, not evidence that the runtime is too old.
test_unparsable_engine_range_does_not_block_the_update() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir/stubs"

  OMP_ENGINES='{"bun":"^99.0.0"}' \
    run_tool "$test_dir" "$test_dir/stdout" "$test_dir/stderr" --yes \
    || fail "an unparsable engine range blocked the update: $(<"$test_dir/stderr")"
  assert_complete_npm_refresh "$test_dir/command-log"
}

# shellcheck source=tests/lib/suite-dispatch.bash
source "$REPO_ROOT/tests/lib/suite-dispatch.bash"

readonly test_cases=(
  test_machine_status_reports_current_by_exit_status_without_output
  test_machine_status_reports_outdated_by_exit_status_without_output
  test_machine_status_reports_discovery_failure_and_preserves_freshness_state
  test_machine_status_reports_unresolved_activation_failure_as_maintenance_needed
  test_conditional_update_leaves_current_toolchain_and_acp_workers_alone
  test_conditional_update_stops_before_mutation_when_discovery_fails
  test_conditional_update_refreshes_the_whole_toolchain_when_outdated
  test_conditional_update_requires_yes_for_unattended_acp_disruption
  test_conditional_update_yes_authorizes_only_acp_disruption
  test_conditional_interactive_update_prompts_once_for_acp_disruption
  test_conditional_update_retries_a_current_toolchain_after_activation_failure
  test_conditional_update_retries_after_pre_activation_failure_makes_versions_current
  test_due_check_runs_once_per_success_interval
  test_internal_freshness_interface_reuses_cache_without_a_subordinate_action
  test_internal_freshness_interface_does_not_wait_for_maintenance
  test_internal_timeout_record_preserves_last_successful_result
  test_state_uses_local_state_fallback
  test_state_writes_replace_the_state_file_atomically
  test_concurrent_due_checks_are_serialized
  test_update_and_check_modes_share_the_state_lock
  test_failed_check_preserves_cache_and_retries_after_one_hour
  test_malformed_aoe_release_is_a_failed_check
  test_empty_npm_version_is_a_failed_check
  test_npm_registry_failure_preserves_cache_and_retries_after_one_hour
  test_current_toolchain_is_silent
  test_outdated_components_report_exact_versions
  test_missing_components_are_reported
  test_nested_codex_runtime_is_a_distinct_scope
  test_nested_codex_uses_latest_adapter_compatible_target
  test_nested_codex_accepts_a_single_compatible_version
  test_nested_codex_ignores_compatible_prereleases
  test_default_update_refreshes_and_activates_the_complete_toolchain
  test_interactive_update_without_running_workers_does_not_prompt
  test_noninteractive_update_with_running_workers_requires_yes
  test_yes_authorizes_noninteractive_update_with_running_workers
  test_interactive_decline_happens_once_before_mutation
  test_workers_are_reconciled_by_identity_after_pre_activation_verification
  test_temporarily_unregistered_worker_is_reconciled_without_restart
  test_coexisting_old_and_replacement_identities_fail_health_without_restarting_again
  test_each_worker_restart_decision_uses_a_fresh_identity_snapshot
  test_worker_replacement_health_failure_is_bounded_and_not_successful
  test_final_service_health_failure_after_worker_replacement_is_bounded
  test_partial_install_does_not_restart_the_service
  test_default_update_removes_stale_cli_shims_before_npm_refresh
  test_pre_activation_diagnostics_failure_does_not_restart_the_service
  test_pre_activation_command_resolution_failure_does_not_restart_the_service
  test_pre_activation_version_failure_does_not_restart_the_service
  test_pre_activation_empty_package_inventory_names_its_component
  test_pre_activation_registry_failure_names_the_managed_component
  test_post_activation_failure_retains_failure_without_rollback
  test_activation_failure_is_recovered_by_a_full_rerun
  test_standalone_and_bundled_codex_remain_separate_on_update
  test_outdated_bun_runtime_is_installed_before_the_harnesses
  test_missing_bun_runtime_is_reported_and_installed
  test_bun_archive_digest_mismatch_stops_before_the_harnesses_change
  test_bun_archive_matches_the_host_instruction_set
  test_harness_node_floor_above_the_profile_stops_before_mutation
  test_harness_bun_floor_above_the_latest_release_stops_before_mutation
  test_unparsable_engine_range_does_not_block_the_update
)

suite_dispatch 'update-agent-tools --check' "$@"
