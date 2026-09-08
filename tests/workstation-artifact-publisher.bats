#!/usr/bin/env bats
set -euo pipefail

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
readonly REPO_ROOT

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

rendered_publisher() {
  if [[ -n "${TEST_WORKSTATION_RENDERED_CONFIGURATION:-}" ]]; then
    jq -c '.artifactPublisher' "$TEST_WORKSTATION_RENDERED_CONFIGURATION"
  else
    nix eval --json "$REPO_ROOT#homeConfigurations.workstation.config" \
      --apply 'c: {
        text = c.xdg.configFile."faviann-skills/artifacts.json".text;
        target = c.xdg.configFile."faviann-skills/artifacts.json".target;
        managedPaths = builtins.filter
          (path: builtins.match ".*faviann-skills/artifacts\\.json" path != null)
          (builtins.attrNames c.home.file);
        sessionVariables = builtins.attrNames c.home.sessionVariables;
        inherit (c.home) homeDirectory;
      }'
  fi
}

@test "test_artifact_mapping_declares_the_agreed_directory_and_base_url" {
  local publisher
  publisher="$(rendered_publisher)"

  diff -u \
    <(printf '%s\n' '{"baseUrl":"https://artifacts.admin.faviann.com","directory":"/ephemeral/workstation/artifacts"}') \
    <(jq -c -S '.text | fromjson' <<<"$publisher") \
    || fail 'the mapping is not exactly the agreed directory and base URL'
}

@test "test_artifact_mapping_installs_at_the_publisher_discovery_path" {
  local publisher
  local target
  local home
  publisher="$(rendered_publisher)"
  target="$(jq -r '.target' <<<"$publisher")"
  home="$(jq -r '.homeDirectory' <<<"$publisher")"

  if [[ "$target" != /* ]]; then
    target="$home/$target"
  fi
  [[ "$target" == '/home/faviann/.config/faviann-skills/artifacts.json' ]] \
    || fail "mapping installs at $target, not the publisher's discovery path"
}

@test "test_artifact_mapping_has_a_single_manager_and_no_global_selector" {
  local publisher
  publisher="$(rendered_publisher)"

  diff -u \
    <(printf '%s\n' '/home/faviann/.config/faviann-skills/artifacts.json') \
    <(jq -r '.managedPaths[]' <<<"$publisher") \
    || fail 'the mapping is not managed by exactly one declaration'
  if jq -e '.sessionVariables | index("FAVIANN_SKILLS_ARTIFACT_CONFIG")' \
    <<<"$publisher" >/dev/null; then
    fail 'a global publisher-configuration selector was declared'
  fi
}
