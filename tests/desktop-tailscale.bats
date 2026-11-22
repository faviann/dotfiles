#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

REAL_BASH="$(command -v bash)"
readonly REAL_BASH
readonly SCRIPT="$REPO_ROOT/.chezmoiscripts/run_after_connect-work-tailscale.sh"
readonly SIGN_IN='connect-work-tailscale: sign in to the work tailnet with your work account: tailscale up --operator=tester --accept-routes --accept-dns --shields-up'
readonly BASE_URL=https://pkgs.tailscale.com/stable/ubuntu/resolute
readonly CURL_FLAGS="-fsSL --proto =https --tlsv1.2"

setup() {
  bats_require_minimum_version 1.5.0
  export TMPDIR="$BATS_TEST_TMPDIR"
  export USER=tester
  export STATE="$BATS_TEST_TMPDIR/stub-state"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  export CONNECT_WORK_TAILSCALE_TEST_ROOT="$BATS_TEST_TMPDIR/root"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  REAL_TOOLS="$BATS_TEST_TMPDIR/real-tools"
  mkdir -p "$STATE" "$STUBS" "$REAL_TOOLS" "$CONNECT_WORK_TAILSCALE_TEST_ROOT/etc"
  : >"$CALLS"
  printf 'ID=ubuntu\nVERSION_CODENAME=resolute\n' >"$CONNECT_WORK_TAILSCALE_TEST_ROOT/etc/os-release"

  local tool
  for tool in env install jq mktemp rm seq sleep; do
    ln -s "$(command -v "$tool")" "$REAL_TOOLS/$tool"
  done

  cat >"$STUBS/sudo" <<'STUB'
set -euo pipefail
printf 'sudo %s\n' "$*" >>"$CALLS"
AS_ROOT=1 exec "$@"
STUB
  cat >"$STUBS/curl" <<'STUB'
set -euo pipefail
printf 'curl %s\n' "$*" >>"$CALLS"
dest=; url=
while (($#)); do
  [[ "$1" != -o ]] || dest="$2"
  url="$1"
  shift
done
printf 'fixture for %s\n' "$url" >"$dest"
STUB
  cat >"$STUBS/apt-get" <<'STUB'
set -euo pipefail
printf 'apt-get %s\n' "$*" >>"$CALLS"
case "$*" in
  update) ;;
  *'install -y tailscale')
    [[ -z "${APT_INSTALL_FAILS:-}" ]] || { printf 'E: Unable to locate package tailscale\n' >&2; exit 100; }
    cp "$STATE/tailscale-stub" "$(dirname "$0")/tailscale"
    ;;
  *) exit 64 ;;
esac
STUB
  cat >"$STATE/tailscale-stub" <<'STUB'
set -euo pipefail
printf 'tailscale %s\n' "$*" >>"$CALLS"
prefs="$STATE/prefs.json"
[[ -z "${DAEMON_DOWN:-}" ]] || { printf 'failed to connect to local tailscaled\n' >&2; exit 1; }
case "$1 ${2:-}" in
  'debug prefs') cat "$prefs" ;;
  'status --json') jq -c '{BackendState: $s}' --arg s "$(<"$STATE/backend")" -n ;;
  'set '*)
    shift
    if [[ -z "${AS_ROOT:-}" && "$(jq -r .OperatorUser "$prefs")" != "$USER" ]]; then
      printf 'Access denied: checkprefs access denied\n' >&2
      exit 1
    fi
    for arg; do
      case "$arg" in
        --operator=*) jq --arg v "${arg#*=}" '.OperatorUser = $v' "$prefs" >"$prefs.new" ;;
        --accept-routes) jq '.RouteAll = true' "$prefs" >"$prefs.new" ;;
        --accept-dns) jq '.CorpDNS = true' "$prefs" >"$prefs.new" ;;
        --shields-up) jq '.ShieldsUp = true' "$prefs" >"$prefs.new" ;;
        *) exit 64 ;;
      esac
      mv "$prefs.new" "$prefs"
    done
    ;;
  *) exit 64 ;;
