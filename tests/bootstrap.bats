#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

REAL_BASH="$(command -v bash)"
readonly REAL_BASH
readonly SCRIPT="$REPO_ROOT/bootstrap.sh"

SET_UP_STATE=(apt chezmoi bw bw-logged-in bw-unlocked nix nix-daemon)

setup() {
  bats_require_minimum_version 1.5.0
  export TMPDIR="$BATS_TEST_TMPDIR"
  export HOME="$BATS_TEST_TMPDIR/home"
  export STATE="$BATS_TEST_TMPDIR/state" CALLS="$BATS_TEST_TMPDIR/calls"
  STUBS="$BATS_TEST_TMPDIR/bin"
  TOOLS="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$HOME" "$STATE" "$STUBS" "$TOOLS"
  : >"$CALLS"
  unset BW_SESSION DOTFILES_REF XDG_CONFIG_HOME XDG_DATA_HOME

  local tool
  for tool in cat chmod mkdir mktemp rm seq sha256sum sleep; do
    ln -s "$(command -v "$tool")" "$TOOLS/$tool"
  done

  stub uname <<'STUB'
case "$1" in
  -n) printf '%s\n' "${STUB_HOSTNAME:-laptop-test}" ;;
  -m) printf '%s\n' "${STUB_ARCH:-x86_64}" ;;
esac
STUB
  stub id <<'STUB'
printf '%s\n' "${STUB_UID:-1000}"
STUB
  stub dpkg-query <<'STUB'
[[ -e "$STATE/apt" ]] || exit 1
printf installed
STUB
  stub sudo <<'STUB'
printf 'sudo %s\n' "$*" >>"$CALLS"
"$@"
STUB
  stub apt-get <<'STUB'
[[ "$1" != install ]] || : >"$STATE/apt"
STUB
  stub curl <<'STUB'
printf 'curl %s\n' "${*: -1}" >>"$CALLS"
while [[ "$1" != -o ]]; do shift; done
printf 'not the pinned release\n' >"$2"
STUB
  stub bw <<'STUB'
printf 'bw %s\n' "$*" >>"$CALLS"
case "$*" in
  'login --check') [[ -e "$STATE/bw-logged-in" ]] ;;
  'login --raw') : >"$STATE/bw-logged-in"; printf 'login-session' ;;
  'unlock --check') [[ -e "$STATE/bw-unlocked" || "${BW_SESSION:-}" == *-session ]] ;;
  'unlock --raw') printf 'unlock-session' ;;
  sync) ;;
  *) exit 64 ;;
esac
STUB
  stub chezmoi <<'STUB'
printf 'chezmoi %s\n' "$*" >>"$CALLS"
case "$1" in
  init)
    mkdir -p "$HOME/.local/share/chezmoi/.git" "$HOME/.config/chezmoi"
    : >"$HOME/.config/chezmoi/chezmoi.toml"
    ;;
  apply)
    printf 'chezmoi apply sees BW_SESSION=%s\n' "${BW_SESSION:-}" >>"$CALLS"
    exit "${STUB_APPLY_STATUS:-0}"
    ;;
esac
STUB
  stub nix <<'STUB'
[[ "$*" == 'store info' && -e "$STATE/nix-daemon" ]]
STUB
}

stub() {
  local name="$1"
  {
    printf '#!%s\nset -euo pipefail\n' "$REAL_BASH"
    cat
  } >"$STUBS/.$name"
  chmod +x "$STUBS/.$name"
}

given() {
  local item
  for item in "$@"; do
    : >"$STATE/$item"
    [[ ! -e "$STUBS/.$item" ]] || ln -sf ".$item" "$STUBS/$item"
  done
}

run_bootstrap() {
  local name
  for name in uname id dpkg-query sudo apt-get curl; do
    ln -sf ".$name" "$STUBS/$name"
  done
  run --separate-stderr env PATH="$STUBS:$TOOLS" "$REAL_BASH" "$SCRIPT"
}

given_initialized_chezmoi() {
  mkdir -p "$HOME/.local/share/chezmoi/.git" "$HOME/.config/chezmoi"
  : >"$HOME/.config/chezmoi/chezmoi.toml"
}

actions() {
  grep -v -e ' --check$' "$CALLS" || true
}

@test "test_bootstrap_refuses_the_workstation" {
  STUB_HOSTNAME=workstation run_bootstrap

  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  [ "$stderr" = 'bootstrap: error: this is the workstation, which homelab-iac provisions; run workstation-setup instead' ]
  [ ! -s "$CALLS" ]
}

