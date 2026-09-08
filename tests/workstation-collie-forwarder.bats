#!/usr/bin/env bats
set -euo pipefail

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
readonly REPO_ROOT

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}

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

rendered_raw() {
  local fixture_filter="$1"
  local installable="$2"

  if [[ -n "${TEST_WORKSTATION_RENDERED_CONFIGURATION:-}" ]]; then
    jq -er "$fixture_filter" "$TEST_WORKSTATION_RENDERED_CONFIGURATION"
    return
  fi

  nix eval --raw "$installable"
}

@test "test_workstation_profile_includes_dotnet_10_lts_sdk" {
  local dotnet_sdk_package

  dotnet_sdk_package="$(
    rendered_json '.dotnetSdkPackage' \
      "$REPO_ROOT#homeConfigurations.workstation.config.home.packages" \
      --apply '
        packages:
        let
          package = builtins.head (
            builtins.filter
              (package: (package.pname or package.name) == "dotnet-sdk-wrapped")
              packages
          );
        in
        {
          pname = package.pname or package.name;
          inherit (package) version;
        }
      '
  )" || fail 'could not render the workstation .NET SDK package'

  jq -e '
    (.pname == "dotnet-sdk-wrapped") and
    (.version | startswith("10."))
  ' <<<"$dotnet_sdk_package" >/dev/null \
    || fail 'rendered workstation package profile does not include the .NET 10 LTS SDK'
}

@test "test_collie_origin_socket_listens_on_the_portal_origin_port" {
  local listen_stream

  listen_stream="$(
    rendered_raw '.collieOriginSocket.Socket.ListenStream' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.sockets.collie-origin-forwarder.Socket.ListenStream"
  )" || fail 'could not render the Collie origin socket listener'

  [[ "$listen_stream" == '0.0.0.0:8788' ]] \
    || fail "Collie origin socket listens on unexpected address: $listen_stream"
}

@test "test_collie_origin_socket_activates_with_normal_user_sockets" {
  local wanted_by

  wanted_by="$(
    rendered_json '.collieOriginSocket.Install.WantedBy' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.sockets.collie-origin-forwarder.Install.WantedBy"
  )" || fail 'could not render the Collie origin socket activation target'

  [[ "$wanted_by" == '["sockets.target"]' ]] \
    || fail "Collie origin socket has unexpected activation targets: $wanted_by"
}

@test "test_collie_origin_forwarder_connects_to_the_loopback_bridge" {
  local exec_start

  exec_start="$(
    rendered_json '.collieOriginService.Service.ExecStart' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.services.collie-origin-forwarder.Service.ExecStart"
  )" || fail 'could not render the Collie origin forwarder command'

  [[ "$exec_start" == '["/lib/systemd/systemd-socket-proxyd 127.0.0.1:8787"]' ]] \
    || fail "Collie origin forwarder has unexpected command: $exec_start"
}