esac
STUB
  local stub
  for stub in "$STUBS"/* "$STATE/tailscale-stub"; do
    sed -i "1i #!$REAL_BASH" "$stub"
  done
  chmod +x "$STUBS"/* "$STATE/tailscale-stub"
  # The stubs call mv, cat, cp and dirname outside the script's own PATH needs.
  for tool in cat cp dirname mv; do
    ln -s "$(command -v "$tool")" "$REAL_TOOLS/$tool"
  done

  write_state '' false false false NeedsLogin
}

write_state() {
  local operator="$1" routes="$2" dns="$3" shields="$4" backend="$5"
  jq -n --arg o "$operator" --argjson r "$routes" --argjson d "$dns" --argjson s "$shields" \
    '{OperatorUser: $o, RouteAll: $r, CorpDNS: $d, ShieldsUp: $s, ExitNodeID: ""}' >"$STATE/prefs.json"
  printf '%s\n' "$backend" >"$STATE/backend"
}

install_tailscale_stub() {
  cp "$STATE/tailscale-stub" "$STUBS/tailscale"
}

run_connect() {
  run --separate-stderr env PATH="$STUBS:$REAL_TOOLS" "$REAL_BASH" "$SCRIPT"
}

calls() {
  sed -E "s|$BATS_TEST_TMPDIR/tmp\.[[:alnum:]]+|WORK|g; s|$CONNECT_WORK_TAILSCALE_TEST_ROOT|ROOT|g" "$CALLS"
}

@test "test_fresh_install_adds_the_apt_repo_installs_then_converges_prefs" {
  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = "$SIGN_IN" ]
  [ "$stderr" = '' ]
  diff -u - <(calls) <<CALLS
curl $CURL_FLAGS -o WORK/keyring.gpg $BASE_URL.noarmor.gpg
curl $CURL_FLAGS -o WORK/tailscale.list $BASE_URL.tailscale-keyring.list
sudo install -D -m 0644 WORK/keyring.gpg ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg
sudo install -D -m 0644 WORK/tailscale.list ROOT/etc/apt/sources.list.d/tailscale.list
sudo apt-get update
apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y tailscale
apt-get -o DPkg::Lock::Timeout=600 install -y tailscale
tailscale debug prefs
sudo tailscale set --operator=tester
tailscale set --operator=tester
tailscale set --accept-routes --accept-dns --shields-up
tailscale status --json
CALLS
  grep -qF "fixture for $BASE_URL.noarmor.gpg" \
    "$CONNECT_WORK_TAILSCALE_TEST_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
  grep -qF "fixture for $BASE_URL.tailscale-keyring.list" \
    "$CONNECT_WORK_TAILSCALE_TEST_ROOT/etc/apt/sources.list.d/tailscale.list"
  [ "$(stat -c %a "$CONNECT_WORK_TAILSCALE_TEST_ROOT/etc/apt/sources.list.d/tailscale.list")" = 644 ]
  [ "$(jq -c '[.OperatorUser, .RouteAll, .CorpDNS, .ShieldsUp]' "$STATE/prefs.json")" = '["tester",true,true,true]' ]
  ! compgen -G "$BATS_TEST_TMPDIR/tmp.*" >/dev/null || fail 'left a work directory behind'
}

@test "test_wrong_operator_takes_one_sudo_set_and_nothing_else" {
  install_tailscale_stub
  write_state root true true true Running

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
  diff -u - <(calls) <<'CALLS'
tailscale debug prefs
sudo tailscale set --operator=tester
tailscale set --operator=tester
tailscale status --json
CALLS
}

@test "test_pref_drift_is_reset_as_the_user_without_touching_the_exit_node" {
  install_tailscale_stub
  write_state tester true false true Running
  jq '.ExitNodeID = "nodeid-exit"' "$STATE/prefs.json" >"$STATE/prefs.new"
  mv "$STATE/prefs.new" "$STATE/prefs.json"

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  diff -u - <(calls) <<'CALLS'
tailscale debug prefs
tailscale set --accept-routes --accept-dns --shields-up
tailscale status --json
CALLS
  [ "$(jq -r .ExitNodeID "$STATE/prefs.json")" = nodeid-exit ]
}

@test "test_converged_running_node_makes_no_sudo_or_set_call_and_prints_nothing" {
  install_tailscale_stub
  write_state tester true true true Running

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
  diff -u - <(calls) <<'CALLS'
tailscale debug prefs
tailscale status --json
CALLS
}

@test "test_needs_login_prints_the_full_sign_in_command" {
  install_tailscale_stub
  write_state tester true true true NeedsLogin

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = "$SIGN_IN" ]
  [ "$stderr" = '' ]
}

@test "test_stopped_node_is_left_silent" {
  install_tailscale_stub
  write_state tester true true true Stopped

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
}

@test "test_unreachable_daemon_fails_naming_the_service" {
  install_tailscale_stub

  DAEMON_DOWN=1 run_connect

  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  [ "$stderr" = 'connect-work-tailscale: error: tailscaled is not reachable; check systemctl status tailscaled' ]
}

@test "test_apt_install_failure_says_to_rerun_apply" {
  APT_INSTALL_FAILS=1 run_connect

  [ "$status" -eq 1 ]
  [[ "$stderr" == *'connect-work-tailscale: error: cannot install tailscale with apt-get; rerun chezmoi apply to retry' ]]
  [ ! -e "$STUBS/tailscale" ]
}
