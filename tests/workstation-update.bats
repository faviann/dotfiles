#!/usr/bin/env bats

setup() {
  bats_require_minimum_version 1.5.0
  export COMMAND="$BATS_TEST_DIRNAME/../dot_local/bin/executable_workstation-update"
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_STATE_HOME="$HOME/state"
  export XDG_CACHE_HOME="$HOME/cache" XDG_CONFIG_HOME="$HOME/config"
  export SOURCE_REPO="$BATS_TEST_TMPDIR/source"
  export REMOTE_REPO="$BATS_TEST_TMPDIR/remote.git"
  export PHASE_LOG="$BATS_TEST_TMPDIR/phases"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  export GIT_SSH_VARIANT=ssh GIT_TERMINAL_PROMPT=0
  export REAL_CHEZMOI REAL_GIT_UPLOAD_PACK
  REAL_CHEZMOI="$(command -v chezmoi)"
  REAL_GIT_UPLOAD_PACK="$(command -v git-upload-pack)"
  export BW_SESSION=fixture-session
  mkdir -p "$HOME/.local/state/workstation-setup" "$HOME/.local/bin" "$BATS_TEST_TMPDIR/bin"
  touch "$HOME/.local/state/workstation-setup/complete"
  git config --global user.name 'Test Operator'
  git config --global user.email 'operator@example.test'
  git init --quiet --bare --initial-branch=main "$REMOTE_REPO"
  git init --quiet --initial-branch=main "$BATS_TEST_TMPDIR/seed"
  seed="$BATS_TEST_TMPDIR/seed"
  printf 'ignored-local\n' >"$seed/.gitignore"
  printf 'version one\n' >"$seed/dot_managed"
  mkdir -p "$seed/dot_local/bin"
  cat >"$seed/dot_local/bin/executable_update-agent-tools" <<'STUB'
#!/usr/bin/env bash
printf 'agent-tools %s\n' "$*" >>"$PHASE_LOG"
[[ "${FAIL_PHASE:-}" != agent-tools ]]
STUB
  cat >"$seed/dot_local/bin/executable_github-token" <<'STUB'
#!/usr/bin/env bash
printf 'github-token %s\n' "$*" >>"$PHASE_LOG"
printf 'github-token: warning: the work token expires soon; run github-token rotate work\n' >&2
[[ "${FAIL_PHASE:-}" != github-token ]]
STUB
  sed -i "1c #!$(command -v bash)" "$seed/dot_local/bin/executable_"*
  git -C "$seed" add .
  git -C "$seed" commit --quiet -m initial
  git -C "$seed" remote add origin "$REMOTE_REPO"
  git -C "$seed" push --quiet --set-upstream origin main
  git clone --quiet "$REMOTE_REPO" "$SOURCE_REPO"
  git -C "$SOURCE_REPO" remote set-url origin git@github.com:faviann/dotfiles.git
  cat >"$BATS_TEST_TMPDIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'fetch\n' >>"$PHASE_LOG"
[[ "${FAIL_PHASE:-}" != fetch ]] || exit 1
if [[ -n "${DIRTY_DURING_FETCH:-}" ]]; then
  printf 'concurrent local work\n' >"$SOURCE_REPO/dot_managed"
fi
exec "$REAL_GIT_UPLOAD_PACK" "$REMOTE_REPO"
STUB
  cat >"$BATS_TEST_TMPDIR/bin/bw" <<'STUB'
#!/usr/bin/env bash
printf 'bw %s\n' "$*" >>"$PHASE_LOG"
case "$*" in
  'unlock --check') [[ "${BW_SESSION:-}" == fixture-session ]] ;;
  'unlock --raw')
    [[ "${FAIL_UNLOCK:-}" != 1 ]] || exit 1
    printf 'fixture-session\n' ;;
  'get item fixture')
    [[ "${BW_SESSION:-}" == fixture-session ]] || exit 1
    printf '{"notes":"refreshed-secret","fields":[{"name":"owner","value":"work-owner"}]}\n' ;;
  *) exit 1 ;;
