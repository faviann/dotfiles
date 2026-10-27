#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  export HOME="$BATS_TEST_TMPDIR/home"
  export COMMAND_LOG="$BATS_TEST_TMPDIR/commands"
  local bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$HOME" "$bin"
  : >"$COMMAND_LOG"
  cat >"$bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'GIT_TERMINAL_PROMPT=%s git' "${GIT_TERMINAL_PROMPT-unset}" >>"$COMMAND_LOG"
printf ' %s' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
[[ -d "$(dirname "${@: -1}")" ]] || exit 65
if [[ -n "${GIT_FAILS:-}" ]]; then
  printf "fatal: unable to access 'https://github.com/faviann/homelab-iac.git/': Could not resolve host: github.com\n" >&2
  exit 128
fi
STUB
  sed -i "1c #!$(command -v bash)" "$bin/git"
  chmod +x "$bin/git"
  export PATH="$bin:$PATH"
}

run_clone() {
  bash "$REPO_ROOT/.chezmoiscripts/run_after_clone-homelab-iac.sh"
}

readonly CLONE_LOG_LINE='GIT_TERMINAL_PROMPT=0 git clone https://github.com/faviann/homelab-iac.git'

@test "test_missing_homelab_iac_checkout_is_cloned_over_https" {
  run_clone

  diff -u - "$COMMAND_LOG" <<<"$CLONE_LOG_LINE $HOME/repos/homelab-iac"
}

@test "test_failed_clone_warns_without_failing_the_apply" {
  bats_require_minimum_version 1.5.0

  GIT_FAILS=1 run --separate-stderr run_clone

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = "fatal: unable to access 'https://github.com/faviann/homelab-iac.git/': Could not resolve host: github.com
clone-homelab-iac: warning: cannot clone https://github.com/faviann/homelab-iac.git into $HOME/repos/homelab-iac; the next apply retries" ]
  diff -u - "$COMMAND_LOG" <<<"$CLONE_LOG_LINE $HOME/repos/homelab-iac"
}

@test "test_existing_homelab_iac_path_is_never_touched" {
  local existing

  mkdir -p "$HOME/repos/homelab-iac"
  printf 'local work\n' >"$HOME/repos/homelab-iac/notes"
  run_clone
  [[ "$(cat "$HOME/repos/homelab-iac/notes")" == 'local work' ]] \
    || fail 'existing checkout was modified'

  rm -rf "$HOME/repos/homelab-iac"
  existing="$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$existing" "$HOME/repos/homelab-iac"
  run_clone

  [[ ! -s "$COMMAND_LOG" ]] || fail "git ran for an existing path: $(cat "$COMMAND_LOG")"
}
