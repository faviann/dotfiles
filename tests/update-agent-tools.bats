#!/usr/bin/env bats

setup() {
  bats_require_minimum_version 1.5.0
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_STATE_HOME="$HOME/state"
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
  export COMMAND_LOG="$HOME/commands"
  : >"$COMMAND_LOG"
  printf '[]\n' >"$HOME/workers"
  export COMMAND="$BATS_TEST_DIRNAME/../dot_local/bin/executable_update-agent-tools"
  local tool
  for tool in npm curl aoe systemctl sleep bun opencode omp pi; do
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
  aoe)
    case "$*" in
      'ps --acp --dead --json')
        [[ "${FAIL_AT:-}" != inventory ]] || { printf 'null\n'; exit 0; }
        cat "$HOME/workers"
        ;;
      'update --yes') [[ "${FAIL_AT:-}" != aoe ]] ;;
      'acp doctor') [[ "${FAIL_AT:-}" != doctor ]] ;;
      'acp restart '*)
        [[ "${FAIL_AT:-}" != restart ]] || exit 1
        case "${WORKER_RESULT:-healthy}" in
          unchanged) ;;
          missing) printf '[]\n' >"$HOME/workers" ;;
          *)
            jq --arg session "$3" --arg result "${WORKER_RESULT:-healthy}" '
              map(if .session_id == $session then
                .pid += 100 | .alive = true | .build_stale = ($result == "stale")
              else . end)
            ' "$HOME/workers" >"$HOME/workers.tmp"
            mv "$HOME/workers.tmp" "$HOME/workers"
            ;;
        esac
        ;;
      *) exit 91 ;;
    esac
    ;;
  systemctl)
    [[ "${FAIL_AT:-}" != service ]] || exit 1
    if [[ "$*" == '--user restart aoe-serve.service' && -f "$HOME/auto-workers" ]]; then
      cp "$HOME/auto-workers" "$HOME/workers"
    fi
    ;;
  sleep) ;;
  *) exit 92 ;;
esac
STUB
    chmod +x "$HOME/.local/bin/$tool"
  done
}

live_worker() {
  printf '[{"session_id":"private-session","pid":123,"alive":true,"build_stale":false}]\n' >"$HOME/workers"
}

@test "test_noninteractive_update_requires_consent_before_changes" {
  live_worker
  run bash "$COMMAND"
  [ "$status" -ne 0 ]
  [[ "$output" == *'1 running ACP workers'* ]]
  [[ "$output" != *private-session* ]]
  run ! grep -Eq '^(npm|curl|systemctl|aoe update)' "$COMMAND_LOG"
}

@test "test_invalid_worker_inventory_refuses_changes" {
  run env FAIL_AT=inventory bash "$COMMAND" --yes
  [ "$status" -ne 0 ]
  run ! grep -Eq '^(npm|curl|systemctl|aoe update)' "$COMMAND_LOG"
}

@test "test_npm_engine_preflight_failure_preserves_installed_tools_and_services" {
  run env FAIL_AT=preflight bash "$COMMAND" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'npm preflight failed'* ]]
  run ! grep -Eq '^(curl|systemctl|aoe update)' "$COMMAND_LOG"
  grep -q '^npm install .*--force=false --engine-strict --dry-run' "$COMMAND_LOG"
}

@test "test_installation_failure_does_not_restart_services" {
  local phase
  for phase in bun npm aoe; do
    : >"$COMMAND_LOG"
    run env FAIL_AT="$phase" bash "$COMMAND" --yes
    [ "$status" -ne 0 ]
    run ! grep -q '^systemctl ' "$COMMAND_LOG"
  done
}

@test "test_failed_runtime_or_diagnostics_does_not_restart_services" {
  local phase
  for phase in opencode omp pi doctor; do
    : >"$COMMAND_LOG"
    run env FAIL_AT="$phase" bash "$COMMAND" --yes
    [ "$status" -ne 0 ]
    run ! grep -q '^systemctl ' "$COMMAND_LOG"
  done
}

@test "test_authorized_update_delegates_installation_and_replaces_captured_workers" {
  live_worker
  run bash "$COMMAND" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *'workers verified'* ]]
  grep -q '^npm install .*--force=false --engine-strict .*@openai/codex@latest .*pi-acp@latest$' "$COMMAND_LOG"
  grep -qx 'curl -fsSL https://bun.sh/install' "$COMMAND_LOG"
  grep -qx 'aoe update --yes' "$COMMAND_LOG"
  grep -qx 'aoe acp restart private-session' "$COMMAND_LOG"
  jq -e '.[0].pid == 223' "$HOME/workers"
}

@test "test_empty_workstation_does_not_need_disruption_consent" {
  run bash "$COMMAND"
  [ "$status" -eq 0 ]
  run ! grep -q '^aoe acp restart ' "$COMMAND_LOG"
}

@test "test_service_replaced_workers_are_not_restarted_twice" {
  live_worker
  jq '[.[0] | .alive = false] + [.[0] | .pid += 100]' \
    "$HOME/workers" >"$HOME/auto-workers"
  run bash "$COMMAND" --yes
  [ "$status" -eq 0 ]
  run ! grep -q '^aoe acp restart ' "$COMMAND_LOG"
}

@test "test_sessions_started_after_consent_are_not_restarted" {
  live_worker
  jq '. + [{session_id:"new-session",pid:500,alive:true,build_stale:false}]' \
    "$HOME/workers" >"$HOME/auto-workers"
  run bash "$COMMAND" --yes
  [ "$status" -eq 0 ]
  grep -qx 'aoe acp restart private-session' "$COMMAND_LOG"
  run ! grep -q '^aoe acp restart new-session' "$COMMAND_LOG"
}

@test "test_missing_unchanged_and_stale_replacement_workers_fail_verification" {
  live_worker
  local result
  for result in missing unchanged stale; do
    live_worker
    run env WORKER_RESULT="$result" bash "$COMMAND" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *'post-activation verification failed'* ]]
  done
}

@test "test_failed_service_or_worker_restart_fails_update" {
  live_worker
  local phase
  for phase in service restart; do
    run env FAIL_AT="$phase" bash "$COMMAND" --yes
    [ "$status" -ne 0 ]
    [[ "$output" != *'workers verified'* ]]
  done
}

@test "test_removed_discovery_modes_cannot_mutate_tools" {
  run bash "$COMMAND" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *'usage:'* ]]
  [ ! -s "$COMMAND_LOG" ]
}