esac
STUB
  cat >"$BATS_TEST_TMPDIR/bin/chezmoi" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'chezmoi %s\n' "$*" >>"$PHASE_LOG"
[[ "${FAIL_PHASE:-}" != "$1" ]] || exit 1
"$REAL_CHEZMOI" --color=false --progress=false --source "$SOURCE_REPO" --destination "$HOME" \
  --config "${CHEZMOI_CONFIG_FILE:-/dev/null}" --config-format toml \
  --persistent-state "$XDG_STATE_HOME/chezmoi.boltdb" "$@"
STUB
  cat >"$BATS_TEST_TMPDIR/bin/workstation-setup" <<'STUB'
#!/usr/bin/env bash
printf 'workstation-setup\n' >>"$PHASE_LOG"
[[ "${FAIL_PHASE:-}" != workstation-setup ]]
STUB
  sed -i "1c #!$(command -v bash)" "$BATS_TEST_TMPDIR/bin/"*
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

publish_change() {
  printf 'version two\n' >"$seed/dot_managed"
  git -C "$seed" add .
  git -C "$seed" commit --quiet -m update
  git -C "$seed" push --quiet
}

@test "test_workstation_update_reconciles_in_order_and_retries_without_a_success_cache" {
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.managed")" = 'version one' ]
  local phases
  phases="$(cat "$PHASE_LOG")"
  [[ "$phases" == *fetch*'chezmoi init'*'chezmoi apply'*'chezmoi verify'*workstation-setup*agent-tools*'github-token check-expiry'* ]]
  run ! grep -q '^bw ' "$PHASE_LOG"

  # Even unchanged source must retry the configuration owner's reconciliation.
  : >"$PHASE_LOG"
  run env FAIL_PHASE=workstation-setup bash "$COMMAND"
  [ "$status" -ne 0 ]
  run ! grep -q '^agent-tools' "$PHASE_LOG"
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  grep -q '^agent-tools $' "$PHASE_LOG"
}

@test "test_workstation_update_fast_forwards_and_uses_the_new_managed_updater" {
  publish_change
  sed -i 's/agent-tools /new-agent-tools /' "$seed/dot_local/bin/executable_update-agent-tools"
  git -C "$seed" commit --quiet -am 'new updater'
  git -C "$seed" push --quiet
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  [ "$(git -C "$SOURCE_REPO" rev-parse HEAD)" = "$(git -C "$seed" rev-parse HEAD)" ]
  [ "$(cat "$HOME/.managed")" = 'version two' ]
  grep -q '^new-agent-tools $' "$PHASE_LOG"
}

@test "test_workstation_update_preserves_local_source_content" {
  for path in dot_managed untracked ignored-local; do
    printf 'operator work\n' >"$SOURCE_REPO/$path"
    run bash "$COMMAND"
    [ "$status" -ne 0 ]
    [[ "$output" == *'source has local content'* ]]
    [ "$(cat "$SOURCE_REPO/$path")" = 'operator work' ]
    run ! grep -q '^fetch' "$PHASE_LOG"
    if [[ "$path" == dot_managed ]]; then
      git -C "$SOURCE_REPO" restore dot_managed
    else
      rm "$SOURCE_REPO/$path"
    fi
  done
}

@test "test_workstation_update_refuses_hidden_index_content_and_unfinished_git_operations" {
  git -C "$SOURCE_REPO" update-index --assume-unchanged dot_managed
  printf 'hidden work\n' >"$SOURCE_REPO/dot_managed"
  run bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'index flags hide tracked content'* ]]
  [ "$(cat "$SOURCE_REPO/dot_managed")" = 'hidden work' ]
  git -C "$SOURCE_REPO" update-index --no-assume-unchanged dot_managed
  git -C "$SOURCE_REPO" restore dot_managed
  mkdir "$SOURCE_REPO/.git/rebase-merge"
  run bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unfinished Git operation'* ]]
  run ! grep -q '^fetch' "$PHASE_LOG"
}

