#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  common_setup
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
