#!/usr/bin/env bats
set -euo pipefail

# Covers the apply script that imports dotfiles/wifi/* Bitwarden items into
# NetworkManager and the wifi-sync command that saves networks the other way.
# bw, nmcli, and sudo are stateful stubs; every real tool the scripts call
# records its argv, so a test can prove a password never reached a command line.

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

REAL_BASH="$(command -v bash)"
SCRIPT_TOOL="$(command -v script)"
readonly REAL_BASH SCRIPT_TOOL
readonly APPLY="$REPO_ROOT/.chezmoiscripts/run_after_import-wifi-networks.sh"
readonly WIFI_SYNC="$REPO_ROOT/dot_local/bin/executable_wifi-sync"
readonly NM_DIR=/etc/NetworkManager/system-connections
readonly PSK='FIXTURE-PSK-DO-NOT-PRINT'
readonly PSK_OTHER='FIXTURE-OTHER-PSK-DO-NOT-PRINT'
readonly PSK_AWKWARD=' FIXTURE\lead;ing'
readonly ID_HOME=11111111-1111-4111-8111-111111111111
readonly ID_CAFE=22222222-2222-4222-8222-222222222222
readonly ID_OPEN=33333333-3333-4333-8333-333333333333

setup() {
  bats_require_minimum_version 1.5.0
  export TMPDIR="$BATS_TEST_TMPDIR"
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg-state"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
  export STATE="$BATS_TEST_TMPDIR/stub-state"
  export CALLS="$BATS_TEST_TMPDIR/calls" REAL_TOOL_ARGV="$BATS_TEST_TMPDIR/tool-calls"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  REAL_TOOLS="$BATS_TEST_TMPDIR/real-tools"
  mkdir -p "$HOME/.local/bin" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$STATE/etc-nm" "$STUBS" "$REAL_TOOLS"
  cp "$WIFI_SYNC" "$HOME/.local/bin/wifi-sync"
  : >"$CALLS"
  : >"$REAL_TOOL_ARGV"
  printf '[]\n' >"$STATE/items.json"
  printf '[]\n' >"$STATE/connections.json"

  record_argv_of_real_tools awk base64 basename bash cat cp cut grep install jq mkdir mktemp mv rm sed sort stat tee tr

  cat >"$STUBS/bw" <<'STUB'
set -euo pipefail
printf 'bw %s\n' "$*" >>"$CALLS"
locked() { [[ -n "${BW_LOCKED:-}" && "${BW_SESSION:-}" != fixture-session ]]; }
case "$*" in
  'unlock --check') ! locked ;;
  'unlock --raw') printf 'fixture-session' ;;
  'login --check') [[ -z "${BW_LOGGED_OUT:-}" ]] ;;
  'login --raw') printf 'fixture-session' ;;
  'list items --search '*)
    locked && { printf 'Vault is locked.\n' >&2; exit 1; }
    jq --arg search "$4" '[.[] | select(.name | contains($search))]' "$STATE/items.json"
    ;;
  'get template item')
    printf '{"organizationId":null,"folderId":null,"type":1,"reprompt":0,"name":"Item name","notes":"Some notes","favorite":false,"fields":[],"login":null}\n'
    ;;
  'get item '*)
    jq -c --arg id "${3}" '.[] | select(.id == $id)' "$STATE/items.json"
    ;;
  encode) base64 -w0 ;;
  'create item')
    base64 -d | tee "$STATE/created.json" \
      | jq --arg id "created-$(jq length "$STATE/items.json")" '. + {id: $id, revisionDate: "2026-06-01T00:00:00.000Z"}' >"$STATE/created-with-id.json"
    jq --slurpfile item "$STATE/created-with-id.json" '. + $item' "$STATE/items.json" >"$STATE/items.json.new"
    mv "$STATE/items.json.new" "$STATE/items.json"
    ;;
  'edit item '*)
    base64 -d >"$STATE/edited.json"
    jq --arg id "${3}" --slurpfile item "$STATE/edited.json" 'map(if .id == $id then . + $item[0] else . end)' "$STATE/items.json" >"$STATE/items.json.new"
    mv "$STATE/items.json.new" "$STATE/items.json"
    ;;
  *) exit 64 ;;
