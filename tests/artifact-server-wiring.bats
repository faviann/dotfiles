#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

readonly KEY='fixture-key-0123456789abcdef0123456789abcdef'
readonly ORIGIN='https://artifact-server.public.faviann.com'

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  export ITEM="$BATS_TEST_TMPDIR/item.json"
  HOME_DIR="$BATS_TEST_TMPDIR/home"
  local bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$bin" "$HOME_DIR"
  cat >"$bin/bw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == 'get item dotfiles/artifact-server-api-key' ]] || exit 64
cat "$ITEM"
STUB
  sed -i "1c #!$(command -v bash)" "$bin/bw"
  chmod +x "$bin/bw"
  export PATH="$bin:$PATH"
}

apply_targets() {
  local data="$1"
  local runtime_dir="$BATS_TEST_TMPDIR/runtime"
  local target
  local targets=()
  shift

  for target in "$@"; do
    mkdir -p "$(dirname "$HOME_DIR/$target")"
    targets+=("$HOME_DIR/$target")
  done
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
    --override-data "$data" \
    apply --force "${targets[@]}"
}

apply_workstation() {
  apply_targets '{"profile":"workstation"}' "$@"
}

toml_as_json() {
  chezmoi --config /dev/null --config-format toml execute-template --with-stdin \
    '{{ .chezmoi.stdin | fromToml | toJson }}' <"$1"
}

run_helper() {
  HOME="$HOME_DIR" sh "$REPO_ROOT/dot_local/bin/executable_artifact-server-mcp-headers"
}

@test "test_api_key_renders_from_bitwarden_as_one_owner_only_line" {
  local notes

  for notes in "$KEY" "$KEY"$'\n' "$KEY"$'\n\n'; do
    rm -rf "$HOME_DIR"
    mkdir -p "$HOME_DIR"
    jq -n --arg notes "$notes" \
      '{name: "dotfiles/artifact-server-api-key", notes: $notes}' >"$ITEM"

    apply_workstation .agents/artifact-server

    cmp -s "$HOME_DIR/.agents/artifact-server/api-key" <(printf '%s\n' "$KEY") \
      || fail 'key file is not the Notes value on one line'
    [[ "$(stat -c %a "$HOME_DIR/.agents/artifact-server")" == 700 ]] \
      || fail 'key directory is not owner-only'
    [[ "$(stat -c %a "$HOME_DIR/.agents/artifact-server/api-key")" == 600 ]] \
      || fail 'key file is not owner-only'
  done
}

@test "test_headers_helper_prints_the_bearer_header_from_the_key_file" {
  mkdir -p "$HOME_DIR/.agents/artifact-server"
  printf '%s\n' "$KEY" >"$HOME_DIR/.agents/artifact-server/api-key"

  diff -u <(printf '{"Authorization":"Bearer %s"}\n' "$KEY") <(run_helper) \
    || fail 'helper did not print the exact Authorization header JSON'
}

@test "test_headers_helper_fails_without_a_partial_header_when_the_key_is_missing" {
  local key_file="$HOME_DIR/.agents/artifact-server/api-key"
  local state

  for state in missing empty; do
    mkdir -p "$(dirname "$key_file")"
    rm -f "$key_file"
    [[ "$state" == missing ]] || : >"$key_file"

    if run_helper >"$BATS_TEST_TMPDIR/stdout" 2>"$BATS_TEST_TMPDIR/stderr"; then
      fail "helper succeeded with a $state key file"
    fi
    [[ ! -s "$BATS_TEST_TMPDIR/stdout" ]] \
      || fail "helper printed output with a $state key file"
    grep -qF "$key_file" "$BATS_TEST_TMPDIR/stderr" \
      || fail "helper error does not name the key file when it is $state"
  done
}

