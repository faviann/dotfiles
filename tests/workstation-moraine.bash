#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=tests/lib/rendered-configuration.bash
source "$REPO_ROOT/tests/lib/rendered-configuration.bash"

rendered_moraine_config() {
  rendered_json '.moraineConfig' \
    "$REPO_ROOT#homeConfigurations.workstation.config.home.file.\".moraine/config.toml\".text" \
    --apply 'text: builtins.fromTOML (builtins.unsafeDiscardStringContext text)'
}

test_moraine_profile_uses_one_integrity_pinned_release_bundle() {
  local release

  release="$(
    rendered_json '.moraineRelease' \
      "$REPO_ROOT#homeConfigurations.workstation.config.home.packages" \
      --apply '
        packages:
        let
          package = builtins.head (
            builtins.filter
              (package: (package.pname or package.name) == "moraine")
              packages
          );
        in
        package.passthru.release
      '
  )" || fail 'could not render the Moraine release package'

  jq -e '
    (.version == "v0.7.3") and
    (.target == "x86_64-unknown-linux-gnu") and
    (.hash == "sha256-JqjV/LL43yt1REfSyZBpYe/kHt7Y4ISqPfOB7C6ArX0=") and
    (.executables == ["moraine", "moraine-ingest", "moraine-monitor", "moraine-mcp"])
  ' <<<"$release" >/dev/null \
    || fail 'workstation does not use the expected single pinned Moraine release bundle'
}

test_moraine_configures_active_and_archived_codex_sources_with_backfill() {
  local config

  config="$(rendered_moraine_config)" \
    || fail 'could not render the Moraine configuration'

  jq -e '
    (.ingest.backfill_on_start == true) and
    (.ingest.sources == [
      {
        name: "codex-active",
        harness: "codex",
        enabled: true,
        glob: "~/.codex/sessions/**/*.jsonl",
        watch_root: "~/.codex/sessions"
      },
      {
        name: "codex-archived",
        harness: "codex",
        enabled: true,
        glob: "~/.codex/archived_sessions/*.jsonl",
        watch_root: "~/.codex/archived_sessions"
      }
    ])
  ' <<<"$config" >/dev/null \
    || fail 'Moraine does not declare the expected active and archived Codex sources'
}

test_moraine_config_keeps_redaction_and_the_default_local_topology() {
  local config

  config="$(rendered_moraine_config)" \
    || fail 'could not render the Moraine configuration'

  # Moraine calls its local per-user socket service "central". It is the same
  # loopback-only unified backend asserted below, not a remote data topology.
  jq -e '
    (.identity.author == "faviann@gmail.com") and
    (.redaction.ruleset == "builtin") and
    (.redaction | has("dangerously_skip_secret_redaction") | not) and
    (.backend == { bind: "127.0.0.1", start_on_up: true }) and
    (.monitor.port == 8080) and
    (.mcp.use_central_server == true) and
    (.mcp.central_socket_path == "mcp.sock") and
    (.ingest.state_dir == "~/.moraine/ingestor") and
    (.runtime.root_dir == "~/.moraine") and
    (.runtime.logs_dir == "logs") and
    (.runtime.pids_dir == "run") and
    (.runtime.managed_clickhouse_dir == "~/.moraine/clickhouse/current") and
    (.runtime.clickhouse_auto_install == true) and
    (.runtime.clickhouse_version == "v25.12.5.44-stable") and
    (.runtime.service_bin_dir | test("^/nix/store/[^/]+-moraine-0\\.7\\.3/bin$")) and
    (has("clickhouse") | not) and
    (has("backends") | not) and
    (has("routes") | not)
  ' <<<"$config" >/dev/null \
    || fail 'Moraine weakens redaction, leaves its runtime root, or configures non-local topology'
}

