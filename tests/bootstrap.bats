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
  export BOOTSTRAP_TEST_ROOT="$BATS_TEST_TMPDIR/root"
  export NIX_PROFILE_BIN="$BATS_TEST_TMPDIR/nix-profile/bin"
  export STUBS="$BATS_TEST_TMPDIR/bin"
  TOOLS="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$HOME" "$STATE" "$STUBS" "$TOOLS" "$NIX_PROFILE_BIN"
  : >"$CALLS"
  unset BW_SESSION DOTFILES_REF XDG_CONFIG_HOME XDG_DATA_HOME

  local tool
  for tool in cat chmod env git ln mkdir mktemp rm seq sha256sum sleep; do
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
url="${*: -1}"
printf 'curl %s\n' "$url" >>"$CALLS"
while [[ "$1" != -o ]]; do shift; done
case "$url" in
  */nix-installer-x86_64-linux) cat "$STUBS/.nix-installer" >"$2" ;;
  *) printf 'not the pinned release\n' >"$2" ;;
esac
STUB
  stub sha256sum <<'STUB'
STUB
  stub nix-installer <<'STUB'
printf 'nix-installer %s\n' "$*" >>"$CALLS"
ln -sf "$STUBS/.nix" "$NIX_PROFILE_BIN/nix"
mkdir -p "$BOOTSTRAP_TEST_ROOT/nix/var/nix/profiles/default/etc/profile.d"
printf 'PATH="%s:$PATH"\n' "$NIX_PROFILE_BIN" \
  >"$BOOTSTRAP_TEST_ROOT/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
[[ " $* " == *' --init none '* ]] || : >"$STATE/nix-daemon"
STUB
  stub sh <<'STUB'
printf 'sh %s\n' "$*" >>"$CALLS"
: >"$STATE/nix-daemon"
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
  stub dotfiles-clone <<'STUB'
source_dir="$HOME/.local/share/chezmoi"
git init -q "$source_dir"
git -C "$source_dir" remote add origin "$1"
git -C "$source_dir" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
STUB
  stub chezmoi <<'STUB'
printf 'chezmoi %s\n' "$*" >>"$CALLS"
case "$1" in
  init)
    [[ -e "$HOME/.local/share/chezmoi" ]] || "$STUBS/.dotfiles-clone" "${*: -1}"
    mkdir -p "$HOME/.config/chezmoi"
    : >"$HOME/.config/chezmoi/chezmoi.toml"
    ;;
  apply)
    printf 'chezmoi apply sees BW_SESSION=%s\n' "${BW_SESSION:-}" >>"$CALLS"
    command -v nix >/dev/null || printf 'chezmoi apply finds no nix\n' >>"$CALLS"
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
  for name in uname id dpkg-query sudo apt-get curl sh; do
    ln -sf ".$name" "$STUBS/$name"
  done
  run --separate-stderr env PATH="$STUBS:$TOOLS" "$REAL_BASH" "$SCRIPT"
}

given_initialized_chezmoi() {
  "$STUBS/.dotfiles-clone" "${1:-https://github.com/faviann/dotfiles.git}"
  mkdir -p "$HOME/.config/chezmoi"
  : >"$HOME/.config/chezmoi/chezmoi.toml"
}

given_downloads_match_their_checksums() {
  ln -sf .sha256sum "$STUBS/sha256sum"
}

given_systemd() {
  mkdir -p "$BOOTSTRAP_TEST_ROOT/run/systemd/system"
}

actions() {
  grep -v -e ' --check$' "$CALLS" | sed "s|$BATS_TEST_TMPDIR/tmp\.[^/]*/|\$work/|" || true
}

refute_printed() {
  [[ "$output" != *"$1"* && "$stderr" != *"$1"* ]] || fail "printed $1"
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
  given_initialized_chezmoi git@github.com:faviann/dotfiles.git

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
  refute_printed login-session
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
  refute_printed unlock-session
  diff -u - <(actions) <<'EXPECTED'
bw unlock --raw
bw sync
chezmoi apply
chezmoi apply sees BW_SESSION=unlock-session
EXPECTED
}

@test "test_bootstrap_installs_nix_without_an_init_system_and_starts_its_daemon_without_systemd" {
  given apt chezmoi bw
  given_downloads_match_their_checksums

  run_bootstrap

  [ "$status" -eq 0 ]
  [ "$stderr" = '' ]
  refute_printed login-session
  diff -u - <(actions) <<'EXPECTED'
bw login --raw
curl https://github.com/DeterminateSystems/nix-installer/releases/download/v3.24.1/nix-installer-x86_64-linux
sudo $work/nix-installer install linux --init none --no-confirm
nix-installer install linux --init none --no-confirm
sudo sh -c nohup /nix/var/nix/profiles/default/bin/nix-daemon >/var/log/nix-daemon.log 2>&1 &
sh -c nohup /nix/var/nix/profiles/default/bin/nix-daemon >/var/log/nix-daemon.log 2>&1 &
chezmoi init --branch main https://github.com/faviann/dotfiles.git
chezmoi apply
chezmoi apply sees BW_SESSION=login-session
EXPECTED
}

