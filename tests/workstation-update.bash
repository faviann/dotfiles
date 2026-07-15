#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly COMMAND="$REPO_ROOT/dot_local/bin/executable_workstation-update"
readonly REAL_CHEZMOI="$(command -v chezmoi)"
readonly CANONICAL_ORIGIN='git@github.com:faviann/dotfiles.git'

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_fixture() {
  local test_dir="$1"
  local home="$test_dir/home"
  local remote="$test_dir/remote.git"
  local seed="$test_dir/seed"
  local source="$test_dir/discovered/source"
  local global_config="$test_dir/gitconfig"

  mkdir -p "$home/stubs" "$home/state" \
    "$home/.local/state/workstation-setup" \
    "$(dirname "$source")"
  : >"$home/.local/state/workstation-setup/complete"
  : >"$global_config"
  git config --file "$global_config" user.name 'Test Operator'
  git config --file "$global_config" user.email 'operator@example.test'
  git config --file "$global_config" \
    "url.file://$remote.insteadOf" "$CANONICAL_ORIGIN"

  GIT_CONFIG_GLOBAL="$global_config" \
    git init --bare --quiet --initial-branch=main "$remote"
  GIT_CONFIG_GLOBAL="$global_config" \
    git init --quiet --initial-branch=main "$seed"
  mkdir -p "$seed/dot_local/bin"
  printf 'ignored-local\n' >"$seed/.gitignore"
  printf '#!/usr/bin/env bash\nprintf "agent tools v1\\n"\n' \
    >"$seed/dot_local/bin/executable_update-agent-tools"
  printf '#!/usr/bin/env bash\nprintf "workstation update v1\\n"\n' \
    >"$seed/dot_local/bin/executable_workstation-update"
  printf 'managed v1\n' >"$seed/dot_managed"
  chmod +x "$seed/dot_local/bin/"executable_*
  GIT_CONFIG_GLOBAL="$global_config" git -C "$seed" add .
  GIT_CONFIG_GLOBAL="$global_config" \
    git -C "$seed" commit --quiet -m initial
  GIT_CONFIG_GLOBAL="$global_config" \
    git -C "$seed" remote add origin "file://$remote"
  GIT_CONFIG_GLOBAL="$global_config" \
    git -C "$seed" push --quiet --set-upstream origin main
  GIT_CONFIG_GLOBAL="$global_config" \
    git clone --quiet "file://$remote" "$source"
  GIT_CONFIG_GLOBAL="$global_config" \
    git -C "$source" remote set-url origin "$CANONICAL_ORIGIN"

  cat >"$home/stubs/chezmoi" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'chezmoi' >>"$COMMAND_LOG"
printf ' %q' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
if [[ "${TEST_FAIL_DRY_RUN:-0}" == 1 \
  && "$*" == 'apply --dry-run --verbose' ]]; then
  printf 'injected dry-run failure\n' >&2
  exit 42
fi
if [[ "${TEST_FAIL_APPLY:-0}" == 1 && "$*" == apply ]]; then
  printf 'injected apply failure\n' >&2
  exit 43
fi
"$TEST_REAL_CHEZMOI" \
  --source "$SOURCE_REPO" \
  --destination "$HOME" \
  --config /dev/null \
  --config-format toml \
  --persistent-state "$XDG_STATE_HOME/chezmoistate.boltdb" \
  "$@"
if [[ "${TEST_DRIFT_AFTER_APPLY:-0}" == 1 \
  && "$1" == apply && "$*" != *'--dry-run'* ]]; then
  printf 'post-apply drift\n' >"$HOME/.managed"
fi
STUB
  chmod +x "$home/stubs/chezmoi"
}

run_update() {
  local test_dir="$1"
  shift

  HOME="$test_dir/home" \
    XDG_STATE_HOME="$test_dir/home/state" \
    PATH="$test_dir/home/stubs:/usr/bin:/bin" \
    COMMAND_LOG="$test_dir/home/command-log" \
    TEST_REAL_CHEZMOI="$REAL_CHEZMOI" \
    SOURCE_REPO="$test_dir/discovered/source" \
    GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    TEST_FAIL_DRY_RUN="${TEST_FAIL_DRY_RUN:-0}" \
    TEST_FAIL_APPLY="${TEST_FAIL_APPLY:-0}" \
    TEST_DRIFT_AFTER_APPLY="${TEST_DRIFT_AFTER_APPLY:-0}" \
    bash "$COMMAND" "$@" </dev/null \
      >"$test_dir/home/stdout" 2>"$test_dir/home/stderr"
}

