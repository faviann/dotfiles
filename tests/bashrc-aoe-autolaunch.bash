#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly BASHRC_PATH="$REPO_ROOT/dot_bashrc.tmpl"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_stubs() {
  local home="$1"
  local bin_dir="$home/.local/bin"

  mkdir -p "$bin_dir" "$home/.local/state/workstation-setup"
  : >"$home/.local/state/workstation-setup/complete"

  cat >"$bin_dir/aoe" <<'STUB'
#!/usr/bin/bash
exit 0
STUB

  cat >"$bin_dir/update-agent-tools" <<'STUB'
#!/usr/bin/bash
set -euo pipefail

printf 'update-agent-tools %s\n' "$*" >>"$COMMAND_LOG"
/usr/bin/sleep 0.05
if [[ -n "${CHECK_OUTPUT:-}" ]]; then
  printf '%s\n' "$CHECK_OUTPUT"
fi
printf 'update-agent-tools complete\n' >>"$COMMAND_LOG"
STUB

  cat >"$bin_dir/tmux" <<'STUB'
#!/usr/bin/bash
set -euo pipefail

printf 'tmux %s\n' "$*" >>"$COMMAND_LOG"
if [[ "$*" == "has-session -t main" ]]; then
  [[ "${TMUX_SESSION_EXISTS:-1}" == "1" ]]
  exit
fi
STUB

  chmod +x "$bin_dir/aoe" "$bin_dir/update-agent-tools" "$bin_dir/tmux"
}

run_shell() {
  local home="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local interactive_with_tty="$4"
  local command_line
  local -a shell_environment=(
    "HOME=$home"
    "PATH=$home/.local/bin"
    "BASHRC_PATH=$BASHRC_PATH"
    "COMMAND_LOG=$home/command-log"
    "CHECK_OUTPUT=${CHECK_OUTPUT:-}"
    "SSH_TTY=${TEST_SSH_TTY:-}"
    "SSH_ORIGINAL_COMMAND=${TEST_SSH_ORIGINAL_COMMAND:-}"
    "SHELL=/bin/bash"
    "TMUX=${TEST_TMUX:-}"
    "TMUX_SESSION_EXISTS=${TMUX_SESSION_EXISTS:-1}"
  )

  if [[ "$interactive_with_tty" == "1" ]]; then
    # The child shell expands BASHRC_PATH from shell_environment.
    # shellcheck disable=SC2016
    printf -v command_line '%q ' \
      /usr/bin/bash --noprofile --norc -i -c 'source "$BASHRC_PATH"'
    env "${shell_environment[@]}" \
      /usr/bin/script -qefc "$command_line" /dev/null \
        >"$stdout_file" 2>"$stderr_file"
    tr -d '\r' <"$stdout_file" >"$stdout_file.normalized"
    mv "$stdout_file.normalized" "$stdout_file"
  else
    # The child shell expands BASHRC_PATH from shell_environment.
    # shellcheck disable=SC2016
    env "${shell_environment[@]}" \
      /usr/bin/bash --noprofile --norc -c 'source "$BASHRC_PATH"' \
        >"$stdout_file" 2>"$stderr_file"
  fi
}

test_due_check_finishes_before_existing_session_attach() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap '[[ -z "${test_dir:-}" ]] || rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir"

  TEST_SSH_TTY=/dev/pts/1 \
    CHECK_OUTPUT='AoE: 1.2.2 -> 1.2.3' \
    run_shell "$test_dir" "$test_dir/stdout" "$test_dir/stderr" 1 \
    || fail "eligible SSH login failed: $(<"$test_dir/stderr")"

  diff -u \
    <(printf 'AoE: 1.2.2 -> 1.2.3\n') \
    "$test_dir/stdout" \
    || fail "due-check notice was not the only login output"
  diff -u \
    <(printf '%s\n' \
      'update-agent-tools --check-if-due' \
      'update-agent-tools complete' \
      'tmux has-session -t main' \
      'tmux attach-session -t main') \
    "$test_dir/command-log" \
    || fail "due check did not finish before the existing AoE session attached"
}

test_due_check_finishes_before_new_session_launch() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap '[[ -z "${test_dir:-}" ]] || rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir"

  TEST_SSH_TTY=/dev/pts/1 \
    CHECK_OUTPUT='Codex CLI (standalone): 2.3.3 -> 2.3.4' \
    TMUX_SESSION_EXISTS=0 \
    run_shell "$test_dir" "$test_dir/stdout" "$test_dir/stderr" 1 \
    || fail "eligible SSH login failed: $(<"$test_dir/stderr")"

  diff -u \
    <(printf 'Codex CLI (standalone): 2.3.3 -> 2.3.4\n') \
    "$test_dir/stdout" \
    || fail "due-check notice was not shown before a new AoE session"
  diff -u \
    <(printf '%s\n' \
      'update-agent-tools --check-if-due' \
      'update-agent-tools complete' \
      'tmux has-session -t main' \
      'tmux new-session -s main aoe; exec /bin/bash -il') \
    "$test_dir/command-log" \
    || fail "due check did not finish before the new AoE session launched"
}

