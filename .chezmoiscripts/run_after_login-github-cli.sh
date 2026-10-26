#!/usr/bin/env bash
set -euo pipefail

# Either variable would shadow the stored login that this script reconciles.
unset GH_TOKEN GITHUB_TOKEN

readonly item=dotfiles/github-cli-token

warn_and_continue_apply() {
  printf 'login-github-cli: warning: %s\n' "$*" >&2
  exit 0
}

if ! command -v gh >/dev/null 2>&1; then
  printf 'login-github-cli: gh is not installed yet; the next apply logs it in\n' >&2
  exit 0
fi

if ! command -v bw >/dev/null 2>&1 || ! bw unlock --check >/dev/null 2>&1; then
  exit 0
fi

token="$(bw get notes "$item" 2>/dev/null)" || token=''
token="${token//[[:space:]]/}"
[[ -n "$token" ]] || warn_and_continue_apply "cannot read a token from the Notes of Bitwarden item $item"

current="$(gh auth token --hostname github.com 2>/dev/null)" || current=''
[[ "${current//[[:space:]]/}" != "$token" ]] || exit 0

if ! error="$(printf '%s\n' "$token" \
  | gh auth login --hostname github.com --with-token 2>&1 >/dev/null)"; then
  error="${error//[$'\r\n']/ }"
  warn_and_continue_apply "gh could not log in with the token in Bitwarden item $item: $error. If the token is invalid, replace it with github-token rotate"
fi
printf 'login-github-cli: logged gh in with Bitwarden item %s\n' "$item"
