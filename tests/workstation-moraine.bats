#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  common_setup
}

rendered_moraine_config() {
  rendered_json '.moraineConfig' \
    "$REPO_ROOT#homeConfigurations.workstation.config.home.file.\".moraine/config.toml\".text" \
    --apply 'text: builtins.fromTOML (builtins.unsafeDiscardStringContext text)'
}

@test "test_moraine_profile_uses_one_integrity_pinned_source_build" {
  local built_package
  local executable
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
        {
          inherit (package) version;
          inherit (package.passthru.release)
            interactiveQueryMemoryBytes
            releaseAssetHash
            serverMemoryBytes
            rustToolchainVersion
            sourceHash
            sourceRevision
            sourceVersion;
          userQueryMemoryBytes = package.passthru.release.userQueryMemoryBytes;
          source = "https://github.com/eric-tramel/moraine/commit/" + package.passthru.release.sourceRevision;
          storePath = builtins.unsafeDiscardStringContext (builtins.toString package);
          hasReleasePassthru = package.passthru ? release;
        }
      '
  )" || fail 'could not render the Moraine source package'

  jq -e '
    (.version == "0.7.3+g91cd7a13ba29") and
    (.sourceVersion == "0.7.3") and
    (.sourceRevision == "91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9") and
    (.sourceHash == "sha256-5ngGU2CjP8X+0rsL2wquvrMpvJK4Z4Gpl8AfiiqI/sM=") and
    (.releaseAssetHash == "sha256-JqjV/LL43yt1REfSyZBpYe/kHt7Y4ISqPfOB7C6ArX0=") and
    (.rustToolchainVersion == "1.96.0") and
    (.interactiveQueryMemoryBytes == 8589934592) and
    (.userQueryMemoryBytes == 17179869184) and
    (.serverMemoryBytes == 51539607552) and
    (.source == "https://github.com/eric-tramel/moraine/commit/91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9") and
    (.storePath | test("^/nix/store/[^/]+-moraine-0\\.7\\.3\\+g91cd7a13ba29$")) and
    (.hasReleasePassthru == true)
  ' <<<"$release" >/dev/null \
    || fail 'workstation does not use the expected commit-pinned and locally patched Moraine source build'

  built_package="$(jq -r '.storePath' <<<"$release")"
  if [[ -z "${TEST_WORKSTATION_RENDERED_CONFIGURATION:-}" ]]; then
    built_package="$(nix build --no-link --print-out-paths "$REPO_ROOT#moraine")" \
      || fail 'could not build the pinned Moraine source package'
  fi
  [[ "$built_package" == "$(jq -r '.storePath' <<<"$release")" ]] \
    || fail 'built Moraine package differs from the workstation source build'
  for executable in moraine moraine-ingest moraine-monitor moraine-mcp; do
    [[ -x "$built_package/bin/$executable" ]] \
      || fail "Moraine source package does not install $executable"
  done
}

@test "test_moraine_configures_codex_and_claude_sources_with_backfill" {
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
      },
      {
        name: "claude-projects",
        harness: "claude-code",
        enabled: true,
        glob: "~/.claude/projects/**/*.jsonl",
        watch_root: "~/.claude/projects"
      }
    ])
  ' <<<"$config" >/dev/null \
    || fail 'Moraine does not declare only the deployment-owned Codex and Claude Code sources'
}

