#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

REAL_BASH="$(command -v bash)"
readonly REAL_BASH
readonly TEMPLATE="$REPO_ROOT/.chezmoiscripts/run_after_zz-connect-homelab-wireguard.sh.tmpl"
readonly ITEM=dotfiles/wireguard/laptop
readonly PRIVATE_KEY='FIXTURE-PRIVATE-KEY-DO-NOT-PRINT='
readonly PROFILE="[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.20.151.2/32
DNS = 10.20.151.1

[Peer]
PublicKey = FIXTURE-PEER-PUBLIC-KEY=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.test:51820"
readonly IMPORTED="[Interface]
DNS = 10.1.0.1, ~faviann.vms, ~proxmox.lan
PrivateKey = $PRIVATE_KEY
Address = 10.20.151.2/32

[Peer]
AllowedIPs = 10.1.0.0/18, 10.0.0.2/32
PublicKey = FIXTURE-PEER-PUBLIC-KEY=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.test:51820"
readonly IMPORTED_LINE='connect-homelab-wireguard: imported the wg-homelab connection from Bitwarden item dotfiles/wireguard/laptop'

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
  SCRIPT="$BATS_TEST_TMPDIR/connect-homelab-wireguard.sh"
  mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$STATE" "$STUBS" "$REAL_TOOLS"
  : >"$CALLS"
  : >"$REAL_TOOL_ARGV"
  printf 'uuid-wifi:Home Wi-Fi:wlp2s0\n' >"$STATE/connections"
  write_items "$ITEM" "$PROFILE" dotfiles/wireguard/laptop2 'decoy profile'

  chezmoi --config /dev/null --config-format toml \
    --persistent-state "$BATS_TEST_TMPDIR/chezmoistate.boltdb" \
    execute-template --override-data '{"chezmoi":{"hostname":"laptop"}}' \
    --file "$TEMPLATE" >"$SCRIPT"

  record_argv_of_real_tools awk basename cat cp cut grep jq mkdir mktemp mv rm sha256sum stat

  cat >"$STUBS/bw" <<'STUB'
set -euo pipefail
printf 'bw %s\n' "$*" >>"$CALLS"
case "$*" in
  'list items --search dotfiles/wireguard/laptop')
    [[ -z "${BW_LOCKED:-}" ]] || { printf 'Vault is locked.\n' >&2; exit 1; }
    cat "$STATE/items.json"
    ;;
  *) exit 64 ;;
esac
STUB
  cat >"$STUBS/sudo" <<'STUB'
set -euo pipefail
printf 'sudo %s\n' "$*" >>"$CALLS"
AS_ROOT=1 exec "$@"
STUB
  cat >"$STUBS/nmcli" <<'STUB'
