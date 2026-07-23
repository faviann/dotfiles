#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly BASH_PROFILE_PATH="$REPO_ROOT/dot_bash_profile.tmpl"
readonly LOGIN_COMMAND_PATH="$REPO_ROOT/dot_local/bin/executable_workstation-login"
REAL_BASH="$(command -v bash)"
REAL_SCRIPT="$(command -v script)"
readonly REAL_BASH REAL_SCRIPT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_fixture() {
  local home="$1"
  local bin_dir="$home/.local/bin"

  mkdir -p "$bin_dir" "$home/.local/state/workstation-setup"
  : >"$home/.local/state/workstation-setup/complete"
  cp "$BASH_PROFILE_PATH" "$home/.bash_profile"
  sed "1c #!$REAL_BASH" "$LOGIN_COMMAND_PATH" >"$bin_dir/workstation-login"

  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/workstation-update"
  cat >>"$bin_dir/workstation-update" <<'STUB'
set -euo pipefail

printf 'workstation-update %s\n' "$*" >>"$COMMAND_LOG"
if [[ -n "${CAPTURE_LOGIN_ENVIRONMENT:-}" ]]; then
  printf 'path=%s\n' "$PATH" >>"$COMMAND_LOG"
  printf 'home-manager=%s\n' "${TEST_HOME_MANAGER_SESSION:-}" >>"$COMMAND_LOG"
fi
if [[ -n "${CHECK_OUTPUT:-}" ]]; then
  printf '%s\n' "$CHECK_OUTPUT"
fi
exit "${CHECK_EXIT_STATUS:-0}"
STUB

  chmod +x "$bin_dir/workstation-login" "$bin_dir/workstation-update"
}

run_login() {
  local home="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local command_line
  local -a shell_environment=(
    "HOME=$home"
    "COMMAND_LOG=$home/command-log"
    "CHECK_EXIT_STATUS=${CHECK_EXIT_STATUS:-0}"
    "CHECK_OUTPUT=${CHECK_OUTPUT:-}"
    "CAPTURE_LOGIN_ENVIRONMENT=${CAPTURE_LOGIN_ENVIRONMENT:-}"
    "SSH_CONNECTION=${TEST_SSH_CONNECTION:-}"
    "SSH_ORIGINAL_COMMAND=${TEST_SSH_ORIGINAL_COMMAND:-}"
    "SSH_TTY=${TEST_SSH_TTY:-}"
    "SHELL=$REAL_BASH"
    "TERM=xterm"
  )

  printf -v command_line '%q --login -i -c %q' \
    "$REAL_BASH" 'printf "login-ready\n"'
  env -i "${shell_environment[@]}" \
    "$REAL_SCRIPT" -qefc "$command_line" /dev/null \
      >"$stdout_file" 2>"$stderr_file"
  tr -d '\r' <"$stdout_file" >"$stdout_file.normalized"
  mv "$stdout_file.normalized" "$stdout_file"
}

run_kitty_login() {
  local home="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local injection_file="$home/kitty-login-injection.bash"
  local command_line
  local -a shell_environment=(
    "HOME=$home"
    "COMMAND_LOG=$home/command-log"
    "CHECK_EXIT_STATUS=${CHECK_EXIT_STATUS:-0}"
    "CHECK_OUTPUT=${CHECK_OUTPUT:-}"
    "CAPTURE_LOGIN_ENVIRONMENT=${CAPTURE_LOGIN_ENVIRONMENT:-}"
    "ENV=$injection_file"
    "KITTY_BASH_INJECT=1"
    "SSH_CONNECTION=${TEST_SSH_CONNECTION:-}"
    "SSH_ORIGINAL_COMMAND=${TEST_SSH_ORIGINAL_COMMAND:-}"
    "SSH_TTY=${TEST_SSH_TTY:-}"
    "SHELL=$REAL_BASH"
    "TERM=xterm-kitty"
  )

  cat >"$injection_file" <<'INJECTION'
[[ "$-" == *i* ]] || return
[[ -n "${KITTY_BASH_INJECT:-}" ]] || return
unset ENV KITTY_BASH_INJECT
set +o posix
if shopt -q login_shell; then
  for startup_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [[ -r "$startup_file" ]]; then
      source "$startup_file"
      break
    fi
  done
fi
INJECTION

  printf -v command_line '%q --login --posix -i -c %q' \
    "$REAL_BASH" 'printf "login-ready\n"'
  env -i "${shell_environment[@]}" \
    "$REAL_SCRIPT" -qefc "$command_line" /dev/null \
      >"$stdout_file" 2>"$stderr_file"
  tr -d '\r' <"$stdout_file" >"$stdout_file.normalized"
  mv "$stdout_file.normalized" "$stdout_file"
}

