#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}
REAL_BASH="$(command -v bash)"
readonly REAL_BASH
export REAL_BASH

render_hook() {
  local is_workstation="$1"
  local output="$2"
  local destination
  local render_dir

  render_dir="$(dirname "$output")"
  destination="$render_dir/destination"
  mkdir -p "$destination"
  chezmoi \
    --source "$REPO_ROOT" \
    --destination "$destination" \
    --config /dev/null \
    --config-format toml \
    --persistent-state "$render_dir/chezmoistate.boltdb" \
    --override-data "{\"is_workstation\":$is_workstation}" \
    execute-template \
    --file "$REPO_ROOT/.chezmoiscripts/run_after_reconcile-agent-skills.sh.tmpl" \
    >"$output"
  chmod +x "$output"
}

make_reconciler() {
  local repo="$1"

  mkdir -p "$repo/.git" "$repo/scripts"
  printf '#!%s\n' "$REAL_BASH" >"$repo/scripts/reconcile-skills.sh"
  cat >>"$repo/scripts/reconcile-skills.sh" <<'STUB'
printf 'reconcile\n' >>"$COMMAND_LOG"
printf 'bw=%s\n' "${BW_SESSION:-<unset>}" >>"${BW_PROBE:-/dev/null}"
exit "${RECONCILE_STATUS:-0}"
STUB
  chmod +x "$repo/scripts/reconcile-skills.sh"
}

make_git_stub() {
  local bin_dir="$1"

  mkdir -p "$bin_dir"
  printf '#!%s\n' "$REAL_BASH" >"$bin_dir/git"
  cat >>"$bin_dir/git" <<'STUB'
set -euo pipefail

printf 'git' >>"$COMMAND_LOG"
printf ' %s' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"

if [[ "${1:-}" == clone ]]; then
  [[ "${GIT_CLONE_FAIL:-false}" != true ]] || exit 23
  target="${@: -1}"
  mkdir -p "$target/.git" "$target/scripts"
  printf '#!%s\n' "$REAL_BASH" >"$target/scripts/reconcile-skills.sh"
  cat >>"$target/scripts/reconcile-skills.sh" <<'RECONCILER'
printf 'reconcile\n' >>"$COMMAND_LOG"
printf 'bw=%s\n' "${BW_SESSION:-<unset>}" >>"${BW_PROBE:-/dev/null}"
exit "${RECONCILE_STATUS:-0}"
RECONCILER
  chmod +x "$target/scripts/reconcile-skills.sh"
  exit 0
fi

if [[ "${1:-}" == -C && "${3:-}" == rev-parse &&
  "${4:-}" == --show-toplevel ]]; then
  [[ "${GIT_INVALID_CHECKOUT:-false}" != true ]] || exit 128
  printf '%s\n' "$SKILLS_REPO"
  exit 0
fi

exit 99
STUB
  chmod +x "$bin_dir/git"
}

run_hook() {
  local test_dir="$1"
  local script="$test_dir/hook"
  local home="$test_dir/home"
  local bin_dir="$test_dir/bin"

  mkdir -p "$home"
  render_hook true "$script"
  make_git_stub "$bin_dir"
  env \
    HOME="$home" \
    PATH="$bin_dir:$PATH" \
    COMMAND_LOG="$test_dir/commands" \
    BW_PROBE="$test_dir/bw-probe" \
    SKILLS_REPO="$home/repos/skills" \
    GIT_CLONE_FAIL="${GIT_CLONE_FAIL:-false}" \
    GIT_INVALID_CHECKOUT="${GIT_INVALID_CHECKOUT:-false}" \
    RECONCILE_STATUS="${RECONCILE_STATUS:-0}" \
    "$REAL_BASH" "$script"
}

@test "test_missing_checkout_is_cloned_and_reconciled" {
  local test_dir
  test_dir="$(mktemp -d)"

  run_hook "$test_dir" || fail 'missing checkout recovery failed'

  diff -u \
    <(printf '%s\n' \
      "git clone https://github.com/faviann/skills.git $test_dir/home/repos/skills" \
      reconcile) \
    "$test_dir/commands" \
    || fail 'bootstrap did not clone and reconcile in order'
}

@test "test_existing_checkout_is_preserved_and_idempotent" {
  local test_dir
  test_dir="$(mktemp -d)"

  make_reconciler "$test_dir/home/repos/skills"
  run_hook "$test_dir" || fail 'existing checkout reconciliation failed'
  run_hook "$test_dir" || fail 'second reconciliation failed'

  [[ "$(grep -c '^reconcile$' "$test_dir/commands")" -eq 2 ]] \
    || fail 'reconciler did not run exactly once per apply'
  if grep -Eq '^git (clone|fetch|pull|reset|checkout|switch)' \
    "$test_dir/commands"; then
    fail 'existing checkout was cloned or updated'
  fi
}

@test "test_invalid_existing_path_fails_without_reconciliation" {
  local test_dir
  test_dir="$(mktemp -d)"

  mkdir -p "$test_dir/home/repos/skills"
  printf 'preserve me\n' >"$test_dir/home/repos/skills/marker"
  if GIT_INVALID_CHECKOUT=true run_hook "$test_dir"; then
    fail 'invalid existing path was accepted'
  fi

  [[ "$(cat "$test_dir/home/repos/skills/marker")" == 'preserve me' ]] \
    || fail 'invalid existing path was mutated'
  ! grep -q '^reconcile$' "$test_dir/commands" \
    || fail 'reconciler ran for an invalid checkout'
}

@test "test_clone_and_reconciler_failures_propagate" {
  local clone_dir
  local reconcile_dir
  clone_dir="$(mktemp -d)"
  reconcile_dir="$(mktemp -d)"

  if GIT_CLONE_FAIL=true run_hook "$clone_dir"; then
    fail 'clone failure was accepted'
  fi
  ! grep -q '^reconcile$' "$clone_dir/commands" \
    || fail 'reconciler ran after clone failure'

  make_reconciler "$reconcile_dir/home/repos/skills"
  if RECONCILE_STATUS=29 run_hook "$reconcile_dir"; then
    fail 'reconciler failure was accepted'
  fi
}

@test "test_reconciler_cannot_read_the_unlocked_vault_session" {
  local test_dir
  test_dir="$(mktemp -d)"

  make_reconciler "$test_dir/home/repos/skills"
  BW_SESSION=vault-session-token run_hook "$test_dir" \
    || fail 'reconciliation under an unlocked vault session failed'

  grep -q '^reconcile$' "$test_dir/commands" \
    || fail 'reconciler did not run'
  diff -u \
    <(printf 'bw=<unset>\n') \
    "$test_dir/bw-probe" \
    || fail 'reconciler inherited the unlocked vault session'
}

@test "test_non_lxc_render_is_a_noop" {
  local test_dir
  local script
  test_dir="$(mktemp -d)"
  script="$test_dir/hook"

  render_hook false "$script"
  if grep -q '[^[:space:]]' "$script"; then
    fail 'non-LXC render contained executable work'
  fi
  HOME="$test_dir/home" "$REAL_BASH" "$script" \
    || fail 'non-LXC no-op failed'
  [[ ! -e "$test_dir/home/repos/skills" ]] \
    || fail 'non-LXC no-op created a skills checkout'
}
