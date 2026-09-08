#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/bin" "$HOME/.nix-profile/etc/profile.d"
  cp "$BATS_TEST_DIRNAME/../dot_bash_profile.tmpl" "$HOME/.bash_profile"
  printf '%s\n' 'echo unexpected-bashrc' >"$HOME/.bashrc"
  printf '%s\n' 'export TEST_HOME_MANAGER_SESSION=loaded' \
    >"$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
  local command
  for command in workstation-login workstation-update update-agent-tools; do
    # Expand HOME in the invoked command.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho unexpected-maintenance\ntouch "$HOME/maintenance-ran"\n' \
      >"$HOME/.local/bin/$command"
    chmod +x "$HOME/.local/bin/$command"
  done
}

assert_login_environment() {
  local command_line
  # Inspect the environment inside the login shell.
  # shellcheck disable=SC2016
  printf -v command_line '%q --login %s -i -c %q' \
    "$(command -v bash)" "${1:-}" \
    'printf "path=%s\nhome-manager=%s\nlogin-ready\n" "$PATH" "${TEST_HOME_MANAGER_SESSION:-}"'
  run env -i HOME="$HOME" PATH="$PATH" SHELL="$(command -v bash)" TERM=xterm \
    SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 22' SSH_TTY=/dev/pts/1 \
    ENV="${ENV:-}" KITTY_BASH_INJECT="${KITTY_BASH_INJECT:-}" \
    script -qefc "$command_line" /dev/null
  [ "$status" -eq 0 ]
  output="${output//$'\r'/}"
  [[ "$output" == path=* ]]
  local login_path="${output%%$'\n'*}"
  login_path=":${login_path#path=}:"
  [[ "$login_path" == *":$HOME/.local/bin:"* ]]
  [[ "$login_path" == *":$HOME/.nix-profile/bin:"* ]]
  [[ "$login_path" == *:/nix/var/nix/profiles/default/bin:* ]]
  [[ "$output" == *$'\nhome-manager=loaded\nlogin-ready' ]]
  [[ "$output" != *unexpected-* ]]
  [ ! -e "$HOME/maintenance-ran" ]
}

@test "SSH login loads the shell environment without launching maintenance" {
  assert_login_environment
}

@test "Kitty SSH injection loads the shell environment without launching maintenance" {
  export ENV="$HOME/kitty-login-injection.bash" KITTY_BASH_INJECT=1
  cat >"$ENV" <<'INJECTION'
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
  assert_login_environment --posix
}