test_moraine_service_manages_the_local_stack_in_the_headless_user_session() {
  local services

  services="$(
    rendered_json '.moraineServices' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.services" \
      --apply 'services: {
        moraine = services.moraine;
        clickhouse = services.moraine-clickhouse;
        migrate = services.moraine-migrate;
        ingest = services.moraine-ingest;
        backend = services.moraine-backend;
      }'
  )" || fail 'could not render the Moraine user services'

  jq -e '
    (.moraine.Unit.Requires == ["moraine-ingest.service", "moraine-backend.service"]) and
    (.moraine.Unit.After == ["moraine-ingest.service", "moraine-backend.service"]) and
    (.moraine.Service.Type == "oneshot") and
    (.moraine.Service.RemainAfterExit == true) and
    (.moraine.Install.WantedBy == ["default.target"]) and
    ([.clickhouse, .ingest, .backend] | all(
      .Unit.PartOf == ["moraine.service"] and
      .Service.Restart == "on-failure" and
      .Service.RestartSec == 5
    )) and
    (.clickhouse.Service.ExecStart[0] | test("/moraine --config %h/\\.moraine/config\\.toml run clickhouse$")) and
    (.migrate.Unit.Requires == ["moraine-clickhouse.service"]) and
    (.migrate.Unit.After == ["moraine-clickhouse.service"]) and
    (.migrate.Unit.PartOf == ["moraine.service"]) and
    (.migrate.Service.Type == "oneshot") and
    (.migrate.Service.RemainAfterExit == true) and
    (.migrate.Service.Restart == "on-failure") and
    (.migrate.Service.ExecStart[0] | test("/moraine --config %h/\\.moraine/config\\.toml db migrate$")) and
    ([.ingest, .backend] | all(
      .Unit.Requires == ["moraine-migrate.service"] and
      .Unit.After == ["moraine-migrate.service"]
    )) and
    (.ingest.Service.ExecStart[0] | test("/moraine --config %h/\\.moraine/config\\.toml run ingest$")) and
    (.backend.Service.ExecStart[0] | test("/moraine --config %h/\\.moraine/config\\.toml run backend$"))
  ' <<<"$services" >/dev/null \
    || fail 'Moraine service does not manage the local stack under the headless user lifecycle'
}

test_codex_mcp_registration_invokes_the_pinned_moraine_stdio_command() {
  local activation
  local config_before_second_activation
  local registration
  local test_dir

  activation="$(
    rendered_raw '.moraineCodexMcpActivation' \
      "$REPO_ROOT#homeConfigurations.workstation.config.home.activation.configureMoraineCodexMcp.data"
  )" || fail 'could not render the Moraine Codex MCP activation'

  grep -Eq 'codex mcp get moraine --json' <<<"$activation" \
    || fail 'Moraine Codex MCP activation does not inspect the current registration'
  grep -Eq 'codex mcp add moraine -- /nix/store/[^/]+-moraine-0\.7\.3/bin/moraine run mcp' \
    <<<"$activation" \
    || fail 'Codex MCP does not invoke the pinned Moraine stdio command directly'
  if grep -Eq 'moraine setup|curl|plugin|https?://' <<<"$activation"; then
    fail 'Moraine Codex MCP activation uses guided setup or fetches integration content'
  fi

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  mkdir -p "$test_dir/.codex"
  printf '%s\n' \
    'model = "preserved-model"' \
    '' \
    '[mcp_servers.preserved]' \
    'command = "preserved-command"' \
    >"$test_dir/.codex/config.toml"

  HOME="$test_dir" CODEX_HOME="$test_dir/.codex" bash -c "$activation" >/dev/null \
    || fail 'Moraine Codex MCP activation failed against an isolated Codex home'
  registration="$(
    CODEX_HOME="$test_dir/.codex" codex mcp get moraine --json
  )" || fail 'Moraine Codex MCP registration was not materialized'

  jq -e '
    (.enabled == true) and
    (.transport.type == "stdio") and
    (.transport.command | test("^/nix/store/[^/]+-moraine-0\\.7\\.3/bin/moraine$")) and
    (.transport.args == ["run", "mcp"])
  ' <<<"$registration" >/dev/null \
    || fail 'materialized Moraine Codex MCP registration is not the pinned stdio command'
  grep -Fxq 'model = "preserved-model"' "$test_dir/.codex/config.toml" \
    || fail 'Moraine Codex MCP activation replaced unrelated Codex configuration'
  CODEX_HOME="$test_dir/.codex" codex mcp get preserved --json >/dev/null \
    || fail 'Moraine Codex MCP activation removed an unrelated MCP registration'

  config_before_second_activation="$(sha256sum "$test_dir/.codex/config.toml")"
  HOME="$test_dir" CODEX_HOME="$test_dir/.codex" bash -c "$activation" >/dev/null \
    || fail 'second Moraine Codex MCP activation failed'
  [[ "$(sha256sum "$test_dir/.codex/config.toml")" == "$config_before_second_activation" ]] \
    || fail 'unchanged Moraine Codex MCP registration was rewritten'
}

# shellcheck source=tests/lib/suite-dispatch.bash
source "$REPO_ROOT/tests/lib/suite-dispatch.bash"

readonly test_cases=(
  test_moraine_profile_uses_one_integrity_pinned_release_bundle
  test_moraine_configures_active_and_archived_codex_sources_with_backfill
  test_moraine_config_keeps_redaction_and_the_default_local_topology
  test_moraine_service_manages_the_local_stack_in_the_headless_user_session
  test_codex_mcp_registration_invokes_the_pinned_moraine_stdio_command
)

suite_dispatch 'workstation-local Moraine producer' "$@"