@test "test_workstation_update_requires_canonical_main_and_upstream" {
  git -C "$SOURCE_REPO" remote set-url origin https://example.invalid/dotfiles.git
  run bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'origin must be the canonical'* ]]
  git -C "$SOURCE_REPO" remote set-url origin git@github.com:faviann/dotfiles.git
  git -C "$SOURCE_REPO" checkout --quiet -b topic
  run bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'source branch must be main'* ]]
  git -C "$SOURCE_REPO" checkout --quiet main
  git -C "$SOURCE_REPO" branch --unset-upstream
  run bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'source upstream must be origin/main'* ]]
  run ! grep -q '^fetch' "$PHASE_LOG"
}

@test "test_workstation_update_preserves_ahead_and_diverged_history" {
  git -C "$SOURCE_REPO" commit --quiet --allow-empty -m 'local work'
  local_head="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
  run bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'ahead of or diverged'* ]]
  publish_change
  run bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'ahead of or diverged'* ]]
  [ "$(git -C "$SOURCE_REPO" rev-parse HEAD)" = "$local_head" ]
  run ! grep -q '^chezmoi apply' "$PHASE_LOG"
}

@test "test_workstation_update_rechecks_local_work_after_fetch" {
  publish_change
  local_head="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
  run env DIRTY_DURING_FETCH=1 bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'source has local content'* ]]
  [ "$(cat "$SOURCE_REPO/dot_managed")" = 'concurrent local work' ]
  [ "$(git -C "$SOURCE_REPO" rev-parse HEAD)" = "$local_head" ]
}

@test "test_workstation_update_preserves_modified_chezmoi_targets_unattended" {
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  printf 'operator target work\n' >"$HOME/.managed"
  publish_change
  : >"$PHASE_LOG"
  run bash "$COMMAND" </dev/null
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.managed")" = 'operator target work' ]
  run ! grep -q '^workstation-setup' "$PHASE_LOG"
}

@test "test_workstation_update_stops_at_failed_phases_and_can_be_rerun" {
  for phase in fetch init apply verify workstation-setup agent-tools; do
    : >"$PHASE_LOG"
    run env FAIL_PHASE="$phase" bash "$COMMAND"
    [ "$status" -ne 0 ]
    [[ "$output" != *'Workstation update complete'* ]]
    if [[ "$phase" != agent-tools ]]; then
      run ! grep -q '^agent-tools' "$PHASE_LOG"
    fi
    run bash "$COMMAND"
    [ "$status" -eq 0 ]
  done
}

publish_secret_templates() {
  printf '{{ (bitwarden "item" "fixture").notes }}\n' >"$seed/private_dot_secret.tmpl"
  printf 'owner={{ (bitwardenFields "item" "fixture").owner.value }}\n' >"$seed/dot_routing.tmpl"
  git -C "$seed" add .
  git -C "$seed" commit --quiet -m 'add secret-backed files'
  git -C "$seed" push --quiet
}

@test "test_workstation_update_requires_unlock_for_missing_or_empty_secret_files" {
  publish_secret_templates
  printf 'existing routing\n' >"$HOME/.routing"
  for state in missing empty directory broken-symlink; do
    case "$state" in
      empty) touch "$HOME/.secret" ;;
      directory) mkdir "$HOME/.secret" ;;
      broken-symlink) rmdir "$HOME/.secret"; ln -s absent "$HOME/.secret" ;;
    esac
    : >"$PHASE_LOG"
    run env BW_SESSION= bash "$COMMAND" </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *'unlocking is required'*'~/.secret'*'Bitwarden is locked'* ]]
    run ! grep -q '^chezmoi apply' "$PHASE_LOG"
    run env BW_SESSION= bash "$COMMAND" --skip-secrets </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *'cannot skip required secrets'* ]]
    [[ "$state" != empty ]] || rm "$HOME/.secret"
  done
}