run_chezmoi() {
  local test_dir="$1"
  shift

  HOME="$test_dir/home" \
    XDG_STATE_HOME="$test_dir/home/state" \
    "$REAL_CHEZMOI" \
      --source "$test_dir/discovered/source" \
      --destination "$test_dir/home" \
      --config /dev/null \
      --config-format toml \
      --persistent-state "$test_dir/home/state/chezmoistate.boltdb" \
      "$@"
}

source_commit() {
  GIT_CONFIG_GLOBAL="$1/gitconfig" \
    git -C "$1/discovered/source" rev-parse HEAD
}

write_applied_marker() {
  local test_dir="$1"

  mkdir -p "$test_dir/home/state/workstation-update"
  source_commit "$test_dir" \
    >"$test_dir/home/state/workstation-update/applied-commit"
}

publish_managed_version() {
  local test_dir="$1"
  local version="$2"
  local seed="$test_dir/seed"

  printf 'managed %s\n' "$version" >"$seed/dot_managed"
  printf '#!/usr/bin/env bash\nprintf "agent tools %s\\n"\n' "$version" \
    >"$seed/dot_local/bin/executable_update-agent-tools"
  printf '#!/usr/bin/env bash\nprintf "workstation update %s\\n"\n' "$version" \
    >"$seed/dot_local/bin/executable_workstation-update"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" git -C "$seed" add .
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$seed" commit --quiet -m "publish $version"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$seed" push --quiet origin main
}

assert_update_fails_with() {
  local test_dir="$1"
  local expected="$2"

  if run_update "$test_dir"; then
    fail "update unexpectedly succeeded; expected: $expected"
  fi
  grep -Fq "$expected" "$test_dir/home/stderr" \
    || fail "missing diagnostic '$expected': $(<"$test_dir/home/stderr")"
}

test_setup_must_be_complete_before_source_discovery() {
  local test_dir
  local status=0

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  mkdir -p "$test_dir/home/stubs"

  cat >"$test_dir/home/stubs/chezmoi" <<'STUB'
#!/usr/bin/env bash
printf 'chezmoi %s\n' "$*" >>"$COMMAND_LOG"
exit 64
STUB
  chmod +x "$test_dir/home/stubs/chezmoi"

  HOME="$test_dir/home" \
    XDG_STATE_HOME="$test_dir/home/state" \
    PATH="$test_dir/home/stubs:/usr/bin:/bin" \
    COMMAND_LOG="$test_dir/home/command-log" \
    bash "$COMMAND" \
      >"$test_dir/home/stdout" 2>"$test_dir/home/stderr" || status=$?

  [[ "$status" -ne 0 ]] || fail 'incomplete setup was accepted'
  grep -Fq 'workstation-update: setup is incomplete' \
    "$test_dir/home/stderr" \
    || fail "missing setup diagnostic: $(<"$test_dir/home/stderr")"
  [[ ! -e "$test_dir/home/command-log" ]] \
    || fail 'source discovery ran before the setup gate'
}

test_first_run_adopts_verified_equal_history() {
  local test_dir
  local expected_commit
  local marker

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  rm -f "$test_dir/home/command-log"
  expected_commit="$(source_commit "$test_dir")"
  marker="$test_dir/home/state/workstation-update/applied-commit"

  run_update "$test_dir" \
    || fail "verified first run failed: $(<"$test_dir/home/stderr")"

  [[ -f "$marker" ]] || fail 'verified first run did not create a marker'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'verified first run did not adopt the current commit'
  [[ "$(<"$test_dir/home/.managed")" == 'managed v1' ]] \
    || fail 'verified first run changed an already-current target'
  diff -u \
    <(printf '%s\n' 'chezmoi source-path' 'chezmoi verify') \
    "$test_dir/home/command-log" \
    || fail 'verified first run invoked apply'
}