@test "test_moraine_config_keeps_redaction_and_the_default_local_topology" {
  local config

  config="$(rendered_moraine_config)" \
    || fail 'could not render the Moraine configuration'

  jq -e '
    (.identity.author == "faviann@gmail.com") and
    (has("redaction") | not) and
    ((.backend // {}) | has("auth_token") | not) and
    (.backend == { bind: "127.0.0.1" }) and
    (.monitor == { port: 8080 }) and
    (has("mcp") | not) and
    (.runtime.root_dir == "~/.moraine") and
    (.runtime.managed_clickhouse_dir == "~/.moraine/clickhouse/current") and
    (.runtime.service_bin_dir | test("^/nix/store/[^/]+-moraine-0\\.7\\.3\\+g91cd7a13ba29/bin$")) and
    (has("clickhouse") | not) and
    (has("backends") | not) and
    (has("routes") | not)
  ' <<<"$config" >/dev/null \
    || fail 'Moraine weakens redaction, leaves its runtime root, or configures non-local topology'
}

@test "test_moraine_service_owns_and_restarts_the_upstream_stack" {
  local fake_moraine
  local invocation_log
  local runner
  local test_dir
  local topology

  topology="$(
    rendered_json '.moraineServiceTopology' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.services" \
      --apply 'services: {
        names = builtins.filter
          (name: builtins.match "moraine.*" name != null)
          (builtins.attrNames services);
        service = services.moraine;
      }'
  )" || fail 'could not render the Moraine user-service topology'

  jq -e '
    (.names == ["moraine"]) and
    (.service.Unit.Description == "Workstation-local Moraine producer") and
    (.service.Unit."X-Restart-Triggers" == [
      (.service.Unit."X-Restart-Triggers"[0] |
        select(test("^/nix/store/[^/]+-hm_\\.moraineconfig\\.toml$")))
    ]) and
    (.service.Service.Type == "simple") and
    (.service.Service.Restart == "on-failure") and
    (.service.Service.RestartSec == 5) and
    (.service.Service.ExecStart[0] | test("/bin/moraine-service /nix/store/[^/]+-moraine-0\\.7\\.3\\+g91cd7a13ba29/bin/moraine %h/\\.moraine/config\\.toml$")) and
    (.service.Service.ExecStop | test("/moraine --config %h/\\.moraine/config\\.toml down$")) and
    (.service.Install.WantedBy == ["default.target"])
  ' <<<"$topology" >/dev/null \
    || fail 'Moraine service does not own the upstream stack lifecycle'

  test_dir="$(mktemp -d)"
  invocation_log="$test_dir/invocations"
  fake_moraine="$test_dir/moraine"
  # The variables in these literal lines are evaluated by the fake executable.
  # shellcheck disable=SC2016
  printf '%s\n' \
    "#!$(command -v bash)" \
    'printf '\''%s\n'\'' "$*" >>"$TEST_INVOCATION_LOG"' \
    'if [[ "$*" == *" status" ]]; then' \
    '  count="$(wc -l <"$TEST_INVOCATION_LOG")"' \
    '  if (( count < 3 )); then' \
    '    printf '\''%s\n'\'' '\''{"services":[{"service":"clickhouse","state":"running"},{"service":"ingest","state":"running"},{"service":"backend","state":"running"}],"doctor":{"clickhouse_healthy":true,"database_exists":true,"pending_migrations":[],"missing_tables":[],"errors":[]}}'\''' \
    '  else' \
    '    printf '\''%s\n'\'' '\''{"services":[{"service":"clickhouse","state":"running"},{"service":"ingest","state":"running"},{"service":"backend","state":"stopped"}],"doctor":{"clickhouse_healthy":true,"database_exists":true,"pending_migrations":[],"missing_tables":[],"errors":[]}}'\''' \
    '  fi' \
    '  (( count < 4 ))' \
    'fi' \
    >"$fake_moraine"
  chmod +x "$fake_moraine"

  runner="$REPO_ROOT/scripts/moraine-service"
  if TEST_INVOCATION_LOG="$invocation_log" \
    MORAINE_STATUS_INTERVAL_SECONDS=0 \
    bash "$runner" "$fake_moraine" "$test_dir/config.toml"; then
    fail 'Moraine service runner stayed healthy after the upstream stack became unhealthy'
  fi
  diff -u \
    <(printf '%s\n' \
      "--config $test_dir/config.toml up" \
      "--config $test_dir/config.toml --output json status" \
      "--config $test_dir/config.toml --output json status") \
    "$invocation_log" \
    || fail 'Moraine service runner does not start upstream before monitoring stack health'
}

@test "test_moraine_leaves_user_codex_configuration_unmanaged" {
  local boundary

  boundary="$(
    rendered_json '.moraineCodexBoundary' \
      "$REPO_ROOT#homeConfigurations.workstation.config" \
      --apply 'config: {
        managesConfig = config.home.file ? ".codex/config.toml";
        hasRegistrationActivation = config.home.activation ? configureMoraineCodexMcp;
      }'
  )" || fail 'could not render the Moraine Codex ownership boundary'

  jq -e '
    (.managesConfig == false) and
    (.hasRegistrationActivation == false)
  ' <<<"$boundary" >/dev/null \
    || fail 'Moraine takes ownership of user-managed Codex configuration'
}