test_regular_ssh_login_reports_actionable_freshness_before_shell_ready() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"

  TEST_SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 22' \
    TEST_SSH_TTY=/dev/pts/1 \
    CHECK_OUTPUT=$'Workstation maintenance available:\nAgent tools:\n  Codex CLI (standalone): 0.144.6 -> 0.145.0\nRun: workstation-update' \
    run_login "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "regular SSH login failed: $(<"$test_dir/stderr")"

  diff -u \
    <(printf '%s\n' \
      'Workstation maintenance available:' \
      'Agent tools:' \
      '  Codex CLI (standalone): 0.144.6 -> 0.145.0' \
      'Run: workstation-update' \
      'login-ready') \
    "$test_dir/stdout" \
    || fail 'freshness verdict was not shown before the login shell became ready'
  diff -u \
    <(printf '%s\n' 'workstation-update --freshness') \
    "$test_dir/command-log" \
    || fail 'regular SSH login did not invoke freshness exactly once'
}

test_healthy_ssh_login_is_silent() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"

  TEST_SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 22' \
    TEST_SSH_TTY=/dev/pts/1 \
    run_login "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "healthy SSH login failed: $(<"$test_dir/stderr")"

  diff -u <(printf '%s\n' 'login-ready') "$test_dir/stdout" \
    || fail 'healthy freshness check added login output'
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "healthy freshness check added login errors: $(<"$test_dir/stderr")"
  diff -u \
    <(printf '%s\n' 'workstation-update --freshness') \
    "$test_dir/command-log" \
    || fail 'healthy SSH login did not invoke freshness exactly once'
}

test_login_profile_loads_required_shell_environment_without_bashrc() {
  local login_path
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  mkdir -p "$test_dir/.nix-profile/etc/profile.d"
  printf '%s\n' "export TEST_HOME_MANAGER_SESSION=loaded" \
    >"$test_dir/.nix-profile/etc/profile.d/hm-session-vars.sh"

  TEST_SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 22' \
    TEST_SSH_TTY=/dev/pts/1 \
    CAPTURE_LOGIN_ENVIRONMENT=1 \
    run_login "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "SSH login environment setup failed: $(<"$test_dir/stderr")"

  login_path="$(sed -n 's/^path=//p' "$test_dir/command-log")"
  [[ "$login_path" == "$test_dir/.local/bin:$test_dir/.nix-profile/bin:/nix/var/nix/profiles/default/bin:"* ]] \
    || fail "login profile did not prepend the required workstation paths: $login_path"
  grep -Fqx 'home-manager=loaded' "$test_dir/command-log" \
    || fail 'login profile did not load Home Manager session variables'
}

test_missing_login_command_warns_without_blocking_shell() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  rm "$test_dir/.local/bin/workstation-login"

  TEST_SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 22' \
    TEST_SSH_TTY=/dev/pts/1 \
    run_login "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "SSH login without its managed command failed: $(<"$test_dir/stderr")"

  diff -u \
    <(printf '%s\n' \
      'Workstation login freshness is unavailable. Run: workstation-update' \
      'login-ready') \
    "$test_dir/stdout" \
    || fail 'missing login command prevented the shell from becoming ready'
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "missing login command escaped the PTY: $(<"$test_dir/stderr")"
  [[ ! -e "$test_dir/command-log" ]] \
    || fail 'missing login command still invoked workstation-update'
}

