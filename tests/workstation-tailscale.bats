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

@test "test_tailscaled_runs_unprivileged_in_userspace_under_the_user_manager" {
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

@test "test_tailscaled_reapplies_the_node_prefs_on_every_start" {
  local rendered argv
  rendered="$(rendered_tailscale)"
  argv="$(jq -r '.service.Service.ExecStartPost' <<<"$rendered")"
  [[ "$argv" =~ ^/nix/store/[^\ ]+/bin/tailscale\  ]] \
    || fail "a failed ExecStartPost would not fail the start: $argv"
  diff -u <(printf '%s\n' "--socket=$(exec_start_flag "$rendered" --socket)" set \
      --shields-up --accept-routes --accept-dns=false) \
    <(tr ' ' '\n' <<<"$argv" | tail -n +2) || fail 'the daemon start does not reapply the node prefs'
}

@test "test_tailscale_login_keeps_the_node_prefs" {
  local rendered argv
  rendered="$(rendered_tailscale)"
  # shellcheck disable=SC2016
  argv="$(XDG_RUNTIME_DIR=/run/user/4242 SCRIPT="$(jq -r .cli <<<"$rendered")" \
    bash -c 'exec() { printf "%s\n" "$@"; }; eval "$SCRIPT"' tailscale login --qr)"
  diff -u <(printf '%s\n' login --shields-up --accept-routes --accept-dns=false --qr) \
    <(tail -n +3 <<<"$argv") || fail 'a bare sign-in would reset shields-up to off'
}

login_shell_notice() {
  local bash
  bash="$(command -v bash)"
  export HOME="$BATS_TEST_TMPDIR/home" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$HOME/.local/bin" "$XDG_RUNTIME_DIR/tailscale"
  touch "$XDG_RUNTIME_DIR/tailscale/tailscaled.sock"
  cp "$REPO_ROOT/dot_bash_profile.tmpl" "$HOME/.bash_profile"
  printf '#!%s\nexec %q %q\n' "$bash" "$bash" "$REPO_ROOT/scripts/tailscale-login-notice" \
    >"$HOME/.local/bin/tailscale-login-notice"
  printf '#!%s\nprintf %q\n' "$bash" "{\"BackendState\": \"$1\"}" >"$HOME/.local/bin/tailscale"
  chmod +x "$HOME/.local/bin/tailscale-login-notice" "$HOME/.local/bin/tailscale"
  env -i HOME="$HOME" PATH="$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    "$bash" --login -c true 2>&1
}

@test "test_login_shell_asks_for_a_tailscale_sign_in" {
  # shellcheck disable=SC2016
  [[ "$(login_shell_notice NeedsLogin)" == 'Work Tailscale is signed out: run `tailscale login`' ]] \
    || fail 'a signed-out node went unreported at login'
}

@test "test_login_shell_is_silent_while_tailscale_runs" {
  local output
  output="$(login_shell_notice Running)"
  [[ -z "$output" ]] || fail "a running node printed at login: $output"
}
