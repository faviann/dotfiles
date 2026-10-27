#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

REAL_BASH="$(command -v bash)"
readonly REAL_BASH
readonly SCRIPT="$REPO_ROOT/.chezmoiscripts/run_after_login-github-cli.sh"

setup() {
  bats_require_minimum_version 1.5.0
  export TMPDIR="$BATS_TEST_TMPDIR"
  export HOME="$BATS_TEST_TMPDIR/home"
  export STATE="$BATS_TEST_TMPDIR/state" CALLS="$BATS_TEST_TMPDIR/calls"
  export BW_SESSION=fixture-session
  export NOTES=$'  token-new\n'
  STUB_ONLY_PATH="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME" "$STATE" "$STUB_ONLY_PATH"
  : >"$CALLS"
  printf 'token-old\n' >"$STATE/gh-token"

  cat >"$STUB_ONLY_PATH/gh" <<'STUB'
set -euo pipefail
printf 'gh %s\n' "$*" >>"$CALLS"
case "$*" in
  'auth token --hostname github.com')
    [[ -f "$STATE/gh-token" ]] || { printf 'no oauth token found\n' >&2; exit 1; }
    printf '%s' "$(<"$STATE/gh-token")"
    ;;
  'auth login --hostname github.com --with-token')
    IFS= read -r -d '' stdin || true
    printf '%s' "$stdin" >"$STATE/login-stdin"
    [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]] || { printf 'GH_TOKEN is set\n' >&2; exit 1; }
    if [[ -n "${GH_REJECTS:-}" ]]; then
      printf 'error validating token: HTTP 401: Bad credentials (https://api.github.com/)\nTry authenticating with:  gh auth login\n' >&2
      exit 1
    fi
    printf '%s' "$stdin" >"$STATE/gh-token"
    ;;
  *) exit 64 ;;
esac
STUB
  cat >"$STUB_ONLY_PATH/bw" <<'STUB'
set -euo pipefail
printf 'bw %s\n' "$*" >>"$CALLS"
case "$*" in
  'unlock --check') [[ "${BW_SESSION:-}" == fixture-session ]] ;;
  'get notes dotfiles/github-cli-token') printf '%s' "$NOTES" ;;
  *) exit 64 ;;
esac
STUB
  sed -i "1i #!$REAL_BASH" "$STUB_ONLY_PATH/gh" "$STUB_ONLY_PATH/bw"
  chmod +x "$STUB_ONLY_PATH/gh" "$STUB_ONLY_PATH/bw"
}

run_login() {
  run --separate-stderr env PATH="$STUB_ONLY_PATH" "$REAL_BASH" "$SCRIPT"
}

@test "test_login_waits_for_gh_to_be_installed" {
  rm "$STUB_ONLY_PATH/gh"

  run_login

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = 'login-github-cli: gh is not installed yet; the next apply logs it in' ]
  [ ! -s "$CALLS" ]
}

@test "test_login_leaves_gh_alone_without_an_unlocked_vault" {
  BW_SESSION='' run_login
  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
  diff -u - "$CALLS" <<<'bw unlock --check'

  rm "$STUB_ONLY_PATH/bw"
  : >"$CALLS"
  run_login
  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
  [ ! -s "$CALLS" ]
  [ "$(<"$STATE/gh-token")" = token-old ]
}

@test "test_login_skips_a_current_token_without_logging_in" {
  printf 'token-new\n' >"$STATE/gh-token"

  run_login

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
  diff -u - "$CALLS" <<'CALLS'
bw unlock --check
bw get notes dotfiles/github-cli-token
gh auth token --hostname github.com
CALLS
}

@test "test_login_replaces_a_different_token_through_stdin" {
  GH_TOKEN=environment-token GITHUB_TOKEN=environment-token run_login

  [ "$status" -eq 0 ]
  [ "$output" = 'login-github-cli: logged gh in with Bitwarden item dotfiles/github-cli-token' ]
  [ "$stderr" = '' ]
  cmp -s "$STATE/login-stdin" <(printf 'token-new\n') \
    || fail 'login stdin is not the stored token and one newline'
  diff -u - "$CALLS" <<'CALLS'
bw unlock --check
bw get notes dotfiles/github-cli-token
gh auth token --hostname github.com
gh auth login --hostname github.com --with-token
CALLS
}

@test "test_login_logs_in_when_gh_holds_no_token" {
  rm "$STATE/gh-token"

  run_login

  [ "$status" -eq 0 ]
  [ "$output" = 'login-github-cli: logged gh in with Bitwarden item dotfiles/github-cli-token' ]
  [ "$(<"$STATE/gh-token")" = token-new ]
}

@test "test_login_warns_when_gh_cannot_log_in" {
  GH_REJECTS=1 run_login

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = 'login-github-cli: warning: gh could not log in with the token in Bitwarden item dotfiles/github-cli-token: error validating token: HTTP 401: Bad credentials (https://api.github.com/) Try authenticating with:  gh auth login. If the token is invalid, replace it with github-token rotate' ]
  [ "$(<"$STATE/gh-token")" = token-old ]
}

@test "test_login_warns_about_empty_notes_without_logging_in" {
  NOTES=$' \n\t' run_login

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = 'login-github-cli: warning: cannot read a token from the Notes of Bitwarden item dotfiles/github-cli-token' ]
  run ! grep -q '^gh' "$CALLS"
}
