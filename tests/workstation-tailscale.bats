#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}

rendered_tailscale() {
  rendered_json '.tailscale' \
    "$REPO_ROOT#homeConfigurations.workstation.config" \
    --apply 'c: let
      script = name: (builtins.head (builtins.filter
        (package: (package.pname or package.name) == name) c.home.packages)).text;
    in {
      service = c.systemd.user.services.tailscaled;
      cli = script "tailscale";
      withJesGateway = script "with-jes-gateway";
      shell = c.home.sessionVariables;
      systemd = c.systemd.user.sessionVariables;
    }'
}

exec_start_flag() {
  jq -r --arg flag "$2" \
    '.service.Service.ExecStart[0] | split(" ")[] | select(startswith($flag + "=")) | ltrimstr($flag + "=")' \
    <<<"$1"
}

@test "test_tailscaled_runs_unprivileged_in_userspace_with_loopback_proxies" {
  local rendered
  rendered="$(rendered_tailscale)"
  jq -e '
    .service |
    (.Service.ExecStart | length == 1) and
    (.Service.ExecStart[0] | test("^/nix/store/[^ ]+-tailscale-[^/ ]+/bin/tailscaled ")) and
    (.Service.Type == "notify") and
    (.Service.RuntimeDirectory == "tailscale") and
    (.Service.UMask == "0077") and
    (.Service.Restart == "on-failure") and
    (.Install.WantedBy == ["default.target"])
  ' <<<"$rendered" >/dev/null || fail 'unexpected tailscaled service contract'
  [[ "$(exec_start_flag "$rendered" --tun)" == userspace-networking ]] \
    || fail 'tailscaled would need a TUN device'
  [[ "$(exec_start_flag "$rendered" --statedir)" == '%h/.local/share/tailscale' ]] \
    || fail 'node state is not under the user data directory'
  [[ "$(exec_start_flag "$rendered" --outbound-http-proxy-listen)" == 127.0.0.1:* ]] \
    || fail 'the gateway proxy listens beyond loopback'
  [[ "$(exec_start_flag "$rendered" --socks5-server)" == "$(exec_start_flag "$rendered" --outbound-http-proxy-listen)" ]] \
    || fail 'the SOCKS5 proxy does not share the loopback HTTP proxy listener'
}

@test "test_tailscale_cli_targets_the_user_service_socket" {
  local rendered argv socket
  rendered="$(rendered_tailscale)"
  socket="$(exec_start_flag "$rendered" --socket)"
  # shellcheck disable=SC2016
  argv="$(XDG_RUNTIME_DIR=/run/user/4242 SCRIPT="$(jq -r .cli <<<"$rendered")" \
    bash -c 'exec() { printf "%s\n" "$@"; }; eval "$SCRIPT"' tailscale status)"
  diff -u <(printf '%s\n' "--socket=${socket//%t//run/user/4242}" status) \
    <(tail -n +2 <<<"$argv") || fail 'CLI and daemon disagree on the socket'
}

@test "test_only_wrapped_commands_reach_the_gateway_proxy" {
  local rendered proxy
  rendered="$(rendered_tailscale)"
  proxy="$(HTTPS_PROXY='' bash -c "$(jq -r .withJesGateway <<<"$rendered")" \
    with-jes-gateway printenv HTTPS_PROXY)"
  [[ "$proxy" == "http://$(exec_start_flag "$rendered" --outbound-http-proxy-listen)" ]] \
    || fail "wrapped command got HTTPS_PROXY=$proxy, not the tailscaled proxy"
  jq -e '
    [.shell, .systemd | keys[] | ascii_downcase] |
    any(. == "https_proxy" or . == "http_proxy" or . == "all_proxy") | not
  ' <<<"$rendered" >/dev/null || fail 'a proxy was exported to every session'
}