@test "test_claude_json_keeps_other_keys_and_sets_the_server_once" {
  local config="$HOME_DIR/.claude.json"
  local existing="$BATS_TEST_TMPDIR/existing.json"

  cat >"$existing" <<'JSON'
{
  "numStartups": 412,
  "firstStartTime": "2026-01-02T03:04:05.678Z",
  "userID": "0123456789abcdef",
  "projects": {"/home/faviann/repos/x": {"allowedTools": ["Bash(make && make test)"], "history": []}},
  "mcpServers": {
    "annotator": {"type": "stdio", "command": "annotator", "args": ["--mcp"]},
    "artifact-server": {"type": "http", "url": "https://stale.example/mcp"}
  }
}
JSON
  cp "$existing" "$config"

  apply_workstation .claude.json || fail 'first apply failed'
  cp "$config" "$BATS_TEST_TMPDIR/first-apply.json"
  apply_workstation .claude.json || fail 'second apply failed'

  cmp -s "$BATS_TEST_TMPDIR/first-apply.json" "$config" \
    || fail 'second apply changed .claude.json'
  diff -u \
    <(jq -S --arg origin "$ORIGIN" --arg home "$HOME_DIR" \
      '.mcpServers["artifact-server"] = {type: "http", url: ($origin + "/mcp"), headersHelper: ($home + "/.local/bin/artifact-server-mcp-headers")}' \
      "$existing") \
    <(jq -S . "$config") \
    || fail 'apply did not keep other keys and set exactly the artifact-server entry'
  [[ "$(stat -c %a "$config")" == 600 ]] || fail '.claude.json is not owner-only'
}

@test "test_codex_config_keeps_nested_tables_and_arrays_and_sets_the_server_once" {
  local config="$HOME_DIR/.codex/config.toml"
  local existing="$BATS_TEST_TMPDIR/existing.toml"

  cat >"$existing" <<'TOML'
model = "gpt-5.5"
model_reasoning_effort = "high"
approval_policy = "never"
notify = ["herdr", "notify", "--agent", "codex"]

[projects."/home/faviann/repos/dotfiles"]
trust_level = "trusted"

[mcp_servers.moraine]
command = "moraine"
args = ["mcp", "--stdio"]
startup_timeout_sec = 20
env = { MORAINE_LOG = "warn" }

[mcp_servers.artifact_server]
url = "https://stale.example/mcp"
bearer_token_env_var = "ARTIFACT_SERVER_API_KEY"

[tui]
notifications = ["agent-turn-complete", "approval-requested"]

[[hooks.post_turn]]
command = ["herdr", "state"]
timeout_ms = 1500

[[hooks.post_turn]]
command = ["notify-send", "done"]
TOML
  mkdir -p "$(dirname "$config")"
  cp "$existing" "$config"

  apply_workstation .codex/config.toml || fail 'first apply failed'
  cp "$config" "$BATS_TEST_TMPDIR/first-apply.toml"
  apply_workstation .codex/config.toml || fail 'second apply failed'

  cmp -s "$BATS_TEST_TMPDIR/first-apply.toml" "$config" \
    || fail 'second apply changed config.toml'
  [[ "$(grep -Ec '^ *\[mcp_servers\.artifact_server\]$' "$config")" -eq 1 ]] \
    || fail 'config.toml does not hold exactly one artifact_server table'
  toml_as_json "$existing" >"$BATS_TEST_TMPDIR/existing.json" \
    || fail 'could not parse the fixture'
  toml_as_json "$config" >"$BATS_TEST_TMPDIR/applied.json" \
    || fail 'could not parse the applied config.toml'
  diff -u \
    <(jq -S --arg origin "$ORIGIN" --arg home "$HOME_DIR" \
      '.mcp_servers.artifact_server = {url: ($origin + "/mcp"), http_headers_helper: ($home + "/.local/bin/artifact-server-mcp-headers")}' \
      "$BATS_TEST_TMPDIR/existing.json") \
    <(jq -S . "$BATS_TEST_TMPDIR/applied.json") \
    || fail 'apply did not keep other keys and set exactly the artifact_server entry'
  [[ "$(stat -c %a "$config")" == 600 ]] || fail 'config.toml is not owner-only'
}

