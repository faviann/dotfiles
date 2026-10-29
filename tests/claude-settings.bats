#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  # A fresh machine's first apply runs before Home Manager installs jq, so
  # chezmoi gets nothing but itself on PATH.
  CHEZMOI_ONLY_PATH="$BATS_TEST_TMPDIR/chezmoi-only"
  mkdir -p "$CHEZMOI_ONLY_PATH"
  ln -s "$(command -v chezmoi)" "$CHEZMOI_ONLY_PATH/chezmoi"
  BW_LOG="$BATS_TEST_TMPDIR/bw.log"
  cat >"$CHEZMOI_ONLY_PATH/bw" <<EOF
#!$(command -v bash)
printf '%s\n' "\$*" >>"$BW_LOG"
printf '%s\n' '{"notes": "gw-token-fixture\n"}'
EOF
  chmod +x "$CHEZMOI_ONLY_PATH/bw"
}

# $HOME is literal: Claude Code expands it when it runs the hook.
# shellcheck disable=SC2016
TRACK_PRS='{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$HOME/.claude/hooks/track-session-prs.sh\"","timeout":5}]}'
GATEWAY="https://ai-gateway.jungleservices.net"

managed_for() {
  local gateway="$1"
  printf '%s' "{
  \"statusLine\": {\"type\": \"command\", \"command\": \"~/.claude/statusline.sh\", \"refreshInterval\": 60},
  \"env\": {
    \"ANTHROPIC_BASE_URL\": \"$gateway\",
    \"ANTHROPIC_CUSTOM_HEADERS\": \"Authorization: Bearer gw-token-fixture\",
    \"DISABLE_TELEMETRY\": \"1\",
    \"DISABLE_ERROR_REPORTING\": \"1\",
    \"DISABLE_AUTOUPDATER\": \"1\",
    \"CLAUDE_CODE_GB_DISK_CACHE_WHEN_TELEMETRY_OFF\": \"1\",
    \"ENABLE_CLAUDEAI_MCP_SERVERS\": \"false\"
  },
  \"syncClaudeAiSkills\": false,
  \"syncClaudeAiPlugins\": false,
  \"attribution\": {\"commit\": \"\", \"pr\": \"\"},
  \"permissions\": {\"defaultMode\": \"bypassPermissions\"},
  \"skipDangerousModePermissionPrompt\": true,
  \"hooks\": {\"PostToolUse\": [$TRACK_PRS]}
}"
}

apply_settings() {
  settings_chezmoi "$1" "${2:-workstation}" apply --force
}

settings_chezmoi() {
  local home="$1"
  local profile="$2"
  shift 2
  local runtime_dir="$BATS_TEST_TMPDIR/runtime"

  mkdir -p "$home/.claude" "$runtime_dir"
  env PATH="$CHEZMOI_ONLY_PATH" \
    HOME="$home" \
    XDG_CACHE_HOME="$runtime_dir/cache" \
    XDG_CONFIG_HOME="$runtime_dir/config" \
    XDG_STATE_HOME="$runtime_dir/state" \
    chezmoi \
    --source "$REPO_ROOT" \
    --destination "$home" \
    --config /dev/null \
    --config-format toml \
    --persistent-state "$runtime_dir/chezmoistate.boltdb" \
    --override-data "{\"profile\":\"$profile\"}" \
    "$@" "$home/.claude/settings.json"
}

