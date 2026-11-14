#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

readonly TOKEN='fixture-github-token-0123456789'

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  export ITEM="$BATS_TEST_TMPDIR/item.json"
  local bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$bin"
  cat >"$bin/bw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == 'get item dotfiles/github-cli-token' ]] || exit 64
cat "$ITEM"
STUB
  sed -i "1c #!$(command -v bash)" "$bin/bw"
  chmod +x "$bin/bw"
  export PATH="$bin:$PATH"
  write_item "$TOKEN"
}

write_item() {
  jq -n --arg notes "$1" '{name: "dotfiles/github-cli-token", notes: $notes}' >"$ITEM"
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

apply_npmrc() {
  run_chezmoi "$1" "$2" apply --force "$2/.npmrc"
}

expected_npmrc() {
  printf 'prefix=/home/faviann/.local\n//npm.pkg.github.com/:_authToken=%s\n' "$1"
}

@test "test_github_token_renders_into_an_owner_only_npmrc_on_every_profile" {
  local profile
  local home

  for profile in workstation desktop; do
    home="$BATS_TEST_TMPDIR/$profile"
    apply_npmrc "$profile" "$home"

    cmp -s "$home/.npmrc" <(expected_npmrc "$TOKEN") \
      || fail "$profile: .npmrc is not the prefix and the GitHub Packages auth line: $(cat "$home/.npmrc")"
    [[ "$(stat -c %a "$home/.npmrc")" == 600 ]] || fail "$profile: .npmrc is not owner-only"
  done
}

@test "test_rotated_item_replaces_the_token_in_an_existing_npmrc" {
  local home="$BATS_TEST_TMPDIR/home"

  mkdir -p "$home"
  printf 'prefix=/home/faviann/.local\n//npm.pkg.github.com/:_authToken=hand-added-token\n' >"$home/.npmrc"
  apply_npmrc desktop "$home"
  cmp -s "$home/.npmrc" <(expected_npmrc "$TOKEN") \
    || fail "apply kept the hand-added token: $(cat "$home/.npmrc")"

  write_item $'rotated-github-token\n'
  apply_npmrc desktop "$home"
  cmp -s "$home/.npmrc" <(expected_npmrc rotated-github-token) \
    || fail "apply did not pick up the rotated token: $(cat "$home/.npmrc")"
}

@test "test_github_token_must_be_one_line_without_spaces" {
  local home="$BATS_TEST_TMPDIR/home"
  local notes

  for notes in '' $'first-token\nsecond-token' 'fixture token'; do
    write_item "$notes"
    run apply_npmrc workstation "$home"
    [ "$status" -ne 0 ]
    [[ "$output" == *'Bitwarden item dotfiles/github-cli-token must hold one GitHub token, on one line, in its Notes'* ]]
    [[ ! -e "$home/.npmrc" ]] || fail 'a rejected token still wrote .npmrc'
  done
}

@test "test_npmrc_is_secret_backed_for_workstation_update" {
  local home="$BATS_TEST_TMPDIR/home"

  run_chezmoi workstation "$home" managed --include files --path-style relative \
    | grep -Fqx .npmrc || fail '.npmrc is not managed'
  run_chezmoi workstation "$home" dump --include files --skip-secrets --format json \
    | jq -e 'has(".npmrc") | not' >/dev/null \
    || fail '.npmrc renders without secrets, so workstation-update would overwrite it'
}
