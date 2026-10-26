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
  export MARKETPLACE_LIST="$BATS_TEST_TMPDIR/marketplaces.json"
  printf '[{"name":"openai-codex","source":"github","repo":"openai/codex-plugin-cc"}]\n' >"$MARKETPLACE_LIST"
  export PLUGIN_LIST="$BATS_TEST_TMPDIR/plugins.json"
  printf '[{"id":"codex@openai-codex","scope":"user"},{"id":"context7@claude-plugins-official","scope":"user"}]\n' >"$PLUGIN_LIST"
  local tool
  for tool in npm curl bun opencode pi claude; do
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
  opencode|pi) [[ "${FAIL_AT:-}" != "$name" ]] ;;
  claude)
    case "$*" in
      'plugin marketplace list --json')
        [[ "${FAIL_AT:-}" != marketplace-list ]]
        cat "$MARKETPLACE_LIST"
        ;;
      'plugin marketplace add '*) [[ "${FAIL_AT:-}" != marketplace-add ]] ;;
      'plugin list --json')
        [[ "${FAIL_AT:-}" != plugin-list ]]
        cat "$PLUGIN_LIST"
        ;;
      'plugin install '*) [[ "${FAIL_AT:-}" != plugin-install ]] ;;
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
  for phase in bun bun-upgrade npm opencode pi marketplace-list marketplace-add \
    plugin-list plugin-install plugin-update; do
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

@test "test_update_adds_missing_marketplaces_and_installs_or_updates_declared_plugins" {
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Agent tools updated'* ]]
  diff -u - <(grep '^claude ' "$COMMAND_LOG") <<'LOG'
claude plugin marketplace list --json
claude plugin marketplace add michael-denyer/pstack-claude
claude plugin list --json
claude plugin install pstack@pstack-claude
claude plugin update codex@openai-codex
claude plugin install frontend-design@anthropic-plugin-directory
claude plugin install skill-creator@anthropic-plugin-directory
LOG
}

@test "test_update_of_reconciled_claude_plugins_only_updates_the_declared_ones" {
  printf '[{"name":"openai-codex"},{"name":"pstack-claude"},{"name":"claude-plugins-official"}]\n' \
    >"$MARKETPLACE_LIST"
  printf '[%s]\n' '{"id":"skill-creator@anthropic-plugin-directory"},{"id":"pstack@pstack-claude"},{"id":"context7@claude-plugins-official"},{"id":"frontend-design@anthropic-plugin-directory"},{"id":"codex@openai-codex"}' \
    >"$PLUGIN_LIST"
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  diff -u - <(grep '^claude ' "$COMMAND_LOG") <<'LOG'
claude plugin marketplace list --json
claude plugin list --json
claude plugin update pstack@pstack-claude
claude plugin update codex@openai-codex
claude plugin update frontend-design@anthropic-plugin-directory
claude plugin update skill-creator@anthropic-plugin-directory
LOG
}

@test "test_failed_marketplace_add_names_the_marketplace" {
  run env FAIL_AT=marketplace-add bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Claude Code plugin marketplace add failed: pstack-claude'* ]]
  [[ "$output" != *'Agent tools updated'* ]]
}

@test "test_failed_claude_plugin_install_names_the_plugin" {
  run env FAIL_AT=plugin-install bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Claude Code plugin install failed: pstack@pstack-claude'* ]]
  [[ "$output" != *'Agent tools updated'* ]]
}

@test "test_failed_claude_plugin_update_names_the_plugin" {
  run env FAIL_AT=plugin-update bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Claude Code plugin update failed: codex@openai-codex'* ]]
  [[ "$output" != *'Agent tools updated'* ]]
}
