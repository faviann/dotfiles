#!/usr/bin/env bats

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  bats_require_minimum_version 1.5.0
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
  export STATE="$BATS_TEST_TMPDIR/stub-state" CALLS="$BATS_TEST_TMPDIR/calls"
  export BW_SESSION=fixture-session
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME" "$STATE/valid" "$bin"
  : >"$CALLS"

  printf 'token-old' >"$STATE/gh-token"
  jq -n '[
    {id: "id-github", name: "dotfiles/github-cli-token", notes: "token-old"},
    {id: "id-other", name: "dotfiles/other", notes: "other-notes"}
  ]' >"$STATE/items.json"

  cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"$CALLS"
case "$*" in
  'auth token --hostname github.com') cat "$STATE/gh-token" ;;
  'auth login --hostname github.com --with-token') tr -d '\n' >"$STATE/gh-token" ;;
  'api -i user')
    [[ -z "${API_UNREACHABLE:-}" ]] || exit 1
    if [[ -f "$STATE/valid/$GH_TOKEN" ]]; then
      printf 'HTTP/2.0 200 OK\nContent-Type: application/json\r\n'
      if [[ -s "$STATE/valid/$GH_TOKEN" ]]; then
        printf 'Github-Authentication-Token-Expiration: %s\r\n' "$(cat "$STATE/valid/$GH_TOKEN")"
      fi
      printf '\r\n{}\n'
    else
      printf 'HTTP/2.0 401 Unauthorized\nContent-Type: application/json\r\n\r\n{}\n'
      exit 1
    fi
    ;;
  *) exit 64 ;;
esac
STUB
  cat >"$bin/bw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'bw %s\n' "$*" >>"$CALLS"
case "$1 ${2:-}" in
  'unlock --check') [[ "${BW_SESSION:-}" == fixture-session ]] ;;
  'get item')
    jq -e --arg key "$3" '.[] | select(.id == $key or .name == $key)' "$STATE/items.json"
    ;;
  'encode ') base64 -w0 ;;
  'edit item')
    base64 -d >"$STATE/edited.json"
    jq --arg id "$3" --slurpfile item "$STATE/edited.json" \
      'map(if .id == $id then $item[0] else . end)' "$STATE/items.json" >"$STATE/items.next"
    mv "$STATE/items.next" "$STATE/items.json"
    cat "$STATE/edited.json"
    ;;
  'sync ') printf 'Syncing complete.\n' ;;
  *) exit 64 ;;
esac
STUB
  cp "$REPO_ROOT/dot_local/bin/executable_github-token" "$bin/github-token"
  sed -i "1c #!$(command -v bash)" "$bin/"*
  chmod +x "$bin/"*
  export PATH="$bin:$PATH"
}

item_notes() {
  jq -r --arg name "$1" '.[] | select(.name == $name) | .notes' "$STATE/items.json"
}

# Marks a token valid until the given relative date, in GitHub's header format.
token_expires() {
  date -u -d "$2" '+%Y-%m-%d %H:%M:%S UTC' >"$STATE/valid/$1"
}

@test "test_rotate_rejects_an_invalid_token_without_touching_bitwarden" {
  run github-token rotate <<<'rejected-secret-token'
  [ "$status" -ne 0 ]
  [[ "$output" == *'GitHub rejected the new token (HTTP 401)'* ]]
  [[ "$output" != *rejected-secret-token* ]]
  run ! grep -q '^bw' "$CALLS"
  [ "$(item_notes dotfiles/github-cli-token)" = token-old ]
}

@test "test_rotate_rejects_a_token_without_an_expiry" {
  : >"$STATE/valid/no-expiry-token"
  run github-token rotate <<<'no-expiry-token'
  [ "$status" -ne 0 ]
  [[ "$output" == *'GitHub reported no expiry for the new token'* ]]
  run ! grep -q '^bw' "$CALLS"
  [ "$(cat "$STATE/gh-token")" = token-old ]
}

@test "test_rotate_updates_the_item_then_reloads_the_gh_login" {
  token_expires new-secret-token '+60 days'
  run github-token rotate <<<'  new-secret-token  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"token rotated; expires $(cat "$STATE/valid/new-secret-token")"* ]]
  [[ "$output" != *new-secret-token* ]]
  [ "$(item_notes dotfiles/github-cli-token)" = new-secret-token ]
  [ "$(item_notes dotfiles/other)" = other-notes ]
  [ "$(cat "$STATE/gh-token")" = new-secret-token ]
}

@test "test_check_expiry_warns_about_a_token_expiring_soon_or_rejected" {
  token_expires token-old '+30 days'
  run github-token check-expiry
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  token_expires token-old '+3 days'
  run github-token check-expiry
  [ "$status" -eq 0 ]
  [[ "$output" == *"token expires $(cat "$STATE/valid/token-old"); run github-token rotate"* ]]

  rm "$STATE/valid/token-old"
  run github-token check-expiry
  [ "$status" -eq 0 ]
  [[ "$output" == *'rejects the token as invalid or expired; run github-token rotate'* ]]
}

@test "test_check_expiry_never_fails_its_caller" {
  run env API_UNREACHABLE=1 github-token check-expiry
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
