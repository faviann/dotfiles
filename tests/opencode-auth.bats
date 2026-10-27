#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

readonly KEY='fixture-opencode-key-0123456789'
readonly AUTH=.local/share/opencode/auth.json

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  export ITEM="$BATS_TEST_TMPDIR/item.json"
  local bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$bin"
  cat >"$bin/bw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == 'get item dotfiles/opencode-api-key' ]] || exit 64
cat "$ITEM"
STUB
  sed -i "1c #!$(command -v bash)" "$bin/bw"
  chmod +x "$bin/bw"
  export PATH="$bin:$PATH"
  write_item "$KEY"
}

write_item() {
  jq -n --arg notes "$1" '{name: "dotfiles/opencode-api-key", notes: $notes}' >"$ITEM"
}

run_chezmoi() {
  local profile="$1"
  local home="$2"
  local runtime_dir="$BATS_TEST_TMPDIR/runtime"
  shift 2

  mkdir -p "$home" "$runtime_dir"
  HOME="$home" \
  XDG_CACHE_HOME="$runtime_dir/cache" \
  XDG_CONFIG_HOME="$runtime_dir/config" \
  XDG_STATE_HOME="$runtime_dir/state" \
    chezmoi \
    --source "$REPO_ROOT" \
    --destination "$home" \
    --config /dev/null \
    --config-format toml \
    --persistent-state "$runtime_dir/chezmoistate.boltdb" \
    --override-data "{\"profile\":\"$profile\"}" \
    "$@"
}

apply_auth() {
  local profile="$1"
  local home="$2"

  run_chezmoi "$profile" "$home" apply --force --recursive=false \
    "$home/.local" "$home/.local/share" "$home/.local/share/opencode" "$home/$AUTH"
}

@test "test_opencode_key_renders_into_a_new_owner_only_auth_file_on_every_profile" {
  local profile
  local home

  for profile in workstation desktop; do
    home="$BATS_TEST_TMPDIR/$profile"
    mkdir -p "$home/.local/share/opencode"
    chmod 775 "$home/.local/share" "$home/.local/share/opencode"

    apply_auth "$profile" "$home"

    cmp -s "$home/$AUTH" \
      <(printf '{\n  "opencode": {\n    "key": "%s",\n    "type": "api"\n  }\n}\n' "$KEY") \
      || fail "$profile: auth.json is not the opencode entry alone: $(cat "$home/$AUTH")"
    [[ "$(stat -c %a "$home/.local/share" "$home/.local/share/opencode" "$home/$AUTH")" \
      == $'700\n700\n600' ]] || fail "$profile: auth.json or its directories are not owner-only"
  done
}

@test "test_opencode_key_replaces_a_stale_key_and_keeps_other_providers" {
  local home="$BATS_TEST_TMPDIR/home"

  mkdir -p "$home/.local/share/opencode"
  cat >"$home/$AUTH" <<'EOF'
{
  "anthropic": {"type": "oauth", "refresh": "fixture-refresh", "access": "fixture-access", "expires": 1730000000000},
  "opencode": {"type": "api", "key": "stale-key", "extra": true}
}
EOF

  apply_auth desktop "$home"

  [[ "$(jq -c . "$home/$AUTH")" == '{"anthropic":{"access":"fixture-access","expires":1730000000000,"refresh":"fixture-refresh","type":"oauth"},"opencode":{"key":"'"$KEY"'","type":"api"}}' ]] \
    || fail "auth.json lost another provider or kept the stale key: $(jq -c . "$home/$AUTH")"
}

opencode_formatted_auth() {
  printf '{\n  "anthropic": {\n    "type": "oauth",\n    "refresh": "fixture-refresh"\n  },\n  "opencode": {\n    "type": "api",\n    "key": "%s"\n  }\n}' "$1"
}

@test "test_current_key_keeps_opencode_formatting_and_a_stale_key_rewrites_it" {
  local home="$BATS_TEST_TMPDIR/home"

  mkdir -p "$home/.local/share/opencode"
  opencode_formatted_auth "$KEY" >"$home/$AUTH"
  apply_auth workstation "$home"
  cmp -s "$home/$AUTH" <(opencode_formatted_auth "$KEY") \
    || fail "apply rewrote an auth.json that already holds the key: $(cat "$home/$AUTH")"

  opencode_formatted_auth stale-key >"$home/$AUTH"
  apply_auth workstation "$home"
  cmp -s "$home/$AUTH" <(printf '{\n  "anthropic": {\n    "refresh": "fixture-refresh",\n    "type": "oauth"\n  },\n  "opencode": {\n    "key": "%s",\n    "type": "api"\n  }\n}\n' "$KEY") \
    || fail "a stale key did not render the sorted form: $(cat "$home/$AUTH")"
}

@test "test_opencode_key_must_be_one_line_without_spaces" {
  local home="$BATS_TEST_TMPDIR/home"
  local notes

  for notes in $'first-key\nsecond-key' 'fixture key'; do
    write_item "$notes"
    run apply_auth workstation "$home"
    [ "$status" -ne 0 ]
    [[ "$output" == *'Bitwarden item dotfiles/opencode-api-key must hold one API key, on one line, in its Notes'* ]]
    [[ ! -e "$home/$AUTH" ]] || fail 'a rejected key still wrote auth.json'
  done
}

@test "test_auth_file_is_secret_backed_for_workstation_update" {
  local home="$BATS_TEST_TMPDIR/home"

  run_chezmoi workstation "$home" managed --include files --path-style relative \
    | grep -Fqx "$AUTH" || fail 'auth.json is not managed'
  run_chezmoi workstation "$home" dump --include files --skip-secrets --format json \
    | jq -e --arg path "$AUTH" 'has($path) | not' >/dev/null \
    || fail 'auth.json renders without secrets, so workstation-update would overwrite it'
}
