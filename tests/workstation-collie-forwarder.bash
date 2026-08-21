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

rendered_raw() {
  local fixture_filter="$1"
  local installable="$2"

  if [[ -n "${TEST_WORKSTATION_RENDERED_CONFIGURATION:-}" ]]; then
    jq -er "$fixture_filter" "$TEST_WORKSTATION_RENDERED_CONFIGURATION"
    return
  fi

  nix eval --raw "$installable"
}

test_workstation_profile_selects_bun_baseline_for_pre_avx2_cpu() {
  local bun_package

  bun_package="$(
    rendered_json '.bunPackage' \
      "$REPO_ROOT#homeConfigurations.workstation.config.home.packages" \
      --apply '
        packages:
        let
          package = builtins.head (
            builtins.filter
              (package: (package.pname or package.name) == "bun-baseline")
              packages
          );
        in
        {
          pname = package.pname or package.name;
          inherit (package) version;
          srcUrl = package.src.url;
        }
      '
  )" || fail 'could not render the workstation package profile'

  jq -e '
    (.pname == "bun-baseline") and
    (.version == "1.3.13") and
    (.srcUrl == "https://github.com/oven-sh/bun/releases/download/bun-v1.3.13/bun-linux-x64-baseline.zip")
  ' <<<"$bun_package" >/dev/null \
    || fail 'rendered workstation package profile does not select the pinned baseline Bun archive'
}

test_workstation_profile_includes_dotnet_10_lts_sdk() {
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

test_collie_origin_socket_listens_on_the_portal_origin_port() {
  local listen_stream

  listen_stream="$(
    rendered_raw '.collieOriginSocket.Socket.ListenStream' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.sockets.collie-origin-forwarder.Socket.ListenStream"
  )" || fail 'could not render the Collie origin socket listener'

  [[ "$listen_stream" == '0.0.0.0:8788' ]] \
    || fail "Collie origin socket listens on unexpected address: $listen_stream"
}

test_collie_origin_socket_activates_with_normal_user_sockets() {
  local wanted_by

  wanted_by="$(
    rendered_json '.collieOriginSocket.Install.WantedBy' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.sockets.collie-origin-forwarder.Install.WantedBy"
  )" || fail 'could not render the Collie origin socket activation target'

  [[ "$wanted_by" == '["sockets.target"]' ]] \
    || fail "Collie origin socket has unexpected activation targets: $wanted_by"
}

test_collie_origin_forwarder_connects_to_the_loopback_bridge() {
  local exec_start

  exec_start="$(
    rendered_json '.collieOriginService.Service.ExecStart' \
      "$REPO_ROOT#homeConfigurations.workstation.config.systemd.user.services.collie-origin-forwarder.Service.ExecStart"
  )" || fail 'could not render the Collie origin forwarder command'

  [[ "$exec_start" == '["/lib/systemd/systemd-socket-proxyd 127.0.0.1:8787"]' ]] \
    || fail "Collie origin forwarder has unexpected command: $exec_start"
}

test_collie_origin_forwarder_has_no_collie_service_dependency_or_fallback() {
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

test_aoe_serve_pulls_up_its_origin_socket() {
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

test_collie_service_drop_in_pulls_up_its_origin_socket() {
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

test_existing_aoe_forwarder_rendering_is_unchanged() {
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

# shellcheck source=tests/lib/suite-dispatch.bash
source "$REPO_ROOT/tests/lib/suite-dispatch.bash"

readonly test_cases=(
  test_workstation_profile_selects_bun_baseline_for_pre_avx2_cpu
  test_workstation_profile_includes_dotnet_10_lts_sdk
  test_collie_origin_socket_listens_on_the_portal_origin_port
  test_collie_origin_socket_activates_with_normal_user_sockets
  test_collie_origin_forwarder_connects_to_the_loopback_bridge
  test_collie_origin_forwarder_has_no_collie_service_dependency_or_fallback
  test_aoe_serve_pulls_up_its_origin_socket
  test_collie_service_drop_in_pulls_up_its_origin_socket
  test_existing_aoe_forwarder_rendering_is_unchanged
)

suite_dispatch 'workstation Collie runtime and origin forwarder' "$@"