@test "test_collie_origin_forwarder_has_no_collie_service_dependency_or_fallback" {
  local rendered_service

  rendered_service="$(
    rendered_json '.collieOriginService' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.services.collie-origin-forwarder"
  )" || fail 'could not render the Collie origin forwarder service'

  jq -e '
    ((.Unit.Requires // []) == []) and
    ([((.Unit.After // [])[]) | select(test("collie"; "i"))] == []) and
    (.Service.ExecStart == ["/lib/systemd/systemd-socket-proxyd 127.0.0.1:8787"]) and
    (has("Install") | not)
  ' <<<"$rendered_service" >/dev/null \
    || fail 'Collie origin forwarder adds a Collie service dependency or fallback'
}

@test "test_aoe_serve_pulls_up_its_origin_socket" {
  local rendered_service

  rendered_service="$(
    rendered_json '.aoeServeService' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.services.aoe-serve"
  )" || fail 'could not render the AoE serve service'

  # Starting aoe-serve without the socket leaves origin port 4001 unbound, so the
  # portal sees nothing while the app is healthy. Wants, not Requires: aoe-serve
  # stays useful locally if the socket fails, and Wants adds no ordering, so it
  # cannot deadlock against the proxy's own Requires=aoe-serve.service.
  jq -e '
    ([((.Unit.Wants // [])[]) | select(. == "aoe-lan-proxy.socket")] | length == 1) and
    ([((.Unit.Requires // [])[]) | select(test("aoe-lan-proxy"; "i"))] == []) and
    ([((.Unit.After // [])[]) | select(test("aoe-lan-proxy"; "i"))] == [])
  ' <<<"$rendered_service" >/dev/null \
    || fail 'aoe-serve does not softly pull up its origin socket'
}

@test "test_collie_service_drop_in_pulls_up_its_origin_socket" {
  local rendered_drop_in

  rendered_drop_in="$(
    rendered_raw '.collieServiceDropIn' \
      "$REPO_ROOT#homeConfigurations.workstation.config.xdg.configFile.\"systemd/user/collie.service.d/10-origin-forwarder.conf\".text"
  )" || fail 'could not render the Collie service drop-in'

  # Collie's unit is generated by collie-ctl, so the link is expressed as a drop-in
  # rather than declared inline the way aoe-serve is. The drop-in must stay confined
  # to the socket dependency: anything reproducing the generated unit's ExecStart,
  # WorkingDirectory, or Environment would fork upstream's contract and drift on the
  # next Collie release.
  grep -Fxq '[Unit]' <<<"$rendered_drop_in" \
    || fail 'Collie drop-in is missing its [Unit] section'
  grep -Fxq 'Wants=collie-origin-forwarder.socket' <<<"$rendered_drop_in" \
    || fail 'Collie drop-in does not pull up the origin socket'
  if grep -Eq '^(ExecStart|WorkingDirectory|Environment|EnvironmentFile|Restart)=' \
    <<<"$rendered_drop_in"; then
    fail 'Collie drop-in reproduces generated unit contents instead of only the socket link'
  fi
}

@test "test_existing_aoe_forwarder_rendering_is_unchanged" {
  local rendered_socket
  local rendered_service

  rendered_socket="$(
    rendered_json '.aoeLanProxySocket' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.sockets.aoe-lan-proxy"
  )" || fail 'could not render the existing AoE proxy socket'
  rendered_service="$(
    rendered_json '.aoeLanProxyService' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.services.aoe-lan-proxy"
  )" || fail 'could not render the existing AoE proxy service'

  jq -e '
    (.Socket.ListenStream == "0.0.0.0:4001") and
    (.Socket.NoDelay == true) and
    (.Install.WantedBy == ["sockets.target"])
  ' <<<"$rendered_socket" >/dev/null \
    || fail 'existing AoE proxy socket rendering changed'
  jq -e '
    (.Service.ExecStart == ["/lib/systemd/systemd-socket-proxyd 127.0.0.1:4000"]) and
    (.Unit.Requires == ["aoe-serve.service"]) and
    (.Unit.After == ["aoe-serve.service"])
  ' <<<"$rendered_service" >/dev/null \
    || fail 'existing AoE proxy service rendering changed'
}

# Exercise the handoff with a plugin fixture that owns its generated unit.
collie_bootstrap_fixture() {
  fixture_dir="$(mktemp -d)"
  export XDG_CONFIG_HOME="$fixture_dir/config"
  mkdir -p "$XDG_CONFIG_HOME/herdr" "$fixture_dir/plugin with spaces/scripts"
  jq -n --arg root "$fixture_dir/plugin with spaces" \
    '[{plugin_id: "herdr.collie", plugin_root: $root}]' \
    >"$XDG_CONFIG_HOME/herdr/plugins.json"
  cat >"$fixture_dir/plugin with spaces/scripts/collie-ctl.sh" <<'PLUGIN'
set -eu
[[ "$#" == 1 && "$1" == start ]]
mkdir -p "$XDG_CONFIG_HOME/systemd/user/default.target.wants"
printf '%s\n' "$PWD" >"$XDG_CONFIG_HOME/systemd/user/collie.service"
ln -sf ../collie.service "$XDG_CONFIG_HOME/systemd/user/default.target.wants/collie.service"
PLUGIN
}

@test "test_collie_bootstrap_regenerates_a_missing_unit_from_the_current_registry" {
  collie_bootstrap_fixture
  bash "$REPO_ROOT/scripts/collie-bootstrap"
  [[ -L "$XDG_CONFIG_HOME/systemd/user/default.target.wants/collie.service" ]] \
    || fail 'bootstrap did not delegate unit creation and enablement'
  bash "$REPO_ROOT/scripts/collie-bootstrap"
  mv "$fixture_dir/plugin with spaces" "$fixture_dir/replacement plugin"
  jq -n --arg root "$fixture_dir/replacement plugin" \
    '[{plugin_id: "herdr.collie", plugin_root: $root}]' \
    >"$XDG_CONFIG_HOME/herdr/plugins.json"
  rm "$XDG_CONFIG_HOME/systemd/user/collie.service" \
    "$XDG_CONFIG_HOME/systemd/user/default.target.wants/collie.service"
  bash "$REPO_ROOT/scripts/collie-bootstrap"
  [[ "$(cat "$XDG_CONFIG_HOME/systemd/user/collie.service")" == "$fixture_dir/replacement plugin" ]] \
    || fail 'bootstrap reused an obsolete plugin root'
}

@test "test_collie_bootstrap_skips_absent_installations_and_reports_broken_ones" {
  collie_bootstrap_fixture
  rm "$XDG_CONFIG_HOME/herdr/plugins.json"
  bash "$REPO_ROOT/scripts/collie-bootstrap"
  printf '[]' >"$XDG_CONFIG_HOME/herdr/plugins.json"
  bash "$REPO_ROOT/scripts/collie-bootstrap"
  [[ ! -e "$XDG_CONFIG_HOME/systemd/user/collie.service" ]] || fail 'absent plugin was started'
  for registry in 'invalid' '{}' '[{"plugin_id":"herdr.collie"}]' \
    '[{"plugin_id":"herdr.collie","plugin_root":"/missing"}]'; do
    printf '%s' "$registry" >"$XDG_CONFIG_HOME/herdr/plugins.json"
    if bash "$REPO_ROOT/scripts/collie-bootstrap"; then
      fail 'invalid installation was silently accepted'
    fi
  done
  jq -n --arg root "$fixture_dir/plugin with spaces" \
    '[{plugin_id: "herdr.collie", plugin_root: $root}]' \
    >"$XDG_CONFIG_HOME/herdr/plugins.json"
  printf 'exit 42\n' >"$fixture_dir/plugin with spaces/scripts/collie-ctl.sh"
  local_status=0
  bash "$REPO_ROOT/scripts/collie-bootstrap" || local_status=$?
  [[ "$local_status" == 42 ]] || fail 'plugin startup failure was swallowed'
}

@test "test_collie_bootstrap_runs_after_the_user_target_without_coupling_herdr" {
  local service
  service="$(rendered_json '.collieBootstrapService' \
    "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.services.collie-bootstrap")"
  jq -e '
    .Install.WantedBy == ["default.target"] and
    .Unit.After == ["default.target"] and
    (.Unit.Requires // []) == [] and
    .Service.Type == "oneshot" and
    .Service.RemainAfterExit == true and
    (.Service.ExecStart[0] | endswith("/bin/collie-bootstrap")) and
    (.Service.Environment[0] | contains("/home/faviann/.local/bin:/home/faviann/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin"))
  ' <<<"$service" >/dev/null || fail 'bootstrap has unsafe boot ordering or environment'
}
