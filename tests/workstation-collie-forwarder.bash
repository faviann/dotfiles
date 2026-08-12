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
  local package_names

  package_names="$(
    rendered_json '.packageNames' \
      "$REPO_ROOT#homeConfigurations.workstation.config.home.packages" \
      --apply 'packages: map (package: package.pname or package.name) packages'
  )" || fail 'could not render the workstation package profile'

  jq -e 'index("bun-baseline") != null' <<<"$package_names" >/dev/null \
    || fail 'rendered workstation package profile does not select baseline-compatible Bun'
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
  test_collie_origin_socket_listens_on_the_portal_origin_port
  test_collie_origin_socket_activates_with_normal_user_sockets
  test_collie_origin_forwarder_connects_to_the_loopback_bridge
  test_collie_origin_forwarder_has_no_collie_service_dependency_or_fallback
  test_existing_aoe_forwarder_rendering_is_unchanged
)

suite_dispatch 'workstation Collie runtime and origin forwarder' "$@"