@test "test_harness_configs_with_the_current_server_are_left_byte_identical" {
  local helper="$HOME_DIR/.local/bin/artifact-server-mcp-headers"

  mkdir -p "$HOME_DIR/.codex"
  printf '{"theme":"dark","mcpServers":{"artifact-server":{"headersHelper":"%s","url":"%s/mcp","type":"http"}}}' \
    "$helper" "$ORIGIN" >"$HOME_DIR/.claude.json"
  printf '# Written by hand.\nmodel = "gpt-5.5"\n\n[mcp_servers.artifact_server]\nurl = "%s/mcp"\nhttp_headers_helper = "%s"\n' \
    "$ORIGIN" "$helper" >"$HOME_DIR/.codex/config.toml"
  cp "$HOME_DIR/.claude.json" "$BATS_TEST_TMPDIR/claude.json"
  cp "$HOME_DIR/.codex/config.toml" "$BATS_TEST_TMPDIR/config.toml"

  apply_workstation .claude.json .codex/config.toml || fail 'apply failed'

  cmp -s "$BATS_TEST_TMPDIR/claude.json" "$HOME_DIR/.claude.json" \
    || fail 'apply rewrote a .claude.json that already had the server'
  cmp -s "$BATS_TEST_TMPDIR/config.toml" "$HOME_DIR/.codex/config.toml" \
    || fail 'apply rewrote a config.toml that already had the server'
}

@test "test_missing_harness_configs_get_only_the_server" {
  local helper="$HOME_DIR/.local/bin/artifact-server-mcp-headers"

  apply_workstation .claude.json .codex/config.toml || fail 'apply failed'

  diff -u \
    <(jq -nS --arg url "$ORIGIN/mcp" --arg helper "$helper" \
      '{mcpServers: {"artifact-server": {type: "http", url: $url, headersHelper: $helper}}}') \
    <(jq -S . "$HOME_DIR/.claude.json") \
    || fail 'missing .claude.json did not get only the server'
  toml_as_json "$HOME_DIR/.codex/config.toml" >"$BATS_TEST_TMPDIR/applied.json" \
    || fail 'could not parse the applied config.toml'
  diff -u \
    <(jq -nS --arg url "$ORIGIN/mcp" --arg helper "$helper" \
      '{mcp_servers: {artifact_server: {url: $url, http_headers_helper: $helper}}}') \
    <(jq -S . "$BATS_TEST_TMPDIR/applied.json") \
    || fail 'missing config.toml did not get only the server'
}

@test "test_every_consumer_reads_the_origin_and_the_one_key_file" {
  local origin='https://artifacts.example.test'
  # The harnesses expand the tilde themselves.
  # shellcheck disable=SC2088
  local key_ref='~/.agents/artifact-server/api-key'

  apply_targets "{\"profile\":\"workstation\",\"artifactServer\":{\"url\":\"$origin\"}}" \
    .claude.json .codex/config.toml .config/opencode/opencode.json \
    .pi/agent/mcp.json .config/faviann-skills/artifact-server.json \
    || fail 'apply failed'

  diff -u \
    <(jq -n --arg origin "$origin" --arg tokenFile "$HOME_DIR/.agents/artifact-server/api-key" \
      '{server: $origin, tokenFile: $tokenFile}') \
    <(jq . "$HOME_DIR/.config/faviann-skills/artifact-server.json") \
    || fail 'skill host configuration does not name the origin and the key file'
  jq -e --arg url "$origin/mcp" '.mcpServers["artifact-server"].url == $url' \
    "$HOME_DIR/.claude.json" >/dev/null || fail 'Claude Code server URL'
  toml_as_json "$HOME_DIR/.codex/config.toml" >"$BATS_TEST_TMPDIR/codex.json" \
    || fail 'could not parse the applied config.toml'
  jq -e --arg url "$origin/mcp" '.mcp_servers.artifact_server.url == $url' \
    "$BATS_TEST_TMPDIR/codex.json" >/dev/null || fail 'Codex server URL'
  jq -e --arg url "$origin/mcp" --arg auth "Bearer {file:$key_ref}" '
    .mcp["artifact-server"] == {type: "remote", url: $url, oauth: false, headers: {Authorization: $auth}}
  ' "$HOME_DIR/.config/opencode/opencode.json" >/dev/null || fail 'OpenCode server entry'
  jq -e --arg url "$origin/mcp" --arg auth "!printf 'Bearer %s' \"\$(cat $key_ref)\"" '
    .mcpServers["artifact-server"] == {url: $url, headers: {Authorization: $auth}}
  ' "$HOME_DIR/.pi/agent/mcp.json" >/dev/null || fail 'pi server entry'
}
