#!/usr/bin/env bats
set -euo pipefail

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
readonly REPO_ROOT

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}
readonly COMMAND_PATH="$PATH"
REAL_BASH="$(command -v bash)"
readonly REAL_BASH

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_fixture() {
  local test_dir="$1"
  local repo="$test_dir/repo"

  mkdir -p "$repo/scripts" "$repo/stubs"
  cp "$REPO_ROOT/scripts/update-dotnet-sdk" "$repo/scripts/update-dotnet-sdk"
  chmod +x "$repo/scripts/update-dotnet-sdk"
  printf '%s\n' '{
  "nodes": {
    "dotnet-nixpkgs": {
      "locked": { "rev": "old" },
      "original": { "ref": "nixos-unstable", "type": "github" }
    },
    "root": { "inputs": { "dotnet-nixpkgs": "dotnet-nixpkgs" } }
  },
  "root": "root",
  "version": 7
}' >"$repo/flake.lock"
  printf 'unchanged\n' >"$repo/other-tracked-file"

  printf '#!%s\n' "$REAL_BASH" >"$repo/stubs/nix"
  cat >>"$repo/stubs/nix" <<'STUB'
set -euo pipefail
printf '%s\n' "$*" >>"$NIX_LOG"
case "$1 $2" in
  'eval --raw')
    if [[ "${3:-}" == *'.outPath' ]]; then
      printf '%s' '/nix/store/test-dotnet-sdk'
    elif jq -e '.nodes["dotnet-nixpkgs"].locked.rev == "new"' flake.lock >/dev/null; then
      printf '%s' "$TEST_NEW_VERSION"
    else
      printf '%s' "$TEST_OLD_VERSION"
    fi
    ;;
  'path-info --store')
    [[ "${TEST_CACHE_MISS:-0}" != 1 ]] || exit 34
    ;;
  'flake update')
    [[ "${3:-}" == 'dotnet-nixpkgs' ]] || exit 31
    jq '.nodes["dotnet-nixpkgs"].locked.rev = "new"' flake.lock >flake.lock.next
    mv flake.lock.next flake.lock
    if [[ "${TEST_CHANGE_OTHER_LOCK_DATA:-0}" == 1 ]]; then
      jq '.nodes.root.inputs.unexpected = "new"' flake.lock >flake.lock.next
      mv flake.lock.next flake.lock
    fi
    ;;
  'flake check')
    [[ "${TEST_CHECK_FAIL:-0}" != 1 ]] || exit 32
    ;;
  *)
    exit 33
    ;;
esac
STUB
  chmod +x "$repo/stubs/nix"

  git -C "$repo" init --quiet --initial-branch main
  git -C "$repo" config user.name 'Test User'
  git -C "$repo" config user.email 'test@example.invalid'
  git -C "$repo" add -- flake.lock other-tracked-file scripts/update-dotnet-sdk stubs/nix
  git -C "$repo" commit --quiet -m fixture
}

run_updater() {
  local test_dir="$1"
  shift

  (
    cd "$test_dir/repo"
    PATH="$test_dir/repo/stubs:$COMMAND_PATH" \
    NIX_LOG="$test_dir/nix.log" \
    TEST_OLD_VERSION="${TEST_OLD_VERSION:-10.0.202}" \
    TEST_NEW_VERSION="${TEST_NEW_VERSION:-10.0.302}" \
      bash "$test_dir/repo/scripts/update-dotnet-sdk" "$@"
  ) >"$test_dir/stdout" 2>"$test_dir/stderr"
}

assert_original_lock() {
  local test_dir="$1"

  jq -e '
    (.nodes["dotnet-nixpkgs"].locked.rev == "old") and
    (.nodes.root.inputs == {"dotnet-nixpkgs": "dotnet-nixpkgs"})
  ' "$test_dir/repo/flake.lock" >/dev/null \
    || fail 'failed update did not restore the original lock'
}

