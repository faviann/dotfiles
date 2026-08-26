#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

rendered_json() {
  local fixture_filter="$1"
  local installable="$2"
  shift 2

  if [[ -n "${TEST_WORKSTATION_RENDERED_CONFIGURATION:-}" ]]; then
    jq -ce "$fixture_filter" "$TEST_WORKSTATION_RENDERED_CONFIGURATION"
    return
  fi

  nix eval --json "$installable" "$@"
}

rendered_herdr_service() {
  rendered_json '.herdrService' \
    "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.services.herdr"
}

rendered_workstation_activation() {
  rendered_json '.workstationActivation' \
    "$REPO_ROOT#homeConfigurations.workstation.config.home.activation" \
    --apply 'activation: builtins.mapAttrs (_: entry: entry.data or "") activation'
}

test_herdr_service_runs_the_supported_foreground_server() {
  local rendered_service

  rendered_service="$(rendered_herdr_service)" \
    || fail 'could not render the Herdr user service'

  jq -e \
    '.Service.ExecStart == ["/home/faviann/.local/bin/herdr server"]' \
    <<<"$rendered_service" >/dev/null \
    || fail 'Herdr does not execute the supported foreground server entrypoint directly'
}

test_herdr_service_has_a_deterministic_process_environment() {
  local rendered_service

  rendered_service="$(rendered_herdr_service)" \
    || fail 'could not render the Herdr user service'

  jq -e '
    (.Service.Type == "simple") and
    (.Service.ExecStart == ["/home/faviann/.local/bin/herdr server"]) and
    (.Service.WorkingDirectory == "/home/faviann") and
    (.Service.Environment == [
      "PATH=/home/faviann/.local/bin:/home/faviann/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin"
    ])
  ' <<<"$rendered_service" >/dev/null \
    || fail 'Herdr service process environment is not deterministic and self-contained'
}

test_herdr_service_restarts_failures_after_a_bounded_delay() {
  local rendered_service

  rendered_service="$(rendered_herdr_service)" \
    || fail 'could not render the Herdr user service'

  jq -e '
    (.Service.Restart == "on-failure") and
    (.Service.RestartSec == 5)
  ' <<<"$rendered_service" >/dev/null \
    || fail 'Herdr service does not use its bounded failure-restart policy'
}

test_herdr_service_leaves_normal_termination_to_herdr() {
  local rendered_service

  rendered_service="$(rendered_herdr_service)" \
    || fail 'could not render the Herdr user service'

  jq -e '
    (.Service.Type == "simple") and
    (.Service.ExecStart == ["/home/faviann/.local/bin/herdr server"]) and
    (.Service | has("ExecStop") | not) and
    (.Service | has("ExecStopPost") | not) and
    (.Service | has("PIDFile") | not) and
    (.Service | has("NotifyAccess") | not)
  ' <<<"$rendered_service" >/dev/null \
    || fail 'Herdr service overrides the foreground server graceful-termination contract'
}

test_herdr_service_is_staged_without_target_or_activation() {
  local rendered_activation
  local rendered_service

  rendered_service="$(rendered_herdr_service)" \
    || fail 'could not render the Herdr user service'
  rendered_activation="$(rendered_workstation_activation)" \
    || fail 'could not render the workstation activation configuration'

  jq -e '
    ((.Install.WantedBy // []) == []) and
    ((.Install.RequiredBy // []) == [])
  ' <<<"$rendered_service" >/dev/null \
    || fail 'Herdr service is enabled in a user target'
  jq -e \
    '[to_entries[] | select(.value | test("herdr.*(start|enable)|(start|enable).*herdr"; "i"))] == []' \
    <<<"$rendered_activation" >/dev/null \
    || fail 'workstation activation starts or enables Herdr'
}

test_herdr_staging_does_not_take_over_the_detached_server_or_panes() {
  local rendered_activation
  local rendered_service

  rendered_service="$(rendered_herdr_service)" \
    || fail 'could not render the Herdr user service'
  rendered_activation="$(rendered_workstation_activation)" \
    || fail 'could not render the workstation activation configuration'

  jq -e '
    ((.Install.WantedBy // []) == []) and
    ((.Install.RequiredBy // []) == []) and
    ((.Unit.Requires // []) == []) and
    ((.Unit.BindsTo // []) == []) and
    ((.Unit.PartOf // []) == []) and
    (.Service | has("ExecStop") | not) and
    (.Service | has("ExecStopPost") | not) and
    (.Service | has("ExecReload") | not) and
    (.Service | has("KillSignal") | not) and
    ([.Service | .. | strings | select(test("--daemon|pid.file|migrat|pane|session"; "i"))] == [])
  ' <<<"$rendered_service" >/dev/null \
    || fail 'staged Herdr unit takes ownership of the detached server or its panes'
  jq -e \
    '[to_entries[] | select(.value | test("herdr"; "i"))] == []' \
    <<<"$rendered_activation" >/dev/null \
    || fail 'workstation activation contains a Herdr lifecycle or migration action'
}

test_workstation_herdr_documentation_explains_the_deferred_cutover() {
  local herdr_section
  local normalized_section

  herdr_section="$(
    sed -n '/^## Workstation herdr$/,$p' "$REPO_ROOT/README.md"
  )" || fail 'could not read the Workstation herdr operating section'
  normalized_section="${herdr_section//$'\n'/ }"

  grep -Eiq 'activation[^.]*deferred[^.]*cutover|deferred[^.]*activation[^.]*cutover' \
    <<<"$normalized_section" \
    || fail 'Workstation herdr documentation does not defer activation to cutover'
  grep -Fiq 'server shutdown ends pane processes' <<<"$normalized_section" \
    || fail 'Workstation herdr documentation does not explain the pane-process risk'
}

# shellcheck source=tests/lib/suite-dispatch.bash
source "$REPO_ROOT/tests/lib/suite-dispatch.bash"

readonly test_cases=(
  test_herdr_service_runs_the_supported_foreground_server
  test_herdr_service_has_a_deterministic_process_environment
  test_herdr_service_restarts_failures_after_a_bounded_delay
  test_herdr_service_leaves_normal_termination_to_herdr
  test_herdr_service_is_staged_without_target_or_activation
  test_herdr_staging_does_not_take_over_the_detached_server_or_panes
  test_workstation_herdr_documentation_explains_the_deferred_cutover
)

suite_dispatch 'workstation Herdr supervised-service staging' "$@"
