#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}

readonly AGREED_MAPPING='{"baseUrl":"https://artifacts.public.faviann.com","directory":"/ephemeral/workstation/artifacts"}'

rendered_publisher() {
  rendered_json '.artifactPublisher' \
    "$REPO_ROOT#homeConfigurations.workstation.config" \
    --apply 'c: {
      activation = c.home.activation.artifactPublisherConfig;
      managedPaths = builtins.filter
        (path: builtins.match ".*faviann-skills/artifacts\\.json" path != null)
        (builtins.attrNames c.home.file);
      sessionVariables = builtins.attrNames c.home.sessionVariables;
    }'
}

run_writer() {
  local home="$1"
  local mapping="${2:-$AGREED_MAPPING}"
  env -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$home" \
    bash "$REPO_ROOT/scripts/artifact-publisher-config" "$mapping"
}

config_of() {
  printf '%s\n' "$1/.config/faviann-skills/artifacts.json"
}

token_of() {
  printf '%s\n' "$1/.local/state/faviann-skills/artifact-gallery"
}

@test "test_activation_writes_the_agreed_mapping_after_link_generation" {
  local publisher data mapping
  publisher="$(rendered_publisher)"
  data="$(jq -r '.activation.data' <<<"$publisher")"

  jq -e '.activation.after | index("linkGeneration")' <<<"$publisher" >/dev/null \
    || fail 'the writer can run before the previous generation link is removed'
  [[ "$data" == *"run /nix/store/"*"-artifact-publisher-config/bin/artifact-publisher-config '"* ]] \
    || fail "activation does not run the writer through Home Manager's run: $data"
  mapping="${data#*\'}"
  mapping="${mapping%\'*}"
  diff -u <(printf '%s\n' "$AGREED_MAPPING") <(jq -c -S . <<<"$mapping") \
    || fail 'the mapping is not exactly the agreed directory and base URL'
}

@test "test_artifact_mapping_has_no_home_manager_link_and_no_global_selector" {
  local publisher
  publisher="$(rendered_publisher)"

  jq -e '.managedPaths == []' <<<"$publisher" >/dev/null \
    || fail 'Home Manager still links the mapping file it no longer owns'
  if jq -e '.sessionVariables | index("FAVIANN_SKILLS_ARTIFACT_CONFIG")' \
    <<<"$publisher" >/dev/null; then
    fail 'a global publisher-configuration selector was declared'
  fi
}

@test "test_writer_generates_a_private_gallery_token_and_merges_it" {
  local home output token
  home="$(mktemp -d)"
  output="$(run_writer "$home" 2>&1)" || fail "writer failed: $output"
  token="$(<"$(token_of "$home")")"

  [[ "$token" =~ ^[0-9a-f]{32}$ ]] || fail 'token is not 16 random bytes in hex'
  [[ "$output" != *"$token"* ]] || fail 'writer printed the gallery token'
  [[ -f "$(config_of "$home")" && ! -L "$(config_of "$home")" ]] \
    || fail 'mapping is not a regular file'
  diff -u <(printf '600\n600\n') \
    <(stat -c '%a' "$(token_of "$home")" "$(config_of "$home")") \
    || fail 'token or mapping is readable by other users'
  diff -u \
    <(jq -c -S --arg gallery "$token" '. + {gallery: $gallery}' <<<"$AGREED_MAPPING") \
    <(jq -c -S . "$(config_of "$home")") \
    || fail 'mapping is not the declared values plus the gallery token'
}

@test "test_writer_keeps_the_token_across_runs_and_follows_mapping_changes" {
  local home first
  home="$(mktemp -d)"
  run_writer "$home"
  first="$(<"$(token_of "$home")")"
  run_writer "$home" '{"directory":"/srv/a","baseUrl":"https://a.example"}'

  [[ "$(<"$(token_of "$home")")" == "$first" ]] || fail 'rerun rotated the token'
  jq -e --arg gallery "$first" \
    '. == {directory: "/srv/a", baseUrl: "https://a.example", gallery: $gallery}' \
    "$(config_of "$home")" >/dev/null \
    || fail 'rerun did not rewrite the mapping with the new declared values'
}

@test "test_writer_replaces_a_leftover_store_link_without_touching_its_target" {
  local home target
  home="$(mktemp -d)"
  target="$home/store-artifacts.json"
  printf '%s\n' "$AGREED_MAPPING" >"$target"
  chmod 444 "$target"
  mkdir -p "$(dirname "$(config_of "$home")")"
  ln -s "$target" "$(config_of "$home")"

  run_writer "$home"

  [[ ! -L "$(config_of "$home")" ]] || fail 'the old link was written through, not replaced'
  jq -e 'has("gallery")' "$(config_of "$home")" >/dev/null || fail 'gallery missing'
  diff -u <(printf '%s\n' "$AGREED_MAPPING") "$target" || fail 'link target was modified'
}

@test "test_writer_honors_xdg_directories" {
  local home
  home="$(mktemp -d)"
  env HOME="$home" XDG_CONFIG_HOME="$home/cfg" XDG_STATE_HOME="$home/st" \
    bash "$REPO_ROOT/scripts/artifact-publisher-config" "$AGREED_MAPPING"

  [[ -f "$home/st/faviann-skills/artifact-gallery" ]] || fail 'token ignored XDG_STATE_HOME'
  [[ -f "$home/cfg/faviann-skills/artifacts.json" ]] || fail 'mapping ignored XDG_CONFIG_HOME'
}

@test "test_writer_refuses_an_invalid_token_and_keeps_the_previous_mapping" {
  local home output status=0
  home="$(mktemp -d)"
  run_writer "$home"
  cp "$(config_of "$home")" "$home/before.json"
  printf 'short\n' >"$(token_of "$home")"

  output="$(run_writer "$home" 2>&1)" || status=$?

  [[ "$status" != 0 ]] || fail 'writer accepted an invalid gallery token'
  [[ "$output" != *short* ]] || fail 'writer printed the token it refused'
  diff -u "$home/before.json" "$(config_of "$home")" || fail 'previous mapping was replaced'
}