@test "test_newer_dotnet_10_sdk_is_validated_and_persisted" {
  local test_dir

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"

  run_updater "$test_dir" \
    || fail "valid SDK update failed: $(<"$test_dir/stderr")"

  jq -e '.nodes["dotnet-nixpkgs"].locked.rev == "new"' \
    "$test_dir/repo/flake.lock" >/dev/null \
    || fail 'validated SDK update did not persist the new lock'
  [[ "$(<"$test_dir/stdout")" == '.NET SDK: 10.0.202 -> 10.0.302' ]] \
    || fail 'validated SDK update reported unexpected output'
  grep -Fxq 'flake update dotnet-nixpkgs' "$test_dir/nix.log" \
    || fail 'SDK updater did not narrow the flake update to dotnet-nixpkgs'
  grep -Fxq 'flake check' "$test_dir/nix.log" \
    || fail 'SDK updater did not run the repository closeout command'
  grep -Fxq \
    'path-info --store https://cache.nixos.org /nix/store/test-dotnet-sdk' \
    "$test_dir/nix.log" \
    || fail 'SDK updater did not require a binary substitute before publication'
}

@test "test_unchanged_sdk_version_is_a_noop" {
  local test_dir

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"

  TEST_NEW_VERSION=10.0.202 run_updater "$test_dir" \
    || fail "current SDK check failed: $(<"$test_dir/stderr")"

  assert_original_lock "$test_dir"
  [[ "$(<"$test_dir/stdout")" == '.NET SDK: current (10.0.202)' ]] \
    || fail 'current SDK check reported unexpected output'
  ! grep -Fxq 'flake check' "$test_dir/nix.log" \
    || fail 'current SDK check ran the full closeout without an update'
}

@test "test_cross_major_sdk_is_rejected_and_restored" {
  local test_dir

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"

  if TEST_NEW_VERSION=11.0.100 run_updater "$test_dir"; then
    fail 'cross-major SDK update succeeded'
  fi

  assert_original_lock "$test_dir"
  grep -Fq 'outside the .NET 10 GA track: 11.0.100' "$test_dir/stderr" \
    || fail 'cross-major SDK failure did not name the rejected version'
}

@test "test_sdk_downgrade_is_rejected_and_restored" {
  local test_dir

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"

  if TEST_NEW_VERSION=10.0.102 run_updater "$test_dir"; then
    fail 'SDK downgrade succeeded'
  fi

  assert_original_lock "$test_dir"
  grep -Fq 'refusing .NET SDK downgrade: 10.0.202 -> 10.0.102' \
    "$test_dir/stderr" \
    || fail 'SDK downgrade failure did not name both versions'
}

@test "test_unrelated_lock_change_is_rejected_and_restored" {
  local test_dir

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"

  if TEST_CHANGE_OTHER_LOCK_DATA=1 run_updater "$test_dir"; then
    fail 'unrelated lock change succeeded'
  fi

  assert_original_lock "$test_dir"
  grep -Fq 'changed lock data outside dotnet-nixpkgs' "$test_dir/stderr" \
    || fail 'lock-scope failure was not diagnostic'
}

@test "test_closeout_failure_restores_the_prior_lock" {
  local test_dir

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"

  if TEST_CHECK_FAIL=1 run_updater "$test_dir"; then
    fail 'SDK update survived a failed closeout'
  fi

  assert_original_lock "$test_dir"
  grep -Fq 'validation failed for .NET SDK 10.0.302' "$test_dir/stderr" \
    || fail 'closeout failure did not name the candidate SDK'
}

@test "test_missing_binary_substitute_restores_the_prior_lock" {
  local test_dir

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"

  if TEST_CACHE_MISS=1 run_updater "$test_dir"; then
    fail 'SDK update without a binary substitute succeeded'
  fi

  assert_original_lock "$test_dir"
  grep -Fq 'binary substitute is unavailable for .NET SDK 10.0.302' \
    "$test_dir/stderr" \
    || fail 'binary-substitute failure did not name the candidate SDK'
  ! grep -Fxq 'flake check' "$test_dir/nix.log" \
    || fail 'SDK update without a substitute reached the full closeout'
}

@test "test_dirty_repository_is_rejected_before_discovery" {
  local test_dir

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"
  printf 'local work\n' >"$test_dir/repo/untracked"

  if run_updater "$test_dir"; then
    fail 'dirty repository was accepted'
  fi

  [[ ! -e "$test_dir/nix.log" ]] \
    || fail 'dirty repository reached SDK discovery'
  grep -Fq 'repository must be clean' "$test_dir/stderr" \
    || fail 'dirty repository failure was not diagnostic'
}
