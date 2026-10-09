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
}

# $HOME is literal: Claude Code expands it when it runs the hook.
# shellcheck disable=SC2016
TRACK_PRS='{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$HOME/.claude/hooks/track-session-prs.sh\"","timeout":5}]}'
MANAGED="{
  \"statusLine\": {\"type\": \"command\", \"command\": \"~/.claude/statusline.sh\", \"refreshInterval\": 60},
  \"env\": {
    \"ANTHROPIC_BASE_URL\": \"https://gateway.ai.faviann.com\",
    \"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC\": \"1\"
  },
  \"apiKeyHelper\": \"cat ~/.config/claude/gateway-token\",
  \"hooks\": {\"PostToolUse\": [$TRACK_PRS]}
}"

apply_settings() {
  local home="$1"
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
    --override-data '{"is_workstation":false}' \
    apply --force "$home/.claude/settings.json"
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
  "env": {"OTHER": "kept", "ANTHROPIC_BASE_URL": "https://stale.example"},
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
  diff -u \
    <(jq -S --argjson managed "$MANAGED" --argjson track "$TRACK_PRS" \
      '. * ($managed | del(.hooks)) | .hooks.PostToolUse += [$track]' "$existing") \
    <(jq -S . "$settings") \
    || fail 'merge did not keep other keys and set exactly the managed keys'
}

@test "test_missing_settings_gets_only_the_managed_keys" {
  local home="$BATS_TEST_TMPDIR/home"

  apply_settings "$home" || fail 'apply failed'

  diff -u <(jq -S . <<<"$MANAGED") <(jq -S . "$home/.claude/settings.json") \
    || fail 'missing settings.json did not get exactly the managed keys'
}
