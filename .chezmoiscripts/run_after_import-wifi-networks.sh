#!/usr/bin/env bash
set -euo pipefail
umask 077

# One Bitwarden login item per saved network, named dotfiles/wifi/<SSID>, with
# the password in Password, a key_mgmt field (wpa-psk, sae, or none), and an
# optional hidden=true field. A password only ever travels through variables,
# builtins, and files in the runtime directory, never a command line.
readonly prefix='dotfiles/wifi/'
readonly connections_dir=/etc/NetworkManager/system-connections
readonly state_file="${XDG_STATE_HOME:-$HOME/.local/state}/import-wifi-networks/imported"
readonly wifi_sync="$HOME/.local/bin/wifi-sync"

status=0

say_error() {
  printf 'import-wifi-networks: error: %s\n' "$*" >&2
  status=1
}

items="$(bw list items --search "$prefix" | jq --arg prefix "$prefix" '[.[] | select(.name | startswith($prefix))]')"
count="$(jq length <<<"$items")"

if ! command -v nmcli >/dev/null 2>&1; then
  ((count == 0)) && exit 0
  printf 'import-wifi-networks: error: nmcli is not installed; install NetworkManager to import the saved Wi-Fi networks\n' >&2
  exit 1
fi

duplicates="$(jq -r 'group_by(.name) | map(select(length > 1) | .[0].name) | join(", ")' <<<"$items")"
if [[ -n "$duplicates" ]]; then
  printf 'import-wifi-networks: error: more than one Bitwarden item is named %s; keep one\n' "$duplicates" >&2
  exit 1
fi

dir="$(mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/import-wifi-networks.XXXXXX")"
trap 'rm -rf "$dir"' EXIT

local_networks="$(bash "$wifi_sync" local-json)"

# GKeyFile values: backslash, control characters, and leading spaces need escapes.
escape_keyfile_value() {
  local value="$1" lead=''
  value="${value//\\/\\\\}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\r'/\\r}"
  while [[ "$value" == ' '* ]]; do
    lead+='\s'
    value="${value# }"
  done
  printf '%s%s' "$lead" "$value"
}

remember() {
  { grep -v "^$1 " "$state_file" 2>/dev/null || true; printf '%s %s\n' "$1" "$2"; } >"$state_file.new"
  mv "$state_file.new" "$state_file"
}

import_item() {
  local item="$1" id revision ssid hidden key_mgmt password file target uuid line default_key_mgmt=none
  id="$(jq -r .id <<<"$item")"
  revision="$(jq -r .revisionDate <<<"$item")"
  ssid="$(jq -r --arg prefix "$prefix" '.name | ltrimstr($prefix)' <<<"$item")"
  hidden="$(jq -r '[.fields[]? | select(.name == "hidden") | .value] | first // "" | ascii_downcase' <<<"$item")"
  password="$(jq -r '.login.password // ""' <<<"$item")"
  [[ -z "$password" ]] || default_key_mgmt=wpa-psk
  key_mgmt="$(jq -r --arg default "$default_key_mgmt" '[.fields[]? | select(.name == "key_mgmt") | .value] | first // $default' <<<"$item")"

  case "$key_mgmt" in
    wpa-psk | sae)
      [[ -n "$password" ]] || { say_error "Bitwarden item $prefix$ssid is $key_mgmt but has no Password"; return; }
      ;;
    none)
      [[ -z "$password" ]] || { say_error "Bitwarden item $prefix$ssid is open (key_mgmt none) but has a Password"; return; }
      ;;
    *)
      say_error "Bitwarden item $prefix$ssid has key_mgmt $key_mgmt; use wpa-psk, sae, or none"
      return
      ;;
  esac

  if grep -qx "$id $revision" "$state_file" 2>/dev/null \
    && jq -e --arg id "$id" 'any(.[]; .uuid == $id)' <<<"$local_networks" >/dev/null; then
    return
  fi

  # nmcli writes the non-secret keyfile and escapes the SSID itself. The
  # connection takes the item's UUID, so a re-import replaces it in place.
  local args=(type wifi con-name "$ssid" ssid "$ssid" connection.uuid "$id")
  [[ "$key_mgmt" == none ]] || args+=(wifi-sec.key-mgmt "$key_mgmt")
  [[ "$hidden" != true ]] || args+=(802-11-wireless.hidden yes)
  nmcli --offline connection add "${args[@]}" >"$dir/base"

  file="$dir/$id.nmconnection"
  : >"$file"
  while IFS= read -r line; do
    printf '%s\n' "$line" >>"$file"
    if [[ "$line" == key-mgmt=* ]]; then
      printf 'psk=%s\n' "$(escape_keyfile_value "$password")" >>"$file"
    fi
  done <"$dir/base"

  target="$connections_dir/dotfiles-wifi-$id.nmconnection"
  sudo install -m 0600 -o root -g root "$file" "$target"
  if ! sudo nmcli connection load "$target" >/dev/null; then
    sudo rm -f "$target"
    say_error "NetworkManager rejected the profile of $prefix$ssid"
    return
  fi
  rm -f "$file" "$dir/base"

  # Same-SSID profiles from the GUI, possibly with an old password, go last so
  # a failed import never leaves the machine without the network.
  for uuid in $(jq -r --arg id "$id" --arg ssid "$ssid" '.[] | select(.ssid == $ssid and .uuid != $id) | .uuid' <<<"$local_networks"); do
    sudo nmcli connection delete uuid "$uuid" >/dev/null
  done

  mkdir -p "${state_file%/*}"
  remember "$id" "$revision"
  printf 'import-wifi-networks: imported the %s network from Bitwarden item %s%s\n' "$ssid" "$prefix" "$ssid"
}

while IFS= read -r item; do
  import_item "$item"
done < <(jq -c '.[]' <<<"$items")

bash "$wifi_sync" remind
exit "$status"