@test "test_workstation_update_keeps_existing_secrets_when_locked_and_reports_progress" {
  publish_secret_templates
  printf 'existing secret\n' >"$HOME/.secret"
  printf 'existing routing\n' >"$HOME/.routing"
  run env BW_SESSION= bash "$COMMAND" </dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.secret")" = 'existing secret' ]
  [ "$(cat "$HOME/.routing")" = 'existing routing' ]
  [ "$(cat "$HOME/.managed")" = 'version one' ]
  [[ "$output" == *'[1/9]'*'[2/9]'*'[3/9]'*'[4/9]'*'[5/9]'*'[6/9]'*'[7/9]'*'[8/9]'*'[9/9]'*'refresh deferred'* ]]
  [[ "$output" != *'existing secret'* ]]
  run ! grep -q '^bw get\|^bw unlock --raw' "$PHASE_LOG"
}

@test "test_workstation_update_can_skip_even_with_an_unlocked_session" {
  publish_secret_templates
  printf 'existing secret\n' >"$HOME/.secret"
  printf 'existing routing\n' >"$HOME/.routing"
  run bash "$COMMAND" --skip-secrets
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.secret")" = 'existing secret' ]
  run ! grep -q '^bw ' "$PHASE_LOG"
}

@test "test_workstation_update_refreshes_secrets_with_a_valid_session_without_printing_them" {
  publish_secret_templates
  run bash "$COMMAND" --refresh-secrets
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.secret")" = refreshed-secret ]
  [ "$(cat "$HOME/.routing")" = owner=work-owner ]
  [[ "$output" != *'refreshed-secret'* ]]
  [[ "$output" != *'refresh deferred'* ]]
  run ! grep -q '^bw unlock --raw' "$PHASE_LOG"

  run env BW_SESSION= bash "$COMMAND" --refresh-secrets </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *'Bitwarden is locked'* ]]
}

interactive_update() {
  local transcript="$BATS_TEST_TMPDIR/terminal"
  : >"$transcript"
  # Answer after fetch, which can consume terminal input. One deadline covers
  # both the responder and updater; TERM=dumb avoids terminal color queries.
  # shellcheck disable=SC2016
  timeout 20s bash -c '
    {
      until grep -Fq "Unlock and refresh secrets?" "$2"; do
        sleep 0.05
      done
      printf "%s\n" "$1"
    } | env TERM=dumb BW_SESSION= script -q -e -f -O "$2" -c "bash \"\$COMMAND\""
  ' bash "$1" "$transcript"
}

@test "test_workstation_update_interactive_enter_skips_and_yes_unlocks_once" {
  publish_secret_templates
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  : >"$PHASE_LOG"
  run interactive_update ''
  [ "$status" -eq 0 ]
  [[ "$output" == *'Unlock and refresh secrets? [y/N]'*'refresh deferred'* ]]
  [ "$(cat "$HOME/.secret")" = refreshed-secret ]
  run ! grep -q '^bw unlock --raw' "$PHASE_LOG"

  : >"$PHASE_LOG"
  run interactive_update y
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.secret")" = refreshed-secret ]
  [ "$(grep -c '^bw unlock --raw' "$PHASE_LOG")" -eq 1 ]
  [[ "$output" == *'unlocking Bitwarden to refresh'* ]]
  [[ "$output" != *'fixture-session'* ]]
}

