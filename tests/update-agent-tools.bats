#!/usr/bin/env bats

setup() {
  bats_require_minimum_version 1.5.0
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_STATE_HOME="$HOME/state"
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
  export COMMAND_LOG="$HOME/commands"
  : >"$COMMAND_LOG"
  export COMMAND="$BATS_TEST_DIRNAME/../dot_local/bin/executable_update-agent-tools"
  export PLUGIN_LIST="$BATS_TEST_TMPDIR/plugins.json"
  printf '[{"id":"codex@openai-codex","scope":"user"},{"id":"pstack@pstack-claude","scope":"user"}]\n' >"$PLUGIN_LIST"
  local tool
  for tool in npm curl bun opencode omp pi claude; do
    printf '#!%s\n' "$(command -v bash)" >"$HOME/.local/bin/$tool"
    cat >>"$HOME/.local/bin/$tool" <<'STUB'
set -euo pipefail
name="${0##*/}"
printf '%s %s\n' "$name" "$*" >>"$COMMAND_LOG"
case "$name" in
  npm)
    if [[ "$*" == *--dry-run* ]]; then
      [[ "${FAIL_AT:-}" != preflight ]]
    else
      [[ "${FAIL_AT:-}" != npm ]]
    fi
    ;;
  curl)
    [[ "${FAIL_AT:-}" != bun ]] || exit 1
    printf '[[ "$BUN_INSTALL" == "$HOME/.local" ]]\ncp "$BUN_FIXTURE" "$BUN_INSTALL/bin/bun"\n'
    ;;
  bun)
    if [[ "$*" == 'upgrade --stable' ]]; then
      [[ "${FAIL_AT:-}" != bun-upgrade ]]
    else
      [[ "${FAIL_AT:-}" != bun ]]
    fi
    ;;
  opencode|omp|pi) [[ "${FAIL_AT:-}" != "$name" ]] ;;
  claude)
    case "$*" in
      'plugin list --json')
        [[ "${FAIL_AT:-}" != plugin-list ]]
        cat "$PLUGIN_LIST"
        ;;
      'plugin update '*) [[ "${FAIL_AT:-}" != plugin-update ]] ;;
      *) exit 92 ;;
    esac
    ;;
  *) exit 92 ;;
esac
STUB
    chmod +x "$HOME/.local/bin/$tool"
  done
  export BUN_FIXTURE="$BATS_TEST_TMPDIR/bun"
  cp "$HOME/.local/bin/bun" "$BUN_FIXTURE"
}

@test "test_npm_engine_preflight_failure_preserves_installed_tools" {
  run env FAIL_AT=preflight bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'npm preflight failed'* ]]
  run ! grep -q '^curl ' "$COMMAND_LOG"
  grep -q '^npm install .*--force=false --engine-strict .*--dry-run' "$COMMAND_LOG"
  [ "$(grep -c '^npm install ' "$COMMAND_LOG")" -eq 1 ]
}

@test "test_update_installs_missing_bun_and_npm_tools" {
  rm "$HOME/.local/bin/bun"
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Agent tools updated'* ]]
  grep -q '^npm install .*--force=false --engine-strict .*@openai/codex@latest' "$COMMAND_LOG"
  # Both npm invocations must carry a non-empty install-script allowlist: the
  # claude and opencode packages install a placeholder executable and still
  # succeed when their script is blocked. Which packages it names is not
  # asserted here; npm reports an omitted one on the next update.
  [ "$(grep -c '^npm install .*--allow-scripts=[^ ]' "$COMMAND_LOG")" -eq 2 ]
  grep -qx 'curl -fsSL https://bun.sh/install' "$COMMAND_LOG"
  [ "$(readlink "$HOME/.local/bin/bunx")" = bun ]
}

@test "test_failed_installation_or_harness_fails_update" {
  local phase
  for phase in bun bun-upgrade npm opencode omp pi plugin-list plugin-update; do
    run env FAIL_AT="$phase" bash "$COMMAND"
    [ "$status" -ne 0 ]
    [[ "$output" != *'Agent tools updated'* ]]
  done
}

@test "test_arguments_are_rejected_before_changes" {
  run bash "$COMMAND" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *'usage:'* ]]
  [ ! -s "$COMMAND_LOG" ]
}

@test "test_update_uses_buns_upgrader_when_the_managed_binary_runs" {
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  grep -qx 'bun upgrade --stable' "$COMMAND_LOG"
  run ! grep -q '^curl ' "$COMMAND_LOG"
  [ "$(readlink "$HOME/.local/bin/bunx")" = bun ]
}

@test "test_update_reinstalls_a_broken_bun" {
  printf '#!%s\nexit 1\n' "$(command -v bash)" >"$HOME/.local/bin/bun"
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  grep -q '^curl ' "$COMMAND_LOG"
  run "$HOME/.local/bin/bun" --version
  [ "$status" -eq 0 ]
}

@test "test_update_refreshes_installed_claude_plugins_after_npm_install" {
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Agent tools updated'* ]]
  [ "$(tail -n 1 "$COMMAND_LOG")" = 'claude plugin update pstack@pstack-claude' ]
  [ "$(grep -c '^claude plugin update ' "$COMMAND_LOG")" -eq 1 ]
}

@test "test_update_skips_claude_plugins_that_are_not_installed" {
  printf '[{"id":"codex@openai-codex","scope":"user"}]\n' >"$PLUGIN_LIST"
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Agent tools updated'* ]]
  grep -qx 'claude plugin list --json' "$COMMAND_LOG"
  run ! grep -q '^claude plugin update ' "$COMMAND_LOG"
}

@test "test_failed_claude_plugin_update_names_the_plugin" {
  run env FAIL_AT=plugin-update bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Claude Code plugin update failed: pstack@pstack-claude'* ]]
  [[ "$output" != *'Agent tools updated'* ]]
}
