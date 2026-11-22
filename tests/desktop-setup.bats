#!/usr/bin/env bats
set -euo pipefail

# Covers desktop-setup, the guided pass over the steps only a person can finish
# after bootstrap. tailscale, ip, curl, codex, claude, az, and wifi-sync are
# stubs whose state lives in files under $STATE, so each test starts from a
# machine where every step is done and breaks only what it exercises. The
# command refuses to run without a terminal, so interactive cases feed their
# answers through a pty.

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

REAL_BASH="$(command -v bash)"
SCRIPT_TOOL="$(command -v script)"
readonly REAL_BASH SCRIPT_TOOL
readonly SETUP="$REPO_ROOT/dot_local/bin/executable_desktop-setup"
readonly UP_COMMAND='tailscale up --operator=tester --accept-routes --accept-dns --shields-up'
readonly ADMIN_URL=https://login.tailscale.com/admin/machines

# Every stub records its argv, then runs its own body.
write_stub() {
  local name="$1"
  {
    # shellcheck disable=SC2016 # the stub's own $* and $CALLS expand when it runs
    printf '#!%s\nset -euo pipefail\nprintf "%s %%s\\n" "$*" >>"$CALLS"\n' "$REAL_BASH" "$name"
    cat
  } >"$STUBS/$name"
  chmod +x "$STUBS/$name"
}

setup() {
  bats_require_minimum_version 1.5.0
  export TMPDIR="$BATS_TEST_TMPDIR"
  export USER=tester
  export STATE="$BATS_TEST_TMPDIR/stub-state" CALLS="$BATS_TEST_TMPDIR/calls"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  REAL_TOOLS="$BATS_TEST_TMPDIR/real-tools"
  mkdir -p "$STATE" "$STUBS" "$REAL_TOOLS"
  : >"$CALLS"
  printf 'Running\n' >"$STATE/backend"
  printf 'Running\n' >"$STATE/backend-after-up"
  : >"$STATE/key-never-expires"

  local tool
  for tool in cat cp env jq rm; do
    ln -s "$(command -v "$tool")" "$REAL_TOOLS/$tool"
  done

  # Status calls are counted so a test can say when the tailnet changes:
  # BACKEND_RUNNING_AT and KEY_EXPIRY_OFF_AT are the call number from which
  # the stub reports Running and expiry disabled.
  write_stub tailscale <<'STUB'
case "$1" in
  status)
    count="$(($(cat "$STATE/status-calls" 2>/dev/null || echo 0) + 1))"
    printf '%s' "$count" >"$STATE/status-calls"
    backend="$(<"$STATE/backend")"
    [[ -z "${BACKEND_RUNNING_AT:-}" || "$count" -lt "$BACKEND_RUNNING_AT" ]] || backend=Running
    expiry='2027-01-01T00:00:00Z'
    [[ ! -e "$STATE/key-never-expires" ]] || expiry=
    [[ -z "${KEY_EXPIRY_OFF_AT:-}" || "$count" -lt "$KEY_EXPIRY_OFF_AT" ]] || expiry=
    jq -nc --arg backend "$backend" --arg expiry "$expiry" \
      '{BackendState: $backend, Self: {HostName: "glados", KeyExpiry: (if $expiry == "" then null else $expiry end)}}'
    ;;
  up)
    printf 'To authenticate, visit: https://login.tailscale.com/a/fixture\n'
    cp "$STATE/backend-after-up" "$STATE/backend"
    ;;
  *) exit 64 ;;
esac
STUB
  write_stub ip <<'STUB'
if [[ -e "$STATE/no-route" ]]; then
  printf '135.119.134.202 via 192.168.1.1 dev wlp2s0 src 192.168.1.20 uid 1000\n'
else
  printf '135.119.134.202 dev tailscale0 src 100.64.0.1 uid 1000\n'
fi
STUB
  write_stub curl <<'STUB'
cat "$STATE/gateway-code" 2>/dev/null || printf 401
STUB
  write_stub codex <<'STUB'
case "$*" in
  'login status') [[ ! -e "$STATE/codex-logged-out" ]] ;;
  'login') rm -f "$STATE/codex-logged-out" ;;
  *) exit 64 ;;
esac
STUB
  write_stub claude <<'STUB'
case "$*" in
  'auth status') [[ ! -e "$STATE/claude-logged-out" ]] ;;
  'auth login --claudeai') rm -f "$STATE/claude-logged-out" ;;
  *) exit 64 ;;
esac
STUB
  write_stub az <<'STUB'
case "$1 ${2:-}" in
  'account show') [[ ! -e "$STATE/az-logged-out" ]] ;;
  'login --use-device-code')
    printf 'To sign in, use a web browser to open https://microsoft.com/devicelogin\n' >&2
    rm -f "$STATE/az-logged-out"
    printf '[]\n'
    ;;
  *) exit 64 ;;
esac
STUB
  write_stub wifi-sync <<'STUB'
