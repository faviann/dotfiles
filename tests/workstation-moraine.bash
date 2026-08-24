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

rendered_moraine_config() {
  rendered_json '.moraineConfig' \
    "$REPO_ROOT#homeConfigurations.workstation.config.home.file.\".moraine/config.toml\".text" \
    --apply 'text: builtins.fromTOML (builtins.unsafeDiscardStringContext text)'
}

test_moraine_profile_uses_one_integrity_pinned_release_bundle() {
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
          hash = package.src.outputHash;
          source = package.src.url;
          storePath = builtins.unsafeDiscardStringContext (builtins.toString package);
          hasReleasePassthru = package.passthru ? release;
        }
      '
  )" || fail 'could not render the Moraine release package'

  jq -e '
    (.version == "0.7.3") and
    (.hash == "sha256-JqjV/LL43yt1REfSyZBpYe/kHt7Y4ISqPfOB7C6ArX0=") and
    (.source == "https://github.com/eric-tramel/moraine/releases/download/v0.7.3/moraine-bundle-x86_64-unknown-linux-gnu.tar.gz") and
    (.storePath | test("^/nix/store/[^/]+-moraine-0\\.7\\.3$")) and
    (.hasReleasePassthru == false)
  ' <<<"$release" >/dev/null \
    || fail 'workstation does not use the expected single pinned Moraine release bundle'

  built_package="$(jq -r '.storePath' <<<"$release")"
  if [[ -z "${TEST_WORKSTATION_RENDERED_CONFIGURATION:-}" ]]; then
    built_package="$(nix build --no-link --print-out-paths "$REPO_ROOT#moraine")" \
      || fail 'could not build the pinned Moraine release bundle'
  fi
  [[ "$built_package" == "$(jq -r '.storePath' <<<"$release")" ]] \
    || fail 'built Moraine package differs from the workstation release bundle'
  for executable in moraine moraine-ingest moraine-monitor moraine-mcp; do
    [[ -x "$built_package/bin/$executable" ]] \
      || fail "Moraine release bundle does not install $executable"
  done
}

test_moraine_configures_codex_and_claude_sources_with_backfill() {
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

test_moraine_config_keeps_redaction_and_the_default_local_topology() {
  local config

  config="$(rendered_moraine_config)" \
    || fail 'could not render the Moraine configuration'

  jq -e '
    (.identity.author == "faviann@gmail.com") and
    (has("redaction") | not) and
    ((.backend // {}) | has("auth_token") | not) and
    (has("backend") | not) and
    (has("monitor") | not) and
    (has("mcp") | not) and
    (.runtime.root_dir == "~/.moraine") and
    (.runtime.managed_clickhouse_dir == "~/.moraine/clickhouse/current") and
    (.runtime.service_bin_dir | test("^/nix/store/[^/]+-moraine-0\\.7\\.3/bin$")) and
    (has("clickhouse") | not) and
    (has("backends") | not) and
    (has("routes") | not)
  ' <<<"$config" >/dev/null \
    || fail 'Moraine weakens redaction, leaves its runtime root, or configures non-local topology'
}

test_moraine_service_owns_and_restarts_the_upstream_stack() {
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
    (.service.Service.ExecStart[0] | test("/bin/moraine-service /nix/store/[^/]+-moraine-0\\.7\\.3/bin/moraine %h/\\.moraine/config\\.toml$")) and
    (.service.Service.ExecStop | test("/moraine --config %h/\\.moraine/config\\.toml down$")) and
    (.service.Install.WantedBy == ["default.target"])
  ' <<<"$topology" >/dev/null \
    || fail 'Moraine service does not own the upstream stack lifecycle'

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
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

test_moraine_leaves_user_codex_configuration_unmanaged() {
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

# shellcheck source=tests/lib/suite-dispatch.bash
source "$REPO_ROOT/tests/lib/suite-dispatch.bash"

readonly test_cases=(
  test_moraine_profile_uses_one_integrity_pinned_release_bundle
  test_moraine_configures_codex_and_claude_sources_with_backfill
  test_moraine_config_keeps_redaction_and_the_default_local_topology
  test_moraine_service_owns_and_restarts_the_upstream_stack
  test_moraine_leaves_user_codex_configuration_unmanaged
)

suite_dispatch 'workstation-local Moraine producer' "$@"