set -euo pipefail
printf 'nmcli %s\n' "$*" >>"$CALLS"
connections="$STATE/connections"
require_root() {
  [[ -n "${AS_ROOT:-}" ]] || { printf 'Error: insufficient privileges.\n' >&2; exit 1; }
}
case "$*" in
  '-g UUID connection show') cut -d : -f 1 "$connections" ;;
  '-g connection.interface-name connection show uuid '*)
    awk -F : -v uuid="$6" '$1 == uuid { print $3; found = 1 } END { exit !found }' "$connections" \
      || { printf 'Error: %s - no such connection profile.\n' "$6" >&2; exit 10; }
    ;;
  'connection delete uuid '*)
    require_root
    grep -q "^$4:" "$connections" || { printf 'Error: unknown connection %s.\n' "$4" >&2; exit 10; }
    grep -v "^$4:" "$connections" >"$connections.new" || true
    mv "$connections.new" "$connections"
    ;;
  'connection import type wireguard file '*)
    require_root
    if [[ -n "${IMPORT_FAILS:-}" ]]; then
      printf 'Error: failed to import the connection.\n' >&2
      exit 1
    fi
    if cut -d : -f 3 "$connections" | grep -qx -- "$(basename "$6" .conf)"; then
      printf "Error: Failed to add 'wg-homelab' connection: Message recipient disconnected from message bus without replying\n" >&2
      exit 4
    fi
    printf '%s %s\n' "$(stat -c %a "$6")" "$(stat -c %a "${6%/*}")" >"$STATE/import-modes"
    cp "$6" "$STATE/imported.conf"
    imports=$(($(cat "$STATE/imports" 2>/dev/null || printf 0) + 1))
    printf '%s\n' "$imports" >"$STATE/imports"
    printf 'uuid-%s:%s:%s\n' "$imports" "$(basename "$6" .conf)" "$(basename "$6" .conf)" >>"$connections"
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

write_items() {
  jq -n '[range(0; $ARGS.positional | length; 2) as $i
    | {name: $ARGS.positional[$i], notes: $ARGS.positional[$i + 1]}]' \
    --args "$@" >"$STATE/items.json"
}

run_connect() {
  run --separate-stderr env PATH="$STUBS:$REAL_TOOLS" "$REAL_BASH" "$SCRIPT"
  ! grep -qF -- "$PRIVATE_KEY" <<<"$output$stderr" \
    || fail 'the private key reached stdout or stderr'
  ! grep -qF -- "$PRIVATE_KEY" "$CALLS" "$REAL_TOOL_ARGV" \
    || fail 'the private key reached a command line'
}

calls() {
  sed -E 's/connect-homelab-wireguard\.[[:alnum:]]{6}/connect-homelab-wireguard.XXXXXX/' "$CALLS"
}

@test "test_missing_item_leaves_networkmanager_alone" {
  write_items dotfiles/wireguard/laptop2 "$PROFILE"

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = 'connect-homelab-wireguard: no Bitwarden item dotfiles/wireguard/laptop; skipping the homelab tunnel' ]
  diff -u - <(calls) <<<'bw list items --search dotfiles/wireguard/laptop'
}

@test "test_first_apply_imports_the_profile_with_homelab_routes_and_dns" {
  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = "$IMPORTED_LINE" ]
  [ "$stderr" = '' ]
  diff -u - <(calls) <<CALLS
bw list items --search dotfiles/wireguard/laptop
nmcli -g UUID connection show
nmcli -g connection.interface-name connection show uuid uuid-wifi
sudo nmcli connection import type wireguard file $XDG_RUNTIME_DIR/connect-homelab-wireguard.XXXXXX/wg-homelab.conf
nmcli connection import type wireguard file $XDG_RUNTIME_DIR/connect-homelab-wireguard.XXXXXX/wg-homelab.conf
CALLS
  diff -u - "$STATE/imported.conf" <<<"$IMPORTED"
  [ "$(<"$STATE/import-modes")" = '600 700' ]
  [ "$(ls -A "$XDG_RUNTIME_DIR")" = '' ]
  diff -u - "$STATE/connections" <<'CONNECTIONS'
uuid-wifi:Home Wi-Fi:wlp2s0
uuid-1:wg-homelab:wg-homelab
CONNECTIONS
  local state_file="$XDG_STATE_HOME/connect-homelab-wireguard/profile.sha256"
  [ "$(<"$state_file")" = "$(sha256sum <<<"$IMPORTED" | cut -d ' ' -f 1)" ]
  [ "$(stat -c %a "$state_file")" = 600 ]
}

@test "test_unchanged_profile_leaves_the_connection_alone" {
  run_connect
  [ "$output" = "$IMPORTED_LINE" ]
  : >"$CALLS"

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
  diff -u - <(calls) <<'CALLS'
bw list items --search dotfiles/wireguard/laptop
nmcli -g UUID connection show
nmcli -g connection.interface-name connection show uuid uuid-wifi
nmcli -g connection.interface-name connection show uuid uuid-1
CALLS
}

@test "test_changed_profile_replaces_the_connection" {
  run_connect
  [ "$output" = "$IMPORTED_LINE" ]
  write_items "$ITEM" "[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.20.151.3/32
dns=9.9.9.9

[Peer]
PublicKey = FIXTURE-PEER-PUBLIC-KEY=
Endpoint = vpn.example.test:51820"
  : >"$CALLS"

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = "$IMPORTED_LINE" ]
  [ "$stderr" = '' ]
  diff -u - <(calls) <<CALLS
bw list items --search dotfiles/wireguard/laptop
nmcli -g UUID connection show
nmcli -g connection.interface-name connection show uuid uuid-wifi
nmcli -g connection.interface-name connection show uuid uuid-1
sudo nmcli connection delete uuid uuid-1
nmcli connection delete uuid uuid-1
sudo nmcli connection import type wireguard file $XDG_RUNTIME_DIR/connect-homelab-wireguard.XXXXXX/wg-homelab.conf
nmcli connection import type wireguard file $XDG_RUNTIME_DIR/connect-homelab-wireguard.XXXXXX/wg-homelab.conf
CALLS
  diff -u - "$STATE/imported.conf" <<IMPORTED
[Interface]
DNS = 10.1.0.1, ~faviann.vms, ~proxmox.lan
PrivateKey = $PRIVATE_KEY
Address = 10.20.151.3/32

[Peer]
AllowedIPs = 10.1.0.0/18, 10.0.0.2/32
PublicKey = FIXTURE-PEER-PUBLIC-KEY=
Endpoint = vpn.example.test:51820
IMPORTED
  diff -u - "$STATE/connections" <<'CONNECTIONS'
uuid-wifi:Home Wi-Fi:wlp2s0
uuid-2:wg-homelab:wg-homelab
CONNECTIONS
}

@test "test_connection_deleted_out_of_band_is_imported_again" {
  run_connect
  [ "$output" = "$IMPORTED_LINE" ]
  printf 'uuid-wifi:Home Wi-Fi:wlp2s0\n' >"$STATE/connections"
  : >"$CALLS"

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = "$IMPORTED_LINE" ]
  [ "$stderr" = '' ]
  diff -u - <(calls) <<CALLS
bw list items --search dotfiles/wireguard/laptop
nmcli -g UUID connection show
nmcli -g connection.interface-name connection show uuid uuid-wifi
sudo nmcli connection import type wireguard file $XDG_RUNTIME_DIR/connect-homelab-wireguard.XXXXXX/wg-homelab.conf
nmcli connection import type wireguard file $XDG_RUNTIME_DIR/connect-homelab-wireguard.XXXXXX/wg-homelab.conf
CALLS
  diff -u - "$STATE/connections" <<'CONNECTIONS'
uuid-wifi:Home Wi-Fi:wlp2s0
uuid-2:wg-homelab:wg-homelab
CONNECTIONS
}

@test "test_renamed_connection_is_replaced_when_the_profile_changes" {
  run_connect
  [ "$output" = "$IMPORTED_LINE" ]
  sed -i 's/^uuid-1:wg-homelab:/uuid-1:Homelab VPN:/' "$STATE/connections"
  write_items "$ITEM" "${PROFILE/10.20.151.2/10.20.151.3}"
  : >"$CALLS"

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = "$IMPORTED_LINE" ]
  [ "$stderr" = '' ]
  diff -u - "$STATE/connections" <<'CONNECTIONS'
uuid-wifi:Home Wi-Fi:wlp2s0
uuid-2:wg-homelab:wg-homelab
CONNECTIONS
}

@test "test_unchanged_profile_leaves_a_renamed_connection_alone" {
  run_connect
  [ "$output" = "$IMPORTED_LINE" ]
  sed -i 's/^uuid-1:wg-homelab:/uuid-1:Homelab VPN:/' "$STATE/connections"
  : >"$CALLS"

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = '' ]
  [ "$stderr" = '' ]
  diff -u - <(calls) <<'CALLS'
bw list items --search dotfiles/wireguard/laptop
nmcli -g UUID connection show
nmcli -g connection.interface-name connection show uuid uuid-wifi
nmcli -g connection.interface-name connection show uuid uuid-1
CALLS
  diff -u - "$STATE/connections" <<'CONNECTIONS'
uuid-wifi:Home Wi-Fi:wlp2s0
uuid-1:Homelab VPN:wg-homelab
CONNECTIONS
}

@test "test_every_connection_on_the_interface_is_replaced" {
  printf 'uuid-wifi:Home Wi-Fi:wlp2s0\nuuid-foo:foo:wg-homelab\nuuid-old:Homelab VPN:wg-homelab\n' >"$STATE/connections"

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = "$IMPORTED_LINE" ]
  [ "$stderr" = '' ]
  diff -u - <(calls) <<CALLS
bw list items --search dotfiles/wireguard/laptop
nmcli -g UUID connection show
nmcli -g connection.interface-name connection show uuid uuid-wifi
nmcli -g connection.interface-name connection show uuid uuid-foo
nmcli -g connection.interface-name connection show uuid uuid-old
sudo nmcli connection delete uuid uuid-foo
nmcli connection delete uuid uuid-foo
sudo nmcli connection delete uuid uuid-old
nmcli connection delete uuid uuid-old
sudo nmcli connection import type wireguard file $XDG_RUNTIME_DIR/connect-homelab-wireguard.XXXXXX/wg-homelab.conf
nmcli connection import type wireguard file $XDG_RUNTIME_DIR/connect-homelab-wireguard.XXXXXX/wg-homelab.conf
CALLS
  diff -u - "$STATE/connections" <<'CONNECTIONS'
uuid-wifi:Home Wi-Fi:wlp2s0
uuid-1:wg-homelab:wg-homelab
CONNECTIONS
}

@test "test_connection_named_wg_homelab_on_another_interface_is_kept" {
  printf 'uuid-wifi:Home Wi-Fi:wlp2s0\nuuid-wg0:wg-homelab:wg0\n' >"$STATE/connections"

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = "$IMPORTED_LINE" ]
  diff -u - "$STATE/connections" <<'CONNECTIONS'
uuid-wifi:Home Wi-Fi:wlp2s0
uuid-wg0:wg-homelab:wg0
uuid-1:wg-homelab:wg-homelab
CONNECTIONS
}

@test "test_failed_import_is_retried_by_the_next_apply" {
  IMPORT_FAILS=1 run_connect

  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  [ "$stderr" = 'Error: failed to import the connection.' ]
  [ ! -e "$XDG_STATE_HOME/connect-homelab-wireguard/profile.sha256" ]
  [ "$(ls -A "$XDG_RUNTIME_DIR")" = '' ]

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = "$IMPORTED_LINE" ]
}

@test "test_duplicate_items_fail_without_touching_networkmanager" {
  write_items "$ITEM" "$PROFILE" "$ITEM" "$PROFILE"

  run_connect

  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  [ "$stderr" = 'connect-homelab-wireguard: error: 2 Bitwarden items are named dotfiles/wireguard/laptop; keep one' ]
  diff -u - <(calls) <<<'bw list items --search dotfiles/wireguard/laptop'
}

@test "test_locked_vault_fails_with_the_bitwarden_error" {
  BW_LOCKED=1 run_connect

  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  [ "$stderr" = 'Vault is locked.' ]
  diff -u - <(calls) <<<'bw list items --search dotfiles/wireguard/laptop'
}

@test "test_missing_nmcli_fails_once_the_item_exists" {
  rm "$STUBS/nmcli"

  run_connect

  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  [ "$stderr" = 'connect-homelab-wireguard: error: nmcli is not installed; install NetworkManager to bring up the homelab tunnel' ]
  diff -u - <(calls) <<<'bw list items --search dotfiles/wireguard/laptop'
}

@test "test_malformed_profile_fails_and_keeps_the_existing_connection" {
  run_connect
  [ "$output" = "$IMPORTED_LINE" ]
  : >"$CALLS"

  local notes
  for notes in '' "$PRIVATE_KEY" "[Interface]
PrivateKey = $PRIVATE_KEY"; do
    write_items "$ITEM" "$notes"

    run_connect

    [ "$status" -eq 1 ]
    [ "$output" = '' ]
    [ "$stderr" = 'connect-homelab-wireguard: error: the Notes of Bitwarden item dotfiles/wireguard/laptop must hold a WireGuard profile with one [Interface] and one [Peer] section' ]
  done
  jq '.[0].notes = null' "$STATE/items.json" >"$STATE/items.json.new"
  mv "$STATE/items.json.new" "$STATE/items.json"
  run_connect
  [ "$status" -eq 1 ]

  run ! grep -q '^sudo' "$CALLS"
  diff -u - "$STATE/connections" <<'CONNECTIONS'
uuid-wifi:Home Wi-Fi:wlp2s0
uuid-1:wg-homelab:wg-homelab
CONNECTIONS
}

@test "test_windows_line_endings_are_imported_as_unix_lines" {
  write_items "$ITEM" "${PROFILE//$'\n'/$'\r\n'}"

  run_connect

  [ "$status" -eq 0 ]
  [ "$output" = "$IMPORTED_LINE" ]
  diff -u - "$STATE/imported.conf" <<<"$IMPORTED"
}