@test "test_bootstrap_refuses_other_architectures_and_root" {
  STUB_ARCH=aarch64 run_bootstrap
  [ "$status" -eq 1 ]
  [ "$stderr" = 'bootstrap: error: only x86_64 is supported; the desktop Home Manager profile builds for x86_64-linux' ]

  STUB_UID=0 run_bootstrap
  [ "$status" -eq 1 ]
  [ "$stderr" = 'bootstrap: error: run this as your own user, not root; it calls sudo when it needs to' ]
  [ ! -s "$CALLS" ]
}

@test "test_bootstrap_skips_every_done_step_on_a_set_up_machine" {
  given "${SET_UP_STATE[@]}"
  given_initialized_chezmoi

  run_bootstrap

  [ "$status" -eq 0 ]
  [ "$stderr" = '' ]
  diff -u - <(printf '%s\n' "$output") <<'EXPECTED'
bootstrap: apt: already done
bootstrap: chezmoi: already done
bootstrap: bw: already done
bootstrap: bw_login: already done
bootstrap: bw_unlock: already done
bootstrap: nix: already done
bootstrap: nix_daemon: already done
bootstrap: chezmoi_init: already done
bootstrap: chezmoi_apply: running
bootstrap: done. Next steps:
bootstrap:   Open a new terminal so it picks up Nix and the new PATH.
bootstrap:   Run codex login to sign Codex in on this machine.
EXPECTED
  diff -u - <(actions) <<'EXPECTED'
chezmoi apply
chezmoi apply sees BW_SESSION=
EXPECTED
}

@test "test_bootstrap_logs_in_to_bitwarden_and_hands_the_session_to_chezmoi" {
  given apt chezmoi bw nix nix-daemon

  run_bootstrap

  [ "$status" -eq 0 ]
  [[ "$output" != *login-session* ]] || fail 'printed the Bitwarden session'
  diff -u - <(actions) <<'EXPECTED'
bw login --raw
chezmoi init --branch main https://github.com/faviann/dotfiles.git
chezmoi apply
chezmoi apply sees BW_SESSION=login-session
EXPECTED
}

@test "test_bootstrap_unlocks_and_syncs_a_logged_in_vault" {
  given apt chezmoi bw bw-logged-in nix nix-daemon
  given_initialized_chezmoi

  run_bootstrap

  [ "$status" -eq 0 ]
  diff -u - <(actions) <<'EXPECTED'
bw unlock --raw
bw sync
chezmoi apply
chezmoi apply sees BW_SESSION=unlock-session
EXPECTED
}

@test "test_dotfiles_ref_selects_the_branch_that_chezmoi_init_clones" {
  given "${SET_UP_STATE[@]}"

  DOTFILES_REF=feat/one-command-bootstrap run_bootstrap

  [ "$status" -eq 0 ]
  grep -qx 'chezmoi init --branch feat/one-command-bootstrap https://github.com/faviann/dotfiles.git' "$CALLS" \
    || fail "chezmoi init did not clone the selected ref: $(cat "$CALLS")"
}

@test "test_bootstrap_installs_missing_apt_packages" {
  given chezmoi bw bw-logged-in bw-unlocked nix nix-daemon
  given_initialized_chezmoi

  run_bootstrap

  [ "$status" -eq 0 ]
  diff -u - <(actions) <<'EXPECTED'
sudo apt-get update
sudo apt-get install -y git curl jq gh unzip
chezmoi apply
chezmoi apply sees BW_SESSION=
EXPECTED
}

@test "test_bootstrap_stops_on_a_download_that_fails_its_checksum" {
  given apt

  run_bootstrap

  [ "$status" -eq 1 ]
  [ "$stderr" = 'bootstrap: error: checksum mismatch for https://github.com/twpayne/chezmoi/releases/download/v2.73.3/chezmoi_2.73.3_linux_amd64.tar.gz' ]
  [ "${lines[-1]}" = 'bootstrap: chezmoi: running' ]
  diff -u - <(actions) <<'EXPECTED'
curl https://github.com/twpayne/chezmoi/releases/download/v2.73.3/chezmoi_2.73.3_linux_amd64.tar.gz
EXPECTED
}

@test "test_a_rerun_after_a_failed_apply_skips_init_and_applies_again" {
  given "${SET_UP_STATE[@]}"

  STUB_APPLY_STATUS=1 run_bootstrap
  [ "$status" -eq 1 ]
  [ "$stderr" = 'bootstrap: error: chezmoi apply failed; fix the error above, then rerun this command' ]
  [[ "$output" != *'Next steps'* ]] || fail 'printed next steps after a failed apply'

  : >"$CALLS"
  run_bootstrap
  [ "$status" -eq 0 ]
  diff -u - <(actions) <<'EXPECTED'
chezmoi apply
chezmoi apply sees BW_SESSION=
EXPECTED
}