test_repository_structure_is_validated_before_fetch() {
  local test_dir
  local old_remote_tip
  local scenario

  for scenario in wrong-origin wrong-branch detached missing-upstream; do
    test_dir="$(mktemp -d)"
    make_fixture "$test_dir"
    old_remote_tip="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" rev-parse origin/main)"
    publish_managed_version "$test_dir" v2

    case "$scenario" in
      wrong-origin)
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" remote set-url origin \
            git@github.com:someone-else/dotfiles.git
        assert_update_fails_with "$test_dir" 'origin must be'
        ;;
      wrong-branch)
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" switch --quiet -c topic
        assert_update_fails_with "$test_dir" 'branch must be main'
        ;;
      detached)
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" switch --quiet --detach
        assert_update_fails_with "$test_dir" 'detached HEAD'
        ;;
      missing-upstream)
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" branch --unset-upstream
        assert_update_fails_with "$test_dir" 'upstream must be origin/main'
        ;;
    esac

    [[ "$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" rev-parse origin/main)" \
      == "$old_remote_tip" ]] \
      || fail "$scenario fetched before structural validation"
    if [[ -e "$test_dir/home/command-log" ]]; then
      ! grep -Fq ' apply' "$test_dir/home/command-log" \
        || fail "$scenario reached chezmoi apply"
    fi
    rm -rf "$test_dir"
  done
}

test_all_source_extras_and_unfinished_operations_are_preserved() {
  local test_dir
  local scenario
  local before_head
  local before_status
  local after_status

  for scenario in staged modified deleted untracked ignored unfinished; do
    test_dir="$(mktemp -d)"
    make_fixture "$test_dir"

    case "$scenario" in
      staged)
        printf 'staged local work\n' \
          >>"$test_dir/discovered/source/dot_managed"
        GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
          git -C "$test_dir/discovered/source" add dot_managed
        ;;
      modified)
        printf 'modified local work\n' \
          >>"$test_dir/discovered/source/dot_managed"
        ;;
      deleted)
        rm "$test_dir/discovered/source/dot_managed"
        ;;
      untracked)
        printf 'untracked local work\n' \
          >"$test_dir/discovered/source/local-notes"
        ;;
      ignored)
        printf 'ignored local work\n' \
          >"$test_dir/discovered/source/ignored-local"
        ;;
      unfinished)
        mkdir "$test_dir/discovered/source/.git/rebase-merge"
        ;;
    esac

    before_head="$(source_commit "$test_dir")"
    before_status="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" status \
        --porcelain=v1 --untracked-files=all --ignored)"
    if [[ "$scenario" == unfinished ]]; then
      assert_update_fails_with "$test_dir" 'unfinished Git operation'
    else
      assert_update_fails_with "$test_dir" \
        'source repository has local content'
    fi
    after_status="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
      git -C "$test_dir/discovered/source" status \
        --porcelain=v1 --untracked-files=all --ignored)"
    [[ "$(source_commit "$test_dir")" == "$before_head" ]] \
      || fail "$scenario changed the checked-out commit"
    [[ "$after_status" == "$before_status" ]] \
      || fail "$scenario changed the index, worktree, or extra content"
    if [[ "$scenario" == unfinished ]]; then
      [[ -d "$test_dir/discovered/source/.git/rebase-merge" ]] \
        || fail 'unfinished operation metadata was discarded'
    fi
    rm -rf "$test_dir"
  done
}

test_fetch_and_unsafe_history_fail_diagnostically() {
  local test_dir

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"
  git config --file "$test_dir/gitconfig" --unset-all \
    "url.file://$test_dir/remote.git.insteadOf"
  git config --file "$test_dir/gitconfig" \
    "url.file://$test_dir/missing.git.insteadOf" "$CANONICAL_ORIGIN"
  assert_update_fails_with "$test_dir" 'fetch phase failed'
  rm -rf "$test_dir"

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"
  printf 'unpublished\n' >"$test_dir/discovered/source/dot_unpublished"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" add dot_unpublished
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" commit --quiet -m unpublished
  assert_update_fails_with "$test_dir" 'ahead of origin/main by 1 commit(s)'
  rm -rf "$test_dir"

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"
  printf 'unpublished\n' >"$test_dir/discovered/source/dot_unpublished"
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" add dot_unpublished
  GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/discovered/source" commit --quiet -m unpublished
  publish_managed_version "$test_dir" v2
  assert_update_fails_with "$test_dir" 'has diverged from origin/main'
  rm -rf "$test_dir"
}

