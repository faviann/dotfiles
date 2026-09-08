#!/usr/bin/env bats
set -euo pipefail

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
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

@test "test_herdr_service_runs_the_supported_foreground_server" {
  local rendered_service

  rendered_service="$(rendered_herdr_service)" \
    || fail 'could not render the Herdr user service'

  jq -e \
    '.Service.ExecStart == ["/home/faviann/.local/bin/herdr server"]' \
    <<<"$rendered_service" >/dev/null \
    || fail 'Herdr does not execute the supported foreground server entrypoint directly'
}

@test "test_herdr_service_has_a_deterministic_process_environment" {
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

@test "test_herdr_service_restarts_failures_after_a_bounded_delay" {
  local rendered_service

  rendered_service="$(rendered_herdr_service)" \
    || fail 'could not render the Herdr user service'

  jq -e '
    (.Service.Restart == "on-failure") and
    (.Service.RestartSec == 5)
  ' <<<"$rendered_service" >/dev/null \
    || fail 'Herdr service does not use its bounded failure-restart policy'
}

@test "test_herdr_service_leaves_normal_termination_to_herdr" {
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

@test "test_herdr_service_activates_with_the_normal_user_target" {
  local rendered_service

  rendered_service="$(rendered_herdr_service)" \
    || fail 'could not render the Herdr user service'

  jq -e '
    (.Install.WantedBy == ["default.target"]) and
    ((.Install.RequiredBy // []) == []) and
    ((.Install.UpheldBy // []) == [])
  ' <<<"$rendered_service" >/dev/null \
    || fail 'Herdr service does not activate under the normal user target'
}

@test "test_herdr_supervision_has_no_automatic_migration_or_coupled_lifecycle" {
  local rendered_activation
  local rendered_service

  rendered_service="$(rendered_herdr_service)" \
    || fail 'could not render the Herdr user service'
  rendered_activation="$(rendered_workstation_activation)" \
    || fail 'could not render the workstation activation configuration'

  jq -e '
    ((.Install.RequiredBy // []) == []) and
    ((.Install.UpheldBy // []) == []) and
    ((.Unit.Requires // []) == []) and
    ((.Unit.BindsTo // []) == []) and
    ((.Unit.PartOf // []) == []) and
    (.Service | has("ExecStop") | not) and
    (.Service | has("ExecStopPost") | not) and
    (.Service | has("ExecReload") | not) and
    (.Service | has("KillSignal") | not) and
    ([.Service | .. | strings | select(test("--daemon|pid.file|migrat|pane|session"; "i"))] == [])
  ' <<<"$rendered_service" >/dev/null \
    || fail 'Herdr unit adds a coupled lifecycle or custom pane management'
  jq -e \
    '[to_entries[] | select(.value | test("herdr"; "i"))] == []' \
    <<<"$rendered_activation" >/dev/null \
    || fail 'workstation activation contains a Herdr lifecycle or migration action'
}
