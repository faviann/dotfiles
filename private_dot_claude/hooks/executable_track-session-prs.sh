#!/usr/bin/env bash
# PostToolUse(Bash): record PR URLs printed by `gh pr create` so the status
# line can show PRs this session (including its subagents) opened, whatever
# worktree they came from.
input=$(cat)
[[ $(jq -r '.tool_input.command // empty' <<<"$input") == *"gh pr create"* ]] || exit 0
sid=$(jq -r '.session_id // empty' <<<"$input")
[[ -n $sid ]] || exit 0
dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$dir"
jq -r '.tool_response | tostring' <<<"$input" |
  grep -oE 'https://github\.com/[^/ ]+/[^/ ]+/pull/[0-9]+' >>"$dir/session-$sid"
exit 0