test_behind_history_fast_forwards_then_applies_in_order() {
  local test_dir
  local expected_commit
  local marker

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  rm -f "$test_dir/home/command-log"
  publish_managed_version "$test_dir" v2
  expected_commit="$(GIT_CONFIG_GLOBAL="$test_dir/gitconfig" \
    git -C "$test_dir/seed" rev-parse HEAD)"
  marker="$test_dir/home/state/workstation-update/applied-commit"

  run_update "$test_dir" \
    || fail "behind update failed: $(<"$test_dir/home/stderr")"

  [[ "$(source_commit "$test_dir")" == "$expected_commit" ]] \
    || fail 'strictly behind main was not fast-forwarded to origin/main'
  [[ "$(<"$test_dir/home/.managed")" == 'managed v2' ]] \
    || fail 'fast-forwarded source was not applied'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'verified fast-forward did not update the marker'
  diff -u \
    <(printf '%s\n' \
      'chezmoi source-path' \
      'chezmoi apply --dry-run --verbose' \
      'chezmoi apply' \
      'chezmoi verify') \
    "$test_dir/home/command-log" \
    || fail 'required apply did not run dry-run, apply, verify in order'
}

test_missing_maintenance_executable_enters_the_apply_path() {
  local test_dir
  local marker
  local expected_commit

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  expected_commit="$(source_commit "$test_dir")"
  rm "$test_dir/home/.local/bin/workstation-update"
  rm -f "$test_dir/home/command-log"

  assert_update_fails_with "$test_dir" 'dry-run phase failed'

  [[ ! -e "$test_dir/home/.local/bin/workstation-update" ]] \
    || fail 'unattended apply replaced a locally deleted executable'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'failed executable repair changed the prior marker'
  grep -Fqx 'chezmoi apply --dry-run --verbose' \
    "$test_dir/home/command-log" \
    || fail 'missing maintenance executable did not require apply'
}

test_drifted_maintenance_executable_enters_the_apply_path() {
  local test_dir
  local expected_commit
  local marker

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  expected_commit="$(source_commit "$test_dir")"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  printf 'operator-maintained version\n' \
    >"$test_dir/home/.local/bin/update-agent-tools"
  rm -f "$test_dir/home/command-log"

  assert_update_fails_with "$test_dir" 'dry-run phase failed'

  [[ "$(<"$test_dir/home/.local/bin/update-agent-tools")" \
    == 'operator-maintained version' ]] \
    || fail 'unattended apply overwrote a drifted maintenance executable'
  [[ "$(<"$marker")" == "$expected_commit" ]] \
    || fail 'drifted executable failure changed the prior marker'
  grep -Fqx 'chezmoi apply --dry-run --verbose' \
    "$test_dir/home/command-log" \
    || fail 'drifted maintenance executable did not require apply'
}

test_matching_marker_does_not_reconcile_unrelated_target_drift() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  printf 'unrelated operator change\n' >"$test_dir/home/.managed"
  rm -f "$test_dir/home/command-log"

  run_update "$test_dir" \
    || fail "matching-marker check failed: $(<"$test_dir/home/stderr")"

  [[ "$(<"$test_dir/home/.managed")" == 'unrelated operator change' ]] \
    || fail 'matching marker reconciled unrelated target drift'
  ! grep -Fq ' apply' "$test_dir/home/command-log" \
    || fail 'matching marker applied unrelated target drift'
}

test_first_run_with_drift_enters_the_apply_path() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"

  run_update "$test_dir" \
    || fail "first-run apply failed: $(<"$test_dir/home/stderr")"

  [[ "$(<"$test_dir/home/.managed")" == 'managed v1' ]] \
    || fail 'first-run drift was not applied'
  diff -u \
    <(printf '%s\n' \
      'chezmoi source-path' \
      'chezmoi verify' \
      'chezmoi apply --dry-run --verbose' \
      'chezmoi apply' \
      'chezmoi verify') \
    "$test_dir/home/command-log" \
    || fail 'failed first-run verification did not enter the apply path'
}