@test "test_bootstrap_installs_nix_with_systemd_and_leaves_the_daemon_to_it" {
  given apt chezmoi bw bw-logged-in bw-unlocked
  given_downloads_match_their_checksums
  given_systemd

  run_bootstrap

  [ "$status" -eq 0 ]
  [ "$stderr" = '' ]
  diff -u - <(actions) <<'EXPECTED'
curl https://github.com/DeterminateSystems/nix-installer/releases/download/v3.24.1/nix-installer-x86_64-linux
sudo $work/nix-installer install --no-confirm
nix-installer install --no-confirm
chezmoi init --branch main https://github.com/faviann/dotfiles.git
chezmoi apply
chezmoi apply sees BW_SESSION=
EXPECTED
}

@test "test_bootstrap_stops_when_systemd_runs_no_nix_daemon" {
  given apt chezmoi bw bw-logged-in bw-unlocked nix
  given_initialized_chezmoi
  given_systemd

  run_bootstrap

  [ "$status" -eq 1 ]
  [ "$stderr" = 'bootstrap: error: nix cannot reach its daemon; check systemctl status nix-daemon.socket' ]
  [ "$(actions)" = '' ]
}

@test "test_a_rerun_loads_installed_nix_and_restarts_its_daemon_after_a_container_restart" {
  given apt chezmoi bw bw-logged-in bw-unlocked
  given_initialized_chezmoi
  given_downloads_match_their_checksums
  "$STUBS/.nix-installer" install linux --init none --no-confirm
  : >"$CALLS"

  run_bootstrap

  [ "$status" -eq 0 ]
  [[ "$output" == *'bootstrap: nix: already done'* ]] || fail "reinstalled nix: $output"
  diff -u - <(actions) <<'EXPECTED'
sudo sh -c nohup /nix/var/nix/profiles/default/bin/nix-daemon >/var/log/nix-daemon.log 2>&1 &
sh -c nohup /nix/var/nix/profiles/default/bin/nix-daemon >/var/log/nix-daemon.log 2>&1 &
chezmoi apply
chezmoi apply sees BW_SESSION=
EXPECTED
}

@test "test_bootstrap_initializes_a_complete_clone_that_has_no_chezmoi_config" {
  given "${SET_UP_STATE[@]}"
  "$STUBS/.dotfiles-clone" https://github.com/faviann/dotfiles.git

  run_bootstrap

  [ "$status" -eq 0 ]
  diff -u - <(actions) <<'EXPECTED'
chezmoi init --branch main https://github.com/faviann/dotfiles.git
chezmoi apply
chezmoi apply sees BW_SESSION=
EXPECTED
}

@test "test_bootstrap_refuses_a_chezmoi_source_that_is_another_repository" {
  given "${SET_UP_STATE[@]}"
  given_initialized_chezmoi https://github.com/someone/dotfiles.git

  run_bootstrap

  [ "$status" -eq 1 ]
  [ "$stderr" = "bootstrap: error: $HOME/.local/share/chezmoi is not a complete clone of https://github.com/faviann/dotfiles.git; move it aside, then rerun this command" ]
  [ "$(actions)" = '' ]
}

@test "test_bootstrap_refuses_an_interrupted_clone" {
  given "${SET_UP_STATE[@]}"
  local source_dir="$HOME/.local/share/chezmoi"
  mkdir -p "$source_dir/.git" "$HOME/.config/chezmoi"
  : >"$HOME/.config/chezmoi/chezmoi.toml"

  run_bootstrap
  [ "$status" -eq 1 ]
  [ "$stderr" = "bootstrap: error: $source_dir is not a complete clone of https://github.com/faviann/dotfiles.git; move it aside, then rerun this command" ]

  git init -q "$source_dir"
  git -C "$source_dir" remote add origin https://github.com/faviann/dotfiles.git
  run_bootstrap
  [ "$status" -eq 1 ]
  [ "$stderr" = "bootstrap: error: $source_dir is not a complete clone of https://github.com/faviann/dotfiles.git; move it aside, then rerun this command" ]
  [ "$(actions)" = '' ]
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
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y git curl jq gh unzip
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
