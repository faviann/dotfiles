# Shared Bats plumbing. Test-only; no production behavior belongs here.
# Suite-specific fixtures, stubs, and assertions stay in their owning suite.

# Consumed by the sourcing suite, not by this file.
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
readonly REPO_ROOT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Render a workstation configuration value as JSON. Read it from the prebuilt
# fixture when the sandbox provides one, otherwise evaluate it live.
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