case "${1:-}" in
  remind) cat "$STATE/wifi-reminder" 2>/dev/null || true ;;
  '') rm -f "$STATE/wifi-reminder" ;;
  *) exit 64 ;;
esac
STUB
}

# Tailscale that has no node, whatever the test changes.
given_no_tailnet_node() {
  printf 'NeedsLogin\n' >"$STATE/backend"
  write_stub tailscale <<'STUB'
printf '{"BackendState":"NeedsLogin","Self":null}\n'
STUB
}

# Feed one answer per argument through a pty, since desktop-setup refuses to
# run without one. The pipe stays open until the command has read every answer,
# because script ends the session when its input ends.
run_setup() {
  # shellcheck disable=SC2016
  run "$REAL_BASH" -c 'tool="$1" path="$2" bash="$3" setup="$4"; shift 4
    { sleep 0.4; for answer; do printf "%s\n" "$answer"; done; sleep 0.8; } \
      | "$tool" -qec "stty -echo; exec env PATH=$path $bash $setup" /dev/null' \
    _ "$SCRIPT_TOOL" "$STUBS:$REAL_TOOLS" "$REAL_BASH" "$SETUP" "$@"
  output="${output//$'\r'/}"
}

calls() { cat "$CALLS"; }

assert_summary() {
  local title="$1" label="$2"
  grep -qE "^  $title +$label\$" <<<"$output" || fail "summary lacks '$title $label': $output"
}

@test "test_a_set_up_machine_prints_only_checks_and_exits_zero" {
  run_setup

  [ "$status" -eq 0 ]
  [[ "$output" != *'[Enter'* ]] || fail "prompted on a set up machine: $output"
  [ "$(grep -c '✓' <<<"$output")" -eq 7 ] || fail "expected seven checks: $output"
  [[ "$output" != *' skipped'* && "$output" != *' failed'* ]] || fail "not all done: $output"
  [[ "$output" == *'Rerun desktop-setup anytime to resume'* ]]
  ! grep -q '^tailscale up\|^codex login$\|^az login\|^claude auth login\|^wifi-sync $' "$CALLS" || fail "acted on a set up machine: $(calls)"
}

@test "test_summary_lists_every_step_as_done" {
  run_setup

  assert_summary 'Tailscale sign-in' 'done'
  assert_summary 'Tailscale key expiry' 'done'
  assert_summary 'AI gateway reachable' 'done'
  assert_summary 'Codex sign-in' 'done'
  assert_summary 'Claude Code claude.ai login' 'done'
  assert_summary 'Azure CLI login' 'done'
  assert_summary 'Wi-Fi networks in Bitwarden' 'done'
}

@test "test_tailscale_sign_in_runs_tailscale_up_with_all_four_flags" {
  printf 'NeedsLogin\n' >"$STATE/backend"

  run_setup ''

  [ "$status" -eq 0 ]
  grep -qxF "$UP_COMMAND" "$CALLS" || fail "no tailscale up with the four flags: $(calls)"
  [[ "$output" == *'https://login.tailscale.com/a/fixture'* ]]
  assert_summary 'Tailscale sign-in' 'done'
}

@test "test_a_device_waiting_for_approval_names_the_admin_page_and_rechecks_after_enter" {
  printf 'NeedsMachineAuth\n' >"$STATE/backend"

  BACKEND_RUNNING_AT=2 run_setup ''

  [ "$status" -eq 0 ]
  [[ "$output" == *"A work-tailnet admin must approve this device at $ADMIN_URL."* ]] || fail "no approval message: $output"
  ! grep -q '^tailscale up' "$CALLS" || fail "ran tailscale up for a device that only awaits approval"
  assert_summary 'Tailscale sign-in' 'done'
}

@test "test_an_approval_that_has_not_happened_asks_again_until_skipped" {
  printf 'NeedsMachineAuth\n' >"$STATE/backend"

  run_setup '' s

  [ "$status" -eq 0 ]
  [ "$(grep -c 'must approve this device' <<<"$output")" -eq 2 ] || fail "did not ask again: $output"
  assert_summary 'Tailscale sign-in' skipped
}

@test "test_an_expiring_key_gets_disable_instructions_and_enter_rechecks" {
  rm "$STATE/key-never-expires"

  KEY_EXPIRY_OFF_AT=4 run_setup ''

  [ "$status" -eq 0 ]
  [[ "$output" == *"Open $ADMIN_URL, find this machine (glados),"* ]] || fail "no instructions: $output"
  [[ "$output" == *'"Disable key expiry"'* ]]
  assert_summary 'Tailscale key expiry' 'done'
}

@test "test_a_key_that_still_expires_can_be_skipped" {
  rm "$STATE/key-never-expires"

  run_setup s

  [ "$status" -eq 0 ]
  assert_summary 'Tailscale key expiry' skipped
}

