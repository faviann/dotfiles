#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

readonly ITEM_NAME=dotfiles/tailscale-policy-oauth
readonly CLIENT_ID='fixture-client-id'
readonly CLIENT_SECRET='tskey-client-fixture0123456789-abcdef'
readonly TARGET=.agents/tailscale-policy/oauth

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  export ITEM="$BATS_TEST_TMPDIR/item.json"
  HOME_DIR="$BATS_TEST_TMPDIR/home"
  local bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$bin" "$HOME_DIR"
  cat >"$bin/bw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == 'get item dotfiles/tailscale-policy-oauth' ]] || exit 64
cat "$ITEM"
STUB
  sed -i "1c #!$(command -v bash)" "$bin/bw"
  chmod +x "$bin/bw"
  export PATH="$bin:$PATH"
}

apply_profile() {
  local profile="$1"
  local runtime_dir="$BATS_TEST_TMPDIR/runtime"

  mkdir -p "$runtime_dir" "$HOME_DIR/$(dirname "$TARGET")"
  HOME="$HOME_DIR" \
  XDG_CACHE_HOME="$runtime_dir/cache" \
  XDG_CONFIG_HOME="$runtime_dir/config" \
  XDG_STATE_HOME="$runtime_dir/state" \
    chezmoi \
    --source "$REPO_ROOT" \
    --destination "$HOME_DIR" \
    --config /dev/null \
    --config-format toml \
    --persistent-state "$runtime_dir/chezmoistate.boltdb" \
    --override-data "{\"profile\":\"$profile\"}" \
    apply --force "$HOME_DIR/$(dirname "$TARGET")" "$HOME_DIR/$TARGET"
}

write_item() {
  jq -n --arg name "$1" --arg id "$2" --arg secret "$3" \
    '{name: $name, login: {username: $id, password: $secret}}' >"$ITEM"
}

@test "test_oauth_credential_renders_two_lines_owner_only_on_the_workstation" {
  write_item "$ITEM_NAME" "$CLIENT_ID" "$CLIENT_SECRET"

  apply_profile workstation

  cmp -s "$HOME_DIR/$TARGET" \
    <(printf 'TS_OAUTH_CLIENT_ID=%s\nTS_OAUTH_CLIENT_SECRET=%s\n' "$CLIENT_ID" "$CLIENT_SECRET") \
    || fail 'credential file is not the two expected lines'
  [[ "$(stat -c %a "$HOME_DIR/.agents/tailscale-policy")" == 700 ]] \
    || fail 'credential directory is not owner-only'
  [[ "$(stat -c %a "$HOME_DIR/$TARGET")" == 600 ]] \
    || fail 'credential file is not owner-only'
}

@test "test_oauth_credential_apply_fails_naming_the_item_when_a_field_is_empty_or_malformed" {
  local id secret

  for pair in "|$CLIENT_SECRET" "$CLIENT_ID|" "$CLIENT_ID|not-a-client-secret" "$CLIENT_ID|tskey-client-" \
    "two words|$CLIENT_SECRET" "$CLIENT_ID|${CLIENT_SECRET}"$'\nextra'; do
    id="${pair%%|*}"
    secret="${pair#*|}"
    rm -rf "$HOME_DIR"
    mkdir -p "$HOME_DIR"
    write_item "$ITEM_NAME" "$id" "$secret"

    if apply_profile workstation 2>"$BATS_TEST_TMPDIR/stderr"; then
      fail "apply succeeded with username '$id' and a bad password"
    fi
    grep -qF "Bitwarden item $ITEM_NAME must hold" "$BATS_TEST_TMPDIR/stderr" \
      || fail 'apply error does not name the item'
    [[ ! -e "$HOME_DIR/$TARGET" ]] || fail 'apply wrote a credential file from bad fields'
  done
}

@test "test_oauth_credential_apply_fails_when_the_item_does_not_exist" {
  rm -f "$ITEM"

  if apply_profile workstation 2>"$BATS_TEST_TMPDIR/stderr"; then
    fail 'apply succeeded without the item'
  fi
  [[ ! -e "$HOME_DIR/$TARGET" ]] || fail 'apply wrote a credential file without the item'
}

@test "test_oauth_credential_apply_fails_when_the_item_has_no_login" {
  jq -n '{name: "dotfiles/tailscale-policy-oauth", notes: "x"}' >"$ITEM"

  if apply_profile workstation 2>"$BATS_TEST_TMPDIR/stderr"; then
    fail 'apply succeeded with no login'
  fi
  grep -qF "Bitwarden item $ITEM_NAME must hold" "$BATS_TEST_TMPDIR/stderr" \
    || fail 'apply error does not name the item'
}

@test "test_oauth_credential_is_secret_backed_for_workstation_update" {
  local runtime_dir="$BATS_TEST_TMPDIR/runtime"

  mkdir -p "$runtime_dir"
  HOME="$HOME_DIR" \
  XDG_CACHE_HOME="$runtime_dir/cache" \
  XDG_CONFIG_HOME="$runtime_dir/config" \
  XDG_STATE_HOME="$runtime_dir/state" \
    chezmoi --source "$REPO_ROOT" --destination "$HOME_DIR" --config /dev/null \
    --config-format toml --override-data '{"profile":"workstation"}' \
    dump --include files --skip-secrets --format json \
    | jq -e 'has(".agents/tailscale-policy/oauth") | not' >/dev/null \
    || fail 'the credential renders without secrets, so workstation-update would overwrite it'
}

@test "test_oauth_credential_is_not_managed_on_a_desktop" {
  write_item "$ITEM_NAME" "$CLIENT_ID" "$CLIENT_SECRET"

  if apply_profile desktop 2>"$BATS_TEST_TMPDIR/stderr"; then
    fail 'desktop managed the work tailnet credential'
  fi
  grep -qF 'not managed' "$BATS_TEST_TMPDIR/stderr" || fail 'desktop apply failed for another reason'
  [[ ! -e "$HOME_DIR/$TARGET" ]] || fail 'desktop received the work tailnet credential'
}
