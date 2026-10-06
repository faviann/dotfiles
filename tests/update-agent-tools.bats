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
  local tool
  for tool in npm curl bun opencode omp pi; do
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
    printf '[[ "$BUN_INSTALL" == "$HOME/.local" ]]\n'
    ;;
  bun|opencode|omp|pi) [[ "${FAIL_AT:-}" != "$name" ]] ;;
  *) exit 92 ;;
esac
STUB
    chmod +x "$HOME/.local/bin/$tool"
  done
}

@test "test_npm_engine_preflight_failure_preserves_installed_tools" {
  run env FAIL_AT=preflight bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'npm preflight failed'* ]]
  run ! grep -q '^curl ' "$COMMAND_LOG"
  grep -q '^npm install .*--force=false --engine-strict .*--dry-run' "$COMMAND_LOG"
  [ "$(grep -c '^npm install ' "$COMMAND_LOG")" -eq 1 ]
}

@test "test_update_installs_bun_and_npm_tools" {
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
  for phase in bun npm opencode omp pi; do
    run env FAIL_AT="$phase" bash "$COMMAND"
    [ "$status" -ne 0 ]
    [[ "$output" != *'Agent tools updated'* ]]
  done
}

@test "test_arguments_are_rejected_before_changes" {
  run bash "$COMMAND" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'usage:'* ]]
  [ ! -s "$COMMAND_LOG" ]
}