@test "test_workstation_update_explains_required_interactive_unlock_and_stops_on_failure" {
  publish_secret_templates
  # The child shell expands COMMAND from the environment.
  # shellcheck disable=SC2016
  run env TERM=dumb BW_SESSION= FAIL_UNLOCK=1 timeout 20s script -q -e -c 'bash "$COMMAND"' /dev/null </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *'unlocking is required'*'unlocking Bitwarden'*'Bitwarden unlock failed'* ]]
  [[ "$output" != *'Unlock and refresh secrets?'* ]]
  run ! grep -q '^chezmoi apply' "$PHASE_LOG"

  # The child shell expands COMMAND from the environment.
  # shellcheck disable=SC2016
  run env TERM=dumb BW_SESSION= timeout 20s script -q -e -c 'bash "$COMMAND"' /dev/null </dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.secret")" = refreshed-secret ]
}

@test "test_workstation_update_secret_inventory_respects_ignores_and_template_conditions" {
  printf '.ignored-secret\n' >"$seed/.chezmoiignore"
  printf '{{ (bitwarden "item" "fixture").notes }}\n' >"$seed/dot_ignored-secret.tmpl"
  printf '{{ if false }}{{ (bitwarden "item" "fixture").notes }}{{ else }}ordinary{{ end }}\n' \
    >"$seed/dot_conditional.tmpl"
  publish_secret_templates
  printf 'existing secret\n' >"$HOME/.secret"
  printf 'existing routing\n' >"$HOME/.routing"
  run env BW_SESSION= bash "$COMMAND" </dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.conditional")" = ordinary ]
  [ ! -e "$HOME/.ignored-secret" ]
  [[ "$output" != *'unlocking is required'* ]]
}

@test "test_workstation_update_rejects_concurrency_incomplete_setup_and_unknown_arguments" {
  mkdir -p "$XDG_STATE_HOME/workstation-update"
  exec 8>"$XDG_STATE_HOME/workstation-update/lock"
  flock 8
  run bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'already running'* ]]
  exec 8>&-
  rm "$HOME/.local/state/workstation-setup/complete"
  run bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'setup is incomplete'* ]]
  run bash "$COMMAND" --force
  [ "$status" -ne 0 ]
  [[ "$output" == *'usage: workstation-update'* ]]
  [ ! -e "$PHASE_LOG" ]
}

@test "test_workstation_update_refreshes_source_owned_chezmoi_configuration" {
  local expected=other

  # An installation whose persisted config predates the source rename.
  export CHEZMOI_CONFIG_FILE="$XDG_CONFIG_HOME/chezmoi/chezmoi.toml"
  mkdir -p "$(dirname "$CHEZMOI_CONFIG_FILE")"
  printf '[data]\n  is_lxc = true\n' >"$CHEZMOI_CONFIG_FILE"

  # The source publishes this repository's config template plus a consumer of
  # the renamed key. Under chezmoi's missingkey=error that consumer cannot
  # render until the config is regenerated, so an update path that only
  # fast-forwards the source fails here.
  cp "$BATS_TEST_DIRNAME/../.chezmoi.toml.tmpl" "$seed/.chezmoi.toml.tmpl"
  printf '{{ if .is_workstation }}workstation{{ else }}other{{ end }}\n' \
    >"$seed/dot_applicability.tmpl"
  git -C "$seed" add .
  git -C "$seed" commit --quiet -m 'rename the applicability key'
  git -C "$seed" push --quiet

  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  [[ "$(hostname -s)" != workstation ]] || expected=workstation
  [ "$(cat "$HOME/.applicability")" = "$expected" ]
  grep -q 'is_workstation' "$CHEZMOI_CONFIG_FILE"
  run ! grep -q 'is_lxc' "$CHEZMOI_CONFIG_FILE"
}

@test "test_workstation_update_completes_despite_token_expiry_warnings_or_failure" {
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  [[ "$output" == *'run github-token rotate work'*'Workstation update complete'* ]]

  run env FAIL_PHASE=github-token bash "$COMMAND"
  [ "$status" -eq 0 ]
  [[ "$output" == *'expiry check failed; continuing'*'Workstation update complete'* ]]
}
