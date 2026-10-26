#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

readonly ORIGIN='https://artifact-server.public.faviann.com'

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  HOME_DIR="$BATS_TEST_TMPDIR/home"
  CONFIG="$HOME_DIR/.codex/config.toml"
  HELPER="'$HOME_DIR/.local/bin/artifact-server-mcp-headers'"
  mkdir -p "$HOME_DIR/.codex"
}

apply_config() {
  local runtime_dir="$BATS_TEST_TMPDIR/runtime"

  mkdir -p "$runtime_dir"
  HOME="$HOME_DIR" \
  XDG_CACHE_HOME="$runtime_dir/cache" \
  XDG_CONFIG_HOME="$runtime_dir/config" \
  XDG_STATE_HOME="$runtime_dir/state" \
    chezmoi \
    --source "$REPO_ROOT" \
    --destination "$HOME_DIR" \
    --config /dev/null \
    --config-format toml \
    --persistent-state "$runtime_dir/chezmoistate.boltdb" \
    --override-data '{"profile":"workstation"}' \
    apply --force "$CONFIG"
}

config_as_json() {
  chezmoi --config /dev/null --config-format toml execute-template --with-stdin \
    '{{ .chezmoi.stdin | fromToml | toJson }}' <"$CONFIG" | jq -S .
}

@test "test_codex_config_pins_approval_sandbox_threads_and_personality" {
  cat >"$CONFIG" <<TOML
model = "gpt-5.5"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
personality = "friendly"

[agents]
max_concurrent_threads_per_session = 4
max_depth = 2

[mcp_servers.artifact_server]
url = "$ORIGIN/mcp"
http_headers_helper = "$HELPER"
TOML

  apply_config || fail 'apply failed'

  diff -u \
    <(jq -nS --arg url "$ORIGIN/mcp" --arg helper "$HELPER" '{
      model: "gpt-5.5",
      approval_policy: "never",
      sandbox_mode: "danger-full-access",
      personality: "pragmatic",
      agents: {max_concurrent_threads_per_session: 24, max_depth: 2},
      mcp_servers: {artifact_server: {url: $url, http_headers_helper: $helper}}
    }') \
    <(config_as_json) \
    || fail 'apply did not pin the four Codex keys and keep the rest'
}

@test "test_current_codex_config_with_comments_is_left_byte_identical" {
  cat >"$CONFIG" <<TOML
# Written by hand.
model = "gpt-5.5"
approval_policy = "never"
sandbox_mode = "danger-full-access"
personality = "pragmatic"

[agents]
# Upper bound for subagents.
max_concurrent_threads_per_session = 24

[mcp_servers.artifact_server]
url = "$ORIGIN/mcp"
http_headers_helper = "$HELPER"
TOML
  cp "$CONFIG" "$BATS_TEST_TMPDIR/before.toml"

  apply_config || fail 'apply failed'

  cmp -s "$BATS_TEST_TMPDIR/before.toml" "$CONFIG" \
    || fail 'apply rewrote a config.toml whose managed keys were all current'
}

@test "test_codex_config_with_one_stale_key_is_rewritten_with_it_fixed" {
  cat >"$CONFIG" <<TOML
# Written by hand.
model = "gpt-5.5"
approval_policy = "never"
sandbox_mode = "danger-full-access"
personality = "friendly"

[agents]
max_concurrent_threads_per_session = 24

[mcp_servers.artifact_server]
url = "$ORIGIN/mcp"
http_headers_helper = "$HELPER"
TOML

  apply_config || fail 'apply failed'

  diff -u \
    <(jq -nS --arg url "$ORIGIN/mcp" --arg helper "$HELPER" '{
      model: "gpt-5.5",
      approval_policy: "never",
      sandbox_mode: "danger-full-access",
      personality: "pragmatic",
      agents: {max_concurrent_threads_per_session: 24},
      mcp_servers: {artifact_server: {url: $url, http_headers_helper: $helper}}
    }') \
    <(config_as_json) \
    || fail 'apply did not fix the stale key and keep the others'
}
