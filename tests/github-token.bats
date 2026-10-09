#!/usr/bin/env bats

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  bats_require_minimum_version 1.5.0
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export STATE="$BATS_TEST_TMPDIR/stub-state" CALLS="$BATS_TEST_TMPDIR/calls"
  export CHEZMOI_SOURCE="$BATS_TEST_TMPDIR/source"
  export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 BW_SESSION=fixture-session
  export REAL_CHEZMOI
  REAL_CHEZMOI="$(command -v chezmoi)"
  WORK_TOKEN_FILE="$HOME/.config/github-tokens/work"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME" "$STATE/valid" "$bin" "$CHEZMOI_SOURCE/dot_config"
  : >"$CALLS"

  printf 'main-token-old' >"$STATE/main-token"
  jq -n '[
    {id: "id-main", name: "dotfiles/github-cli-token", notes: "main-token-old"},
    {id: "id-work", name: "dotfiles/github-token-work", notes: "work-token-old",
     fields: [{name: "owner", value: "example-org", type: 0}]}
  ]' >"$STATE/items.json"

  cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"$CALLS"
case "$*" in
  'auth token --hostname github.com') cat "$STATE/main-token" ;;
  'auth login --hostname github.com --with-token') tr -d '\n' >"$STATE/main-token" ;;
  'auth git-credential get')
    cat >/dev/null
    printf 'username=x-access-token\npassword=%s\n' "$(cat "$STATE/main-token")"
    ;;
  'api -i user')
    [[ -z "${API_UNREACHABLE:-}" ]] || exit 1
    if [[ -f "$STATE/valid/$GH_TOKEN" ]]; then
      printf 'HTTP/2.0 200 OK\nContent-Type: application/json\r\n'
      printf 'Github-Authentication-Token-Expiration: %s\r\n\r\n{}\n' \
        "$(cat "$STATE/valid/$GH_TOKEN")"
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
  cat >"$bin/chezmoi" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'chezmoi %s\n' "$*" >>"$CALLS"
exec "$REAL_CHEZMOI" --source "$CHEZMOI_SOURCE" --destination "$HOME" \
  --config /dev/null --config-format toml \
  --override-data '{"profile":"workstation"}' \
  --persistent-state "$XDG_STATE_HOME/chezmoi.boltdb" "$@"
STUB
  cp "$REPO_ROOT/dot_local/bin/executable_github-token" "$bin/github-token"
  sed -i "1c #!$(command -v bash)" "$bin/"*
  chmod +x "$bin/"*
  export PATH="$bin:$PATH"

  cp "$REPO_ROOT/dot_gitconfig.tmpl" "$REPO_ROOT/.chezmoiignore" "$CHEZMOI_SOURCE/"
  cp -R --no-preserve=mode "$REPO_ROOT/dot_config/private_github-tokens" "$CHEZMOI_SOURCE/dot_config/"
  chezmoi apply
  : >"$CALLS"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
}

credential_password() {
  printf 'protocol=https\nhost=github.com\npath=%s\n\n' "$1" \
    | git credential fill | sed -n 's/^password=//p'
}

item_notes() {
  jq -r --arg name "$1" '.[] | select(.name == $name) | .notes' "$STATE/items.json"
}

# Marks a token valid until the given relative date, in GitHub's header format.
token_expires() {
  date -u -d "$2" '+%Y-%m-%d %H:%M:%S UTC' >"$STATE/valid/$1"
}

@test "test_git_routes_the_work_owner_to_the_work_token_and_others_to_the_main_login" {
  [ "$(cat "$WORK_TOKEN_FILE")" = work-token-old ]
  [ "$(credential_password example-org/project)" = work-token-old ]
  [ "$(credential_password faviann/fork)" = main-token-old ]

  rm "$WORK_TOKEN_FILE"
  run --separate-stderr github-token credential work get <<<$'protocol=https\nhost=github.com\n'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "test_rotate_rejects_an_invalid_token_without_touching_bitwarden" {
  run github-token rotate work <<<'rejected-secret-token'
  [ "$status" -ne 0 ]
  [[ "$output" == *'GitHub rejected the new token (HTTP 401)'* ]]
  [[ "$output" != *rejected-secret-token* ]]
  run ! grep -q '^bw' "$CALLS"
  [ "$(item_notes dotfiles/github-token-work)" = work-token-old ]
}

@test "test_rotate_work_updates_its_item_then_rerenders_the_token_file" {
  token_expires work-secret-token '+60 days'
  run github-token rotate work <<<'  work-secret-token  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"work token rotated; expires $(cat "$STATE/valid/work-secret-token")"* ]]
  [[ "$output" != *work-secret-token* ]]
  [ "$(item_notes dotfiles/github-token-work)" = work-secret-token ]
  [ "$(item_notes dotfiles/github-cli-token)" = main-token-old ]
  [ "$(cat "$WORK_TOKEN_FILE")" = work-secret-token ]
  [ "$(cat "$STATE/main-token")" = main-token-old ]
}

@test "test_rotate_main_updates_its_item_then_reloads_the_gh_login" {
  token_expires main-secret-token '+60 days'
  run github-token rotate main <<<'main-secret-token'
  [ "$status" -eq 0 ]
  [[ "$output" != *main-secret-token* ]]
  [ "$(item_notes dotfiles/github-cli-token)" = main-secret-token ]
  [ "$(item_notes dotfiles/github-token-work)" = work-token-old ]
  [ "$(cat "$STATE/main-token")" = main-secret-token ]
  [ "$(cat "$WORK_TOKEN_FILE")" = work-token-old ]
}

@test "test_check_expiry_warns_about_tokens_expiring_soon_or_rejected" {
  token_expires main-token-old '+3 days'
  token_expires work-token-old '+30 days'
  run github-token check-expiry
  [ "$status" -eq 0 ]
  [[ "$output" == *"main token expires $(cat "$STATE/valid/main-token-old"); run github-token rotate main"* ]]
  [[ "$output" != *work* ]]

  rm "$STATE/valid/work-token-old"
  run github-token check-expiry
  [ "$status" -eq 0 ]
  [[ "$output" == *'rejects the work token as invalid or expired; run github-token rotate work'* ]]
}

@test "test_check_expiry_never_fails_its_caller" {
  run env API_UNREACHABLE=1 github-token check-expiry
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