test_missing_freshness_checker_warns_without_blocking_shell() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  rm "$test_dir/.local/bin/workstation-update"

  TEST_SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 22' \
    TEST_SSH_TTY=/dev/pts/1 \
    run_login "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "SSH login without freshness checker failed: $(<"$test_dir/stderr")"

  diff -u \
    <(printf '%s\n' \
      'Workstation freshness checker is unavailable. Run: workstation-setup' \
      'login-ready') \
    "$test_dir/stdout" \
    || fail 'missing freshness checker did not warn before opening the shell'
  [[ ! -e "$test_dir/command-log" ]] \
    || fail 'missing freshness checker unexpectedly reached a command'
}

test_failed_freshness_checker_warns_on_every_login() {
  local test_dir
  local attempt

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"

  for attempt in first second; do
    TEST_SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 22' \
      TEST_SSH_TTY=/dev/pts/1 \
      CHECK_EXIT_STATUS=17 \
      run_login \
        "$test_dir" "$test_dir/$attempt.stdout" "$test_dir/$attempt.stderr" \
      || fail "$attempt SSH login escaped a failed freshness checker"

    diff -u \
      <(printf '%s\n' \
        'Workstation freshness check failed unexpectedly. Run: workstation-update' \
        'login-ready') \
      "$test_dir/$attempt.stdout" \
      || fail "$attempt SSH login did not repeat the freshness failure warning"
  done

  diff -u \
    <(printf '%s\n' \
      'workstation-update --freshness' \
      'workstation-update --freshness') \
    "$test_dir/command-log" \
    || fail 'consecutive SSH logins did not each retry freshness'
}

test_ineligible_login_contexts_skip_freshness() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"

  run_login "$test_dir" "$test_dir/local.stdout" "$test_dir/local.stderr" \
    || fail 'local login shell failed'
  TEST_SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 22' \
    TEST_SSH_TTY=/dev/pts/1 \
    TEST_SSH_ORIGINAL_COMMAND='git-upload-pack repository' \
    run_login "$test_dir" "$test_dir/remote.stdout" "$test_dir/remote.stderr" \
    || fail 'SSH remote-command shell failed'

  diff -u <(printf '%s\n' 'login-ready') "$test_dir/local.stdout" \
    || fail 'local login gained workstation freshness output'
  diff -u <(printf '%s\n' 'login-ready') "$test_dir/remote.stdout" \
    || fail 'SSH remote-command login gained workstation freshness output'
  [[ ! -e "$test_dir/command-log" ]] \
    || fail 'an ineligible login context invoked workstation freshness'
}

test_kitty_ssh_injection_loads_the_managed_login_profile_once() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"

  TEST_SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 22' \
    TEST_SSH_TTY=/dev/pts/1 \
    CHECK_OUTPUT=$'Workstation maintenance available:\nAgent tools:\n  Codex CLI (standalone): 0.144.6 -> 0.145.0\nRun: workstation-update' \
    run_kitty_login "$test_dir" "$test_dir/stdout" "$test_dir/stderr" \
    || fail "Kitty SSH login failed: $(<"$test_dir/stderr")"

  diff -u \
    <(printf '%s\n' \
      'Workstation maintenance available:' \
      'Agent tools:' \
      '  Codex CLI (standalone): 0.144.6 -> 0.145.0' \
      'Run: workstation-update' \
      'login-ready') \
    "$test_dir/stdout" \
    || fail 'Kitty SSH login did not show freshness before the shell was ready'
  diff -u \
    <(printf '%s\n' 'workstation-update --freshness') \
    "$test_dir/command-log" \
    || fail 'Kitty SSH login did not invoke freshness exactly once'
}

# shellcheck source=tests/lib/suite-dispatch.bash
source "$REPO_ROOT/tests/lib/suite-dispatch.bash"

readonly test_cases=(
  test_regular_ssh_login_reports_actionable_freshness_before_shell_ready
  test_healthy_ssh_login_is_silent
  test_login_profile_loads_required_shell_environment_without_bashrc
  test_missing_login_command_warns_without_blocking_shell
  test_missing_freshness_checker_warns_without_blocking_shell
  test_failed_freshness_checker_warns_on_every_login
  test_ineligible_login_contexts_skip_freshness
  test_kitty_ssh_injection_loads_the_managed_login_profile_once
)

suite_dispatch 'workstation SSH login freshness' "$@"
