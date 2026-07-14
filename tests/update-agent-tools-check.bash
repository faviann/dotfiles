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
  printf '{"tag_name":"v%s"}\n' "$AOE_LATEST"
  exit 0
fi

printf 'unexpected curl invocation: %s\n' "$*" >&2
exit 64
STUB

  cat >"$stub_dir/npm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

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

if [[ "$1" == "view" && "$3" == "version" ]]; then
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

run_check() {
  local home="$1"
  local stdout_file="$2"
  local stderr_file="$3"

  HOME="$home" \
    XDG_STATE_HOME="$home/state" \
    PATH="$home/stubs:/usr/bin:/bin" \
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
    bash "$COMMAND" --check >"$stdout_file" 2>"$stderr_file"
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

test_current_toolchain_is_silent
test_outdated_components_report_exact_versions
test_missing_components_are_reported
test_nested_codex_runtime_is_a_distinct_scope
printf 'PASS: update-agent-tools --check\n'