test_unattended_overwrite_and_phase_failures_preserve_the_marker() {
  local test_dir
  local old_commit
  local marker

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  old_commit="$(source_commit "$test_dir")"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  publish_managed_version "$test_dir" v2
  printf 'operator change\n' >"$test_dir/home/.managed"
  rm -f "$test_dir/home/command-log"

  assert_update_fails_with "$test_dir" 'dry-run phase failed'
  [[ "$(<"$marker")" == "$old_commit" ]] \
    || fail 'failed unattended overwrite changed the prior marker'
  [[ "$(<"$test_dir/home/.managed")" == 'operator change' ]] \
    || fail 'unattended apply overwrote a locally modified target'
  ! grep -Fq -- '--force' "$test_dir/home/command-log" \
    || fail 'unattended apply authorized overwrite with force'

  printf 'managed v1\n' >"$test_dir/home/.managed"
  rm -f "$test_dir/home/command-log"
  run_update "$test_dir" \
    || fail "safe apply retry failed: $(<"$test_dir/home/stderr")"
  [[ "$(<"$test_dir/home/.managed")" == 'managed v2' ]] \
    || fail 'safe retry did not converge the corrected target'
  [[ "$(<"$marker")" == "$(source_commit "$test_dir")" ]] \
    || fail 'safe retry did not record verified success'
}

test_dry_run_and_verification_failures_are_safe_to_retry() {
  local test_dir
  local old_commit
  local marker

  test_dir="$(mktemp -d)"
  make_fixture "$test_dir"
  run_chezmoi "$test_dir" apply
  write_applied_marker "$test_dir"
  old_commit="$(source_commit "$test_dir")"
  marker="$test_dir/home/state/workstation-update/applied-commit"
  publish_managed_version "$test_dir" v2
  rm -f "$test_dir/home/command-log"

  TEST_FAIL_DRY_RUN=1 \
    assert_update_fails_with "$test_dir" 'dry-run phase failed'
  [[ "$(<"$marker")" == "$old_commit" ]] \
    || fail 'dry-run failure changed the prior marker'
  [[ "$(<"$test_dir/home/.managed")" == 'managed v1' ]] \
    || fail 'dry-run failure changed a managed target'

  rm -f "$test_dir/home/command-log"
  TEST_FAIL_APPLY=1 \
    assert_update_fails_with "$test_dir" 'apply phase failed'
  [[ "$(<"$marker")" == "$old_commit" ]] \
    || fail 'apply failure changed the prior marker'
  [[ "$(<"$test_dir/home/.managed")" == 'managed v1' ]] \
    || fail 'injected apply failure changed a managed target'

  rm -f "$test_dir/home/command-log"
  TEST_DRIFT_AFTER_APPLY=1 \
    assert_update_fails_with "$test_dir" 'verification phase failed'
  [[ "$(<"$marker")" == "$old_commit" ]] \
    || fail 'verification failure changed the prior marker'
  [[ "$(<"$test_dir/home/.managed")" == 'post-apply drift' ]] \
    || fail 'verification fault injection did not create target drift'

  printf 'managed v2\n' >"$test_dir/home/.managed"
  rm -f "$test_dir/home/command-log"
  run_update "$test_dir" \
    || fail "verification retry failed: $(<"$test_dir/home/stderr")"
  [[ "$(<"$marker")" == "$(source_commit "$test_dir")" ]] \
    || fail 'verification retry did not record success'
  [[ -z "$(find "$(dirname "$marker")" -name '*.tmp.*' -print -quit)" ]] \
    || fail 'atomic marker update left a temporary file'
  rm -rf "$test_dir"
}

test_setup_must_be_complete_before_source_discovery
test_first_run_adopts_verified_equal_history
test_repository_structure_is_validated_before_fetch
test_all_source_extras_and_unfinished_operations_are_preserved
test_fetch_and_unsafe_history_fail_diagnostically
test_behind_history_fast_forwards_then_applies_in_order
test_missing_maintenance_executable_enters_the_apply_path
test_drifted_maintenance_executable_enters_the_apply_path
test_matching_marker_does_not_reconcile_unrelated_target_drift
test_first_run_with_drift_enters_the_apply_path
test_unattended_overwrite_and_phase_failures_preserve_the_marker
test_dry_run_and_verification_failures_are_safe_to_retry

printf 'PASS: workstation update\n'