esac
STUB
  cat >"$STUBS/sudo" <<'STUB'
set -euo pipefail
printf 'sudo %s\n' "$*" >>"$CALLS"
# The sandbox has no root: keep root-only paths under the stub state.
args=()
if [[ "$1" == install ]]; then
  shift
  args=(install)
  while (($#)); do
    case "$1" in
      -o | -g) shift 2 ;;
      *) args+=("${1/#\/etc\/NetworkManager\/system-connections/$STATE/etc-nm}"); shift ;;
    esac
  done
else
  for arg in "$@"; do
    args+=("${arg/#\/etc\/NetworkManager\/system-connections/$STATE/etc-nm}")
  done
fi
AS_ROOT=1 exec "${args[@]}"
STUB
  cat >"$STUBS/nmcli" <<'STUB'
set -euo pipefail
printf 'nmcli %s\n' "$*" >>"$CALLS"
conns="$STATE/connections.json"
require_root() {
  [[ -n "${AS_ROOT:-}" ]] || { printf 'Error: insufficient privileges.\n' >&2; exit 1; }
}
# Like nmcli -g, print nothing at all for an empty value.
show_property() {
  jq -r --arg uuid "$1" --arg prop "$2" '.[] | select(.uuid == $uuid) | {
    "802-11-wireless.ssid": .ssid, "802-11-wireless.mode": .mode,
    "802-11-wireless.hidden": (if .hidden then "yes" else "no" end),
    "802-11-wireless-security.key-mgmt": .key_mgmt, "802-11-wireless-security.psk": .psk}[$prop] | select(. != "")' "$conns"
}
unescape() {
  jq -Rr 'gsub("\\\\(?<c>.)"; ({"s": " ", "n": "\n", "t": "\t", "r": "\r", "\\": "\\"}[.c] // .c))'
}
case "$*" in
  '-e no -g UUID,TYPE connection show') jq -r '.[] | "\(.uuid):\(.type)"' "$conns" ;;
  '-e no -g 802-11-wireless'*' connection show uuid '*) show_property "${*: -1}" "$4" ;;
  '-e no -s -g 802-11-wireless-security.psk connection show uuid '*)
    require_root
    show_property "${*: -1}" "$5"
    ;;
  'connection delete uuid '*)
    require_root
    jq --arg uuid "$4" 'map(select(.uuid != $uuid))' "$conns" >"$conns.new"
    mv "$conns.new" "$conns"
    ;;
  'connection load '*)
    require_root
    file="$3"
    [[ -z "${LOAD_FAILS:-}" ]] || { printf 'Error: failed to load %s.\n' "$file" >&2; exit 1; }
    stat -c %a "$file" >"$STATE/load-mode"
    ssid="$(sed -n 's/^ssid=//p' "$file" | unescape | sed 's/\\;/;/g')"
    jq --arg uuid "$(sed -n 's/^uuid=//p' "$file")" --arg ssid "$ssid" \
      --arg hidden "$(sed -n 's/^hidden=//p' "$file")" --arg key_mgmt "$(sed -n 's/^key-mgmt=//p' "$file")" \
      --rawfile psk <(sed -n 's/^psk=//p' "$file" | unescape) \
      'map(select(.uuid != $uuid)) + [{uuid: $uuid, type: "802-11-wireless", ssid: $ssid, mode: "infrastructure",
        hidden: ($hidden == "true"), key_mgmt: $key_mgmt, psk: ($psk | rtrimstr("\n"))}]' "$conns" >"$conns.new"
    mv "$conns.new" "$conns"
    cp "$file" "$STATE/loaded.nmconnection"
    ;;
  '--offline connection add '*)
    shift 3
    declare -A p=()
    while (($#)); do p["$1"]="$2"; shift 2; done
    printf '[connection]\nid=%s\nuuid=%s\ntype=wifi\n\n[wifi]\n' "${p[con-name]}" "${p[connection.uuid]}"
    [[ "${p[802-11-wireless.hidden]:-}" != yes ]] || printf 'hidden=true\n'
    printf 'mode=infrastructure\nssid=%s\n\n' "${p[ssid]//;/\\\\;}"
    [[ -z "${p[wifi-sec.key-mgmt]:-}" ]] || printf '[wifi-security]\nkey-mgmt=%s\n\n' "${p[wifi-sec.key-mgmt]}"
    printf '[ipv4]\nmethod=auto\n\n[ipv6]\naddr-gen-mode=default\nmethod=auto\n\n[proxy]\n'
    ;;
  *) exit 64 ;;
esac
STUB
  sed -i "1i #!$REAL_BASH" "$STUBS/bw" "$STUBS/sudo" "$STUBS/nmcli"
  chmod +x "$STUBS"/* "$REAL_TOOLS"/*
}

record_argv_of_real_tools() {
  local tool
  for tool in "$@"; do
    cat >"$REAL_TOOLS/$tool" <<STUB
#!$REAL_BASH
printf '$tool %s\\n' "\$*" >>"\$REAL_TOOL_ARGV"
exec $(command -v "$tool") "\$@"
STUB
  done
}

# add_item <id> <ssid> <password> <revisionDate> [key_mgmt] [hidden]
add_item() {
  jq --arg id "$1" --arg ssid "$2" --arg password "$3" --arg revision "$4" --arg key_mgmt "${5:-}" --arg hidden "${6:-}" '
    . + [{id: $id, name: ("dotfiles/wifi/" + $ssid), revisionDate: $revision,
          login: {username: $ssid, password: (if $password == "" then null else $password end)},
          fields: ((if $key_mgmt == "" then [] else [{name: "key_mgmt", value: $key_mgmt}] end)
                 + (if $hidden == "" then [] else [{name: "hidden", value: $hidden}] end))}]' \
    "$STATE/items.json" >"$STATE/items.json.new"
  mv "$STATE/items.json.new" "$STATE/items.json"
}

# add_connection <uuid> <ssid> <key_mgmt> <psk> [mode] [hidden]
add_connection() {
  jq --arg uuid "$1" --arg ssid "$2" --arg key_mgmt "$3" --arg psk "$4" --arg mode "${5:-infrastructure}" --arg hidden "${6:-false}" '
    . + [{uuid: $uuid, type: "802-11-wireless", ssid: $ssid, mode: $mode, hidden: ($hidden == "true"),
          key_mgmt: $key_mgmt, psk: $psk}]' "$STATE/connections.json" >"$STATE/connections.json.new"
  mv "$STATE/connections.json.new" "$STATE/connections.json"
}

assert_no_secret_leak() {
  local secret
  for secret in "$PSK" "$PSK_OTHER" "$PSK_AWKWARD"; do
    ! grep -qF -- "$secret" <<<"$output${stderr:-}" || fail "a password reached stdout or stderr"
    ! grep -qF -- "$secret" "$CALLS" "$REAL_TOOL_ARGV" || fail "a password reached a command line"
  done
}

run_apply() {
  run --separate-stderr env PATH="$STUBS:$REAL_TOOLS" "$REAL_BASH" "$APPLY"
  assert_no_secret_leak
}

# Feed the answers to wifi-sync through a pty, since it refuses to run without one.
run_sync() {
  local answers="$1"
  # script ends the session when its input ends, so hold the pipe open until
  # wifi-sync has read every answer.
  # shellcheck disable=SC2016
  run "$REAL_BASH" -c '{ sleep 0.3; printf "%s\n" "$1"; sleep 0.7; } | "$2" -qec "env PATH=$3 $4 $5" /dev/null' \
    _ "$answers" "$SCRIPT_TOOL" "$STUBS:$REAL_TOOLS" "$REAL_BASH" "$HOME/.local/bin/wifi-sync"
  output="${output//$'\r'/}"
  assert_no_secret_leak
}

connection() {
  jq -c --arg ssid "$1" '[.[] | select(.ssid == $ssid)][0] // empty' "$STATE/connections.json"
}

keep_local_file() {
  printf '%s' "$XDG_STATE_HOME/wifi-sync/keep-local"
}

@test "test_first_apply_installs_the_profile_and_loads_it" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z

  run_apply

  [ "$status" -eq 0 ]
  [ "$output" = "import-wifi-networks: imported the Home Wi-Fi network from Bitwarden item dotfiles/wifi/Home Wi-Fi" ]
  [ "$stderr" = '' ]
  grep -qE "^sudo install -m 0600 -o root -g root $XDG_RUNTIME_DIR/import-wifi-networks\.[[:alnum:]]{6}/$ID_HOME\.nmconnection $NM_DIR/dotfiles-wifi-$ID_HOME\.nmconnection\$" "$CALLS"
  grep -qxF "sudo nmcli connection load $NM_DIR/dotfiles-wifi-$ID_HOME.nmconnection" "$CALLS"
  [ "$(<"$STATE/load-mode")" = 600 ]
  [ "$(stat -c %a "$STATE/etc-nm/dotfiles-wifi-$ID_HOME.nmconnection")" = 600 ]
  grep -qxF "psk=$PSK" "$STATE/loaded.nmconnection"
  run connection 'Home Wi-Fi'
  [ "$output" = "{\"uuid\":\"$ID_HOME\",\"type\":\"802-11-wireless\",\"ssid\":\"Home Wi-Fi\",\"mode\":\"infrastructure\",\"hidden\":false,\"key_mgmt\":\"wpa-psk\",\"psk\":\"$PSK\"}" ]
  [ "$(<"$XDG_STATE_HOME/import-wifi-networks/imported")" = "$ID_HOME 2026-01-01T00:00:00.000Z" ]
  [ "$(ls -A "$XDG_RUNTIME_DIR")" = '' ]
}

@test "test_state_file_holds_no_password_or_hash_of_one" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z

  run_apply

  [ "$status" -eq 0 ]
  run ! grep -qF "$PSK" "$XDG_STATE_HOME/import-wifi-networks/imported"
  run ! grep -qF "$(printf '%s' "$PSK" | sha256sum | cut -d ' ' -f 1)" "$XDG_STATE_HOME/import-wifi-networks/imported"
  [ "$(stat -c %a "$XDG_STATE_HOME/import-wifi-networks/imported")" = 600 ]
}

@test "test_unchanged_revision_leaves_networkmanager_alone" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  run_apply
  [ "$status" -eq 0 ]
  : >"$CALLS"

  run_apply

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
  run ! grep -q '^sudo' "$CALLS"
}

@test "test_changed_revision_replaces_the_password_in_place" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  run_apply
  [ "$status" -eq 0 ]
  printf '[]\n' >"$STATE/items.json"
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK_OTHER" 2026-02-01T00:00:00.000Z

  run_apply

  [ "$status" -eq 0 ]
  [ "$output" = "import-wifi-networks: imported the Home Wi-Fi network from Bitwarden item dotfiles/wifi/Home Wi-Fi" ]
  [ "$(jq length "$STATE/connections.json")" -eq 1 ]
  [ "$(connection 'Home Wi-Fi' | jq -r .psk)" = "$PSK_OTHER" ]
  [ "$(<"$XDG_STATE_HOME/import-wifi-networks/imported")" = "$ID_HOME 2026-02-01T00:00:00.000Z" ]
}

@test "test_connection_forgotten_out_of_band_is_imported_again" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  run_apply
  [ "$status" -eq 0 ]
  printf '[]\n' >"$STATE/connections.json"

  run_apply

  [ "$status" -eq 0 ]
  [ "$output" = "import-wifi-networks: imported the Home Wi-Fi network from Bitwarden item dotfiles/wifi/Home Wi-Fi" ]
  [ "$(connection 'Home Wi-Fi' | jq -r .uuid)" = "$ID_HOME" ]
}

@test "test_gui_duplicate_with_a_stale_password_is_deleted_after_the_import" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  add_connection gnome-home 'Home Wi-Fi' wpa-psk stale-password
  add_connection gnome-other 'Other Wi-Fi' wpa-psk "$PSK_OTHER"

  run_apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].uuid] | sort | join(",")' "$STATE/connections.json")" = "$ID_HOME,gnome-other" ]
  local load_line delete_line
  load_line="$(grep -n '^sudo nmcli connection load' "$CALLS" | cut -d : -f 1)"
  delete_line="$(grep -n '^sudo nmcli connection delete uuid gnome-home$' "$CALLS" | cut -d : -f 1)"
  ((load_line < delete_line))
}

@test "test_open_network_gets_no_security_section" {
  add_item "$ID_OPEN" 'Library' '' 2026-01-01T00:00:00.000Z none

  run_apply

  [ "$status" -eq 0 ]
  run ! grep -q 'wifi-security\|^psk=' "$STATE/loaded.nmconnection"
  [ "$(connection Library | jq -r .key_mgmt)" = '' ]
}

@test "test_item_without_a_key_mgmt_field_is_open_when_it_has_no_password" {
  add_item "$ID_OPEN" 'Library' '' 2026-01-01T00:00:00.000Z

  run_apply

  [ "$status" -eq 0 ]
  [ "$(connection Library | jq -r .uuid)" = "$ID_OPEN" ]
  run ! grep -q '^psk=' "$STATE/loaded.nmconnection"
}

@test "test_hidden_wpa3_network_keeps_both_fields" {
  add_item "$ID_CAFE" 'Back Room' "$PSK" 2026-01-01T00:00:00.000Z sae true

  run_apply

  [ "$status" -eq 0 ]
  grep -qx 'hidden=true' "$STATE/loaded.nmconnection"
  grep -qx 'key-mgmt=sae' "$STATE/loaded.nmconnection"
  [ "$(connection 'Back Room' | jq -r '[.hidden, .key_mgmt] | join(",")')" = 'true,sae' ]
}

@test "test_ssid_with_spaces_and_a_semicolon_survives_the_keyfile" {
  add_item "$ID_CAFE" 'Cafe; Wi Fi' "$PSK" 2026-01-01T00:00:00.000Z

  run_apply

  [ "$status" -eq 0 ]
  [ "$(connection 'Cafe; Wi Fi' | jq -r .uuid)" = "$ID_CAFE" ]
  grep -qxF 'id=Cafe; Wi Fi' "$STATE/loaded.nmconnection"
  grep -qxF 'ssid=Cafe\\; Wi Fi' "$STATE/loaded.nmconnection"
}

@test "test_password_with_a_backslash_and_a_leading_space_is_escaped_in_the_keyfile" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK_AWKWARD" 2026-01-01T00:00:00.000Z

  run_apply

  [ "$status" -eq 0 ]
  grep -qxF 'psk=\sFIXTURE\\lead;ing' "$STATE/loaded.nmconnection"
  [ "$(connection 'Home Wi-Fi' | jq -r .psk)" = "$PSK_AWKWARD" ]
}

@test "test_reminder_names_only_undecided_networks" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  add_connection gnome-hotel 'Hotel' wpa-psk "$PSK_OTHER"
  add_connection gnome-kept 'Kept' wpa-psk "$PSK_OTHER"
  add_connection gnome-hotspot 'My Hotspot' wpa-psk "$PSK_OTHER" ap
  add_connection gnome-work 'Work' wpa-eap ''
  mkdir -p "$XDG_STATE_HOME/wifi-sync"
  printf '"Kept"\n' >"$(keep_local_file)"

  run_apply

  [ "$status" -eq 0 ]
  [ "$output" = "import-wifi-networks: imported the Home Wi-Fi network from Bitwarden item dotfiles/wifi/Home Wi-Fi
wifi-sync: Wi-Fi networks on this machine that are not in Bitwarden: Hotel, Work. Run wifi-sync to save, keep, or forget them." ]
}

@test "test_no_reminder_when_every_network_is_decided" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  run_apply
  [ "$status" -eq 0 ]

  run_apply

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
}

@test "test_no_items_and_no_nmcli_exits_quietly" {
  rm "$STUBS/nmcli"

  run_apply

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
}

@test "test_items_without_nmcli_fail" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  rm "$STUBS/nmcli"

  run_apply

  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  [ "$stderr" = 'import-wifi-networks: error: nmcli is not installed; install NetworkManager to import the saved Wi-Fi networks' ]
}

@test "test_duplicate_item_names_fail_before_touching_networkmanager" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  add_item "$ID_CAFE" 'Home Wi-Fi' "$PSK_OTHER" 2026-01-01T00:00:00.000Z

  run_apply

  [ "$status" -eq 1 ]
  [ "$stderr" = 'import-wifi-networks: error: more than one Bitwarden item is named dotfiles/wifi/Home Wi-Fi; keep one' ]
  run ! grep -q '^sudo' "$CALLS"
}

@test "test_other_items_are_not_mistaken_for_wifi_items" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  jq '. + [{id: "x", name: "other/dotfiles/wifi/Decoy", revisionDate: "r", login: {password: "p"}, fields: []}]' \
    "$STATE/items.json" >"$STATE/items.json.new"
  mv "$STATE/items.json.new" "$STATE/items.json"

  run_apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].ssid] | join(",")' "$STATE/connections.json")" = 'Home Wi-Fi' ]
}

@test "test_bad_items_fail_but_good_items_still_import" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  add_item "$ID_CAFE" 'Weird' "$PSK" 2026-01-01T00:00:00.000Z wpa-eap
  add_item "$ID_OPEN" 'Empty' '' 2026-01-01T00:00:00.000Z wpa-psk

  run_apply

  [ "$status" -eq 1 ]
  [ "$(jq -r '[.[].ssid] | join(",")' "$STATE/connections.json")" = 'Home Wi-Fi' ]
  grep -qxF 'import-wifi-networks: error: Bitwarden item dotfiles/wifi/Weird has key_mgmt wpa-eap; use wpa-psk, sae, or none' <<<"$stderr"
  grep -qxF 'import-wifi-networks: error: Bitwarden item dotfiles/wifi/Empty is wpa-psk but has no Password' <<<"$stderr"
}

@test "test_rejected_profile_is_removed_and_retried_by_the_next_apply" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  add_connection gnome-home 'Home Wi-Fi' wpa-psk stale-password

  LOAD_FAILS=1 run_apply

  [ "$status" -eq 1 ]
  [ "$stderr" = "Error: failed to load $STATE/etc-nm/dotfiles-wifi-$ID_HOME.nmconnection.
import-wifi-networks: error: NetworkManager rejected the profile of dotfiles/wifi/Home Wi-Fi" ]
  [ ! -e "$STATE/etc-nm/dotfiles-wifi-$ID_HOME.nmconnection" ]
  [ ! -e "$XDG_STATE_HOME/import-wifi-networks/imported" ]
  [ "$(connection 'Home Wi-Fi' | jq -r .uuid)" = gnome-home ]

  run_apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].uuid] | join(",")' "$STATE/connections.json")" = "$ID_HOME" ]
}

@test "test_wifi_sync_refuses_to_run_without_a_terminal" {
  add_connection gnome-hotel 'Hotel' wpa-psk "$PSK"

  run --separate-stderr env PATH="$STUBS:$REAL_TOOLS" "$REAL_BASH" "$HOME/.local/bin/wifi-sync" </dev/null

  [ "$status" -eq 1 ]
  [ "$stderr" = 'wifi-sync: error: wifi-sync asks questions, so run it in a terminal' ]
  run ! grep -q '^sudo' "$CALLS"
}

@test "test_wifi_sync_saves_a_network_with_the_password_on_stdin_only" {
  add_connection gnome-hotel 'Hotel' wpa-psk "$PSK"

  run_sync 's'

  [ "$status" -eq 0 ]
  [[ "$output" == *'Hotel (wpa-psk)'* ]]
  [[ "$output" == *'Saved Hotel to Bitwarden; the next chezmoi apply adopts it.'* ]]
  diff -u - <(jq -S . "$STATE/created.json") < <(jq -S -n --arg psk "$PSK" '{
    organizationId: null, folderId: null, type: 1, reprompt: 0, name: "dotfiles/wifi/Hotel", notes: null, favorite: false,
    fields: [{name: "key_mgmt", value: "wpa-psk", type: 0}],
    login: {username: "Hotel", password: $psk, uris: []}}')
  grep -qxF 'sudo nmcli -e no -s -g 802-11-wireless-security.psk connection show uuid gnome-hotel' "$CALLS"
}

@test "test_wifi_sync_saves_a_hidden_wpa3_network_with_both_fields" {
  add_connection gnome-back 'Back Room' sae "$PSK" infrastructure true

  run_sync 's'

  [ "$status" -eq 0 ]
  [ "$(jq -c '.fields' "$STATE/created.json")" = '[{"name":"key_mgmt","value":"sae","type":0},{"name":"hidden","value":"true","type":0}]' ]
  [ "$(jq -r '.login.password' "$STATE/created.json")" = "$PSK" ]
}

@test "test_wifi_sync_saves_an_open_network_without_a_password" {
  add_connection gnome-library 'Library' '' ''

  run_sync 's'

  [ "$status" -eq 0 ]
  [ "$(jq -c '[.name, .login.username, .login.password, .fields[0].value]' "$STATE/created.json")" = '["dotfiles/wifi/Library","Library",null,"none"]' ]
}

@test "test_wifi_sync_cannot_save_a_network_whose_password_is_not_in_networkmanager" {
  add_connection gnome-hotel 'Hotel' wpa-psk ''

  run_sync 's'

  [ "$status" -eq 0 ]
  [[ "$output" == *'NetworkManager holds no password for Hotel, so it cannot be saved from here.'* ]]
  [ ! -e "$STATE/created.json" ]
}

@test "test_wifi_sync_keep_local_is_remembered_and_silences_the_reminder" {
  add_connection gnome-hotel 'Hotel; "Guest"' wpa-psk "$PSK"

  run_sync 'k'

  [ "$status" -eq 0 ]
  [ "$(<"$(keep_local_file)")" = '"Hotel; \"Guest\""' ]
  run env PATH="$STUBS:$REAL_TOOLS" "$REAL_BASH" "$HOME/.local/bin/wifi-sync" remind
  [ "$output" = '' ]

  run_sync ''

  [[ "$output" == *'Every Wi-Fi network on this machine is in Bitwarden or kept local.'* ]]
}

@test "test_wifi_sync_forget_deletes_the_connection" {
  add_connection gnome-hotel 'Hotel' wpa-psk "$PSK"
  add_connection gnome-home 'Home Wi-Fi' wpa-psk "$PSK_OTHER"
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK_OTHER" 2026-01-01T00:00:00.000Z

  run_sync 'f'

  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].uuid] | join(",")' "$STATE/connections.json")" = gnome-home ]
  grep -qxF 'sudo nmcli connection delete uuid gnome-hotel' "$CALLS"
  [ ! -e "$STATE/created.json" ]
}

@test "test_wifi_sync_later_changes_nothing_and_asks_again_next_time" {
  add_connection gnome-hotel 'Hotel' wpa-psk "$PSK"

  run_sync 'l'
  [ "$status" -eq 0 ]
  [ ! -e "$(keep_local_file)" ]
  [ "$(jq length "$STATE/connections.json")" -eq 1 ]

  run_sync 'l'
  [[ "$output" == *'Hotel (wpa-psk)'* ]]
}

@test "test_wifi_sync_offers_enterprise_networks_only_keep_or_later" {
  add_connection gnome-work 'Work' wpa-eap ''

  run_sync $'s\nf\nk'

  [ "$status" -eq 0 ]
  [[ "$output" == *'Work (enterprise): add it to Bitwarden by hand, wifi-sync cannot manage it'* ]]
  [ ! -e "$STATE/created.json" ]
  [ "$(jq length "$STATE/connections.json")" -eq 1 ]
  [ "$(<"$(keep_local_file)")" = '"Work"' ]
}

@test "test_wifi_sync_updates_the_item_when_the_local_password_differs" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  add_connection gnome-home 'Home Wi-Fi' wpa-psk "$PSK_OTHER"

  run_sync 'u'

  [ "$status" -eq 0 ]
  [[ "$output" == *'Home Wi-Fi: the password on this machine differs from its Bitwarden item'* ]]
  [ "$(jq -r '.[0].login.password' "$STATE/items.json")" = "$PSK_OTHER" ]
}

@test "test_wifi_sync_leaves_the_item_when_asked_to" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  add_connection gnome-home 'Home Wi-Fi' wpa-psk "$PSK_OTHER"

  run_sync 'l'

  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].login.password' "$STATE/items.json")" = "$PSK" ]
  [ ! -e "$STATE/edited.json" ]
}

@test "test_wifi_sync_says_nothing_when_the_passwords_match" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK" 2026-01-01T00:00:00.000Z
  add_connection gnome-home 'Home Wi-Fi' wpa-psk "$PSK"

  run_sync ''

  [ "$status" -eq 0 ]
  [[ "$output" != *'differs'* ]]
}

@test "test_wifi_sync_does_not_push_an_old_password_over_a_newer_item" {
  add_item "$ID_HOME" 'Home Wi-Fi' "$PSK_OTHER" 2026-02-01T00:00:00.000Z
  add_connection "$ID_HOME" 'Home Wi-Fi' wpa-psk "$PSK"
  mkdir -p "$XDG_STATE_HOME/import-wifi-networks"
  printf '%s 2026-01-01T00:00:00.000Z\n' "$ID_HOME" >"$XDG_STATE_HOME/import-wifi-networks/imported"

  run_sync 'u'

  [ "$status" -eq 0 ]
  [[ "$output" != *'differs'* ]]
  [ "$(jq -r '.[0].login.password' "$STATE/items.json")" = "$PSK_OTHER" ]
}

@test "test_wifi_sync_unlocks_a_locked_vault_itself" {
  add_connection gnome-hotel 'Hotel' wpa-psk "$PSK"

  BW_LOCKED=1 run_sync 'l'

  [ "$status" -eq 0 ]
  [[ "$output" == *'Hotel (wpa-psk)'* ]]
  grep -qxF 'bw unlock --raw' "$CALLS"
}

@test "test_wifi_sync_logs_in_when_bw_was_never_logged_in" {
  add_connection gnome-hotel 'Hotel' wpa-psk "$PSK"

  BW_LOCKED=1 BW_LOGGED_OUT=1 run_sync 'l'

  [ "$status" -eq 0 ]
  [[ "$output" == *'Hotel (wpa-psk)'* ]]
  grep -qxF 'bw login --raw' "$CALLS"
  ! grep -qxF 'bw unlock --raw' "$CALLS"
}

@test "test_wifi_sync_reminder_stays_silent_when_the_vault_is_locked" {
  add_connection gnome-hotel 'Hotel' wpa-psk "$PSK"

  BW_LOCKED=1 run --separate-stderr env PATH="$STUBS:$REAL_TOOLS" "$REAL_BASH" "$HOME/.local/bin/wifi-sync" remind

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
}