@test "test_settings_merge_keeps_other_keys_and_is_idempotent" {
  local home="$BATS_TEST_TMPDIR/home"
  local settings="$home/.claude/settings.json"
  local existing="$BATS_TEST_TMPDIR/existing.json"
  local first_apply="$BATS_TEST_TMPDIR/first-apply.json"

  cat >"$existing" <<'JSON'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls:*)"]},
  "env": {"OTHER": "kept", "ANTHROPIC_BASE_URL": "https://stale.example", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"},
  "apiKeyHelper": "cat ~/.config/claude/gateway-token",
  "attribution": {"pr": "stale"},
  "hooks": {
    "SessionStart": [{"matcher": "^(startup|resume)$", "hooks": [{"type": "command", "command": "bash 'herdr-agent-state.sh' session", "timeout": 10}]}],
    "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "format && lint"}]}]
  }
}
JSON
  mkdir -p "$home/.claude"
  cp "$existing" "$settings"

  apply_settings "$home" || fail 'first apply failed'
  cp "$settings" "$first_apply"
  apply_settings "$home" || fail 'second apply failed'

  cmp -s "$first_apply" "$settings" \
    || fail 'second apply changed settings.json'
  diff -u <(jq -S . <<'JSON'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls:*)"], "defaultMode": "bypassPermissions"},
  "skipDangerousModePermissionPrompt": true,
  "statusLine": {"type": "command", "command": "~/.claude/statusline.sh", "refreshInterval": 60},
  "env": {
    "OTHER": "kept",
    "ANTHROPIC_BASE_URL": "https://ai-gateway.jungleservices.net",
    "ANTHROPIC_CUSTOM_HEADERS": "Authorization: Bearer gw-token-fixture",
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_GB_DISK_CACHE_WHEN_TELEMETRY_OFF": "1",
    "ENABLE_CLAUDEAI_MCP_SERVERS": "false"
  },
  "syncClaudeAiSkills": false,
  "syncClaudeAiPlugins": false,
  "attribution": {"commit": "", "pr": ""},
  "hooks": {
    "SessionStart": [{"matcher": "^(startup|resume)$", "hooks": [{"type": "command", "command": "bash 'herdr-agent-state.sh' session", "timeout": 10}]}],
    "PostToolUse": [
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "format && lint"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"$HOME/.claude/hooks/track-session-prs.sh\"", "timeout": 5}]}
    ]
  }
}
JSON
  ) <(jq -S . "$settings") \
    || fail 'merge did not keep other keys and set exactly the managed keys'
}

@test "test_settings_another_writer_reordered_verify_and_stay_as_written" {
  local home="$BATS_TEST_TMPDIR/home"
  local settings="$home/.claude/settings.json"
  local written="$BATS_TEST_TMPDIR/written.json"

  apply_settings "$home" || fail 'first apply failed'
  jq '{enabledPlugins: {"pstack@pstack-claude": true}} + (to_entries | reverse | from_entries)' \
    "$settings" >"$written"
  cp "$written" "$settings"

  settings_chezmoi "$home" workstation verify \
    || fail 'chezmoi verify failed after another writer reordered settings.json'
  apply_settings "$home" || fail 'second apply failed'
  cmp -s "$written" "$settings" \
    || fail 'apply rewrote settings.json that already held every managed value'
}

@test "test_missing_settings_gets_only_the_managed_keys" {
  local home="$BATS_TEST_TMPDIR/home"

  apply_settings "$home" || fail 'apply failed'

  diff -u <(jq -S . <<<"$(managed_for "$GATEWAY")") <(jq -S . "$home/.claude/settings.json") \
    || fail 'missing settings.json did not get exactly the managed keys'
}

@test "test_every_profile_gets_the_jes_gateway_and_keeps_the_parked_url" {
  local profile home
  for profile in workstation desktop; do
    home="$BATS_TEST_TMPDIR/home-$profile"
    mkdir -p "$home/.claude"
    printf '{"env": {"ANTHROPIC_BASE_URL": "https://stale.example", "_ANTHROPIC_BASE_URL": "https://parked.example"}}\n' \
      >"$home/.claude/settings.json"

    apply_settings "$home" "$profile" || fail "$profile apply failed"

    [[ "$(jq -r '.env.ANTHROPIC_BASE_URL' "$home/.claude/settings.json")" == "$GATEWAY" ]] \
      || fail "$profile did not get $GATEWAY"
    [[ "$(jq -r '.env._ANTHROPIC_BASE_URL' "$home/.claude/settings.json")" == "https://parked.example" ]] \
      || fail "$profile lost the parked URL"
  done
}