@test "test_key_expiry_fails_when_the_machine_is_not_on_the_tailnet" {
  given_no_tailnet_node

  run_setup s

  [ "$status" -eq 1 ]
  assert_summary 'Tailscale sign-in' skipped
  assert_summary 'Tailscale key expiry' failed
}

@test "test_a_gateway_that_is_not_reachable_is_reported_as_failed" {
  : >"$STATE/no-route"
  printf 000 >"$STATE/gateway-code"

  run_setup

  [ "$status" -eq 1 ]
  [[ "$output" == *'135.119.134.202 does not route through tailscale0'* ]] || fail "no route hint: $output"
  [[ "$output" == *'answered 000, not the expected 401'* ]] || fail "no status hint: $output"
  assert_summary 'AI gateway reachable' failed
  assert_summary 'Codex sign-in' 'done'
}

@test "test_codex_that_is_not_signed_in_runs_codex_login" {
  : >"$STATE/codex-logged-out"

  run_setup ''

  [ "$status" -eq 0 ]
  grep -qxF 'codex login' "$CALLS" || fail "no codex login: $(calls)"
  assert_summary 'Codex sign-in' 'done'
}

@test "test_claude_code_that_is_not_logged_in_runs_claude_auth_login" {
  : >"$STATE/claude-logged-out"

  run_setup ''

  [ "$status" -eq 0 ]
  [[ "$output" == *'Only claude.ai artifacts need this'* ]]
  grep -qxF 'claude auth login --claudeai' "$CALLS" || fail "no claude auth login: $(calls)"
  assert_summary 'Claude Code claude.ai login' 'done'
}

@test "test_azure_that_is_not_logged_in_prompts_for_the_tenant_and_logs_in_by_device_code" {
  : >"$STATE/az-logged-out"

  run_setup contoso.example

  [ "$status" -eq 0 ]
  [[ "$output" == *'Tenant id or domain'* ]]
  grep -qxF 'az login --use-device-code --tenant contoso.example' "$CALLS" || fail "no az login: $(calls)"
  [[ "$output" == *'https://microsoft.com/devicelogin'* ]] || fail "device-code instructions were hidden: $output"
  assert_summary 'Azure CLI login' 'done'
}

@test "test_unsaved_wifi_networks_are_offered_to_wifi_sync" {
  printf 'wifi-sync: Wi-Fi networks on this machine that are not in Bitwarden: Cafe. Run wifi-sync to save, keep, or forget them.\n' >"$STATE/wifi-reminder"

  run_setup ''

  [ "$status" -eq 0 ]
  [[ "$output" == *'not in Bitwarden: Cafe'* ]]
  grep -qxF 'wifi-sync ' "$CALLS" || fail "wifi-sync did not run: $(calls)"
  assert_summary 'Wi-Fi networks in Bitwarden' 'done'
}

@test "test_skip_answers_are_recorded_as_skipped_and_do_not_fail_the_run" {
  printf 'NeedsLogin\n' >"$STATE/backend"
  : >"$STATE/codex-logged-out"
  : >"$STATE/claude-logged-out"
  : >"$STATE/az-logged-out"
  printf 'wifi-sync: Wi-Fi networks on this machine that are not in Bitwarden: Cafe.\n' >"$STATE/wifi-reminder"

  # One skip each for the tailscale sign-in, codex, claude, the az tenant, and wifi.
  run_setup s s s s s

  [ "$status" -eq 0 ]
  ! grep -q '^tailscale up\|^codex login$\|^claude auth login\|^az login\|^wifi-sync $' "$CALLS" || fail "acted after a skip: $(calls)"
  assert_summary 'Tailscale sign-in' skipped
  assert_summary 'Codex sign-in' skipped
  assert_summary 'Claude Code claude.ai login' skipped
  assert_summary 'Azure CLI login' skipped
  assert_summary 'Wi-Fi networks in Bitwarden' skipped
}

@test "test_a_missing_tool_fails_its_step_with_a_hint_and_the_run_goes_on" {
  rm "$STUBS/codex"

  run_setup

  [ "$status" -eq 1 ]
  [[ "$output" == *'codex is not on PATH. Run update-agent-tools to install it.'* ]] || fail "no hint: $output"
  assert_summary 'Codex sign-in' failed
  assert_summary 'Claude Code claude.ai login' 'done'
  assert_summary 'Wi-Fi networks in Bitwarden' 'done'
}

@test "test_without_a_terminal_it_prints_the_steps_and_asks_nothing" {
  run --separate-stderr env PATH="$STUBS:$REAL_TOOLS" "$REAL_BASH" "$SETUP" </dev/null

  [ "$status" -eq 1 ]
  [[ "$stderr" == *'standard input is not a terminal'* ]]
  [[ "$output" == *'1. Tailscale sign-in'* && "$output" == *'7. Wi-Fi networks in Bitwarden'* ]] || fail "steps not listed: $output"
  [ ! -s "$CALLS" ] || fail "ran a step without a terminal: $(calls)"
}