test_silent_check_adds_no_login_output() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap '[[ -z "${test_dir:-}" ]] || rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir"

  TEST_SSH_TTY=/dev/pts/1 \
    run_shell "$test_dir" "$test_dir/stdout" "$test_dir/stderr" 1 \
    || fail "eligible SSH login with a silent check failed: $(<"$test_dir/stderr")"

  [[ ! -s "$test_dir/stdout" ]] \
    || fail "healthy or not-yet-due check added login output: $(<"$test_dir/stdout")"
}

assert_context_skips_autolaunch() {
  local context="$1"
  local interactive_with_tty="$2"
  local ssh_tty="$3"
  local ssh_original_command="$4"
  local tmux_environment="$5"
  local missing_prerequisite="${6:-}"
  local test_dir
  test_dir="$(mktemp -d)"
  trap '[[ -z "${test_dir:-}" ]] || rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir"

  case "$missing_prerequisite" in
    marker) rm "$test_dir/.local/state/workstation-setup/complete" ;;
    aoe|tmux) rm "$test_dir/.local/bin/$missing_prerequisite" ;;
    '') ;;
    *) fail "unknown test prerequisite: $missing_prerequisite" ;;
  esac

  TEST_SSH_TTY="$ssh_tty" \
    TEST_SSH_ORIGINAL_COMMAND="$ssh_original_command" \
    TEST_TMUX="$tmux_environment" \
    CHECK_OUTPUT='this notice must not be shown' \
    run_shell \
      "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
      "$interactive_with_tty" \
    || fail "$context shell failed: $(<"$test_dir/stderr")"

  [[ ! -s "$test_dir/command-log" ]] \
    || fail "$context shell reached the freshness check or AoE launch: $(<"$test_dir/command-log")"
  [[ ! -s "$test_dir/stdout" ]] \
    || fail "$context shell gained output: $(<"$test_dir/stdout")"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "$context shell gained error output: $(<"$test_dir/stderr")"
}

test_excluded_shell_contexts_skip_the_check() {
  assert_context_skips_autolaunch \
    'local interactive' 1 '' '' ''
  assert_context_skips_autolaunch \
    'nested tmux' 1 /dev/pts/1 '' /tmp/tmux-1000/default,1,0
  assert_context_skips_autolaunch \
    'SSH remote command' 1 /dev/pts/1 'git-upload-pack repository' ''
  assert_context_skips_autolaunch \
    'non-interactive SSH' 0 /dev/pts/1 '' ''
  assert_context_skips_autolaunch \
    'workstation without setup marker' 1 /dev/pts/1 '' '' marker
  assert_context_skips_autolaunch \
    'workstation without AoE' 1 /dev/pts/1 '' '' aoe
  assert_context_skips_autolaunch \
    'workstation without tmux' 1 /dev/pts/1 '' '' tmux
}

test_missing_checker_preserves_existing_autolaunch() {
  local test_dir
  test_dir="$(mktemp -d)"
  trap '[[ -z "${test_dir:-}" ]] || rm -rf "$test_dir"' RETURN
  make_stubs "$test_dir"
  rm "$test_dir/.local/bin/update-agent-tools"

  TEST_SSH_TTY=/dev/pts/1 \
    CHECK_OUTPUT='this notice must not be shown' \
    run_shell "$test_dir" "$test_dir/stdout" "$test_dir/stderr" 1 \
    || fail "SSH login without the checker failed: $(<"$test_dir/stderr")"

  diff -u \
    <(printf '%s\n' \
      'tmux has-session -t main' \
      'tmux attach-session -t main') \
    "$test_dir/command-log" \
    || fail "missing checker suppressed the existing AoE auto-launch"
  [[ ! -s "$test_dir/stdout" ]] \
    || fail "missing checker added login output: $(<"$test_dir/stdout")"
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "missing checker added login error output: $(<"$test_dir/stderr")"
}

# shellcheck source=tests/lib/suite-dispatch.bash
source "$REPO_ROOT/tests/lib/suite-dispatch.bash"

readonly test_cases=(
  test_due_check_finishes_before_existing_session_attach
  test_due_check_finishes_before_new_session_launch
  test_silent_check_adds_no_login_output
  test_excluded_shell_contexts_skip_the_check
  test_missing_checker_preserves_existing_autolaunch
)

suite_dispatch 'bashrc AoE auto-launch boundary' "$@"
