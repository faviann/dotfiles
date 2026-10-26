#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}

rendered_artifact_tools() {
  local profile="$1"

  rendered_json ".artifactTools.$profile" \
    "$REPO_ROOT#homeConfigurations.$profile.config" \
    --apply '
      configuration: {
        packages = map
          (package: package.pname or package.name)
          configuration.home.packages;
        fontconfigEnabled = configuration.fonts.fontconfig.enable;
      }
    '
}

@test "artifact-server tarball is pinned" {
  local release

  release="$(
    rendered_json '.artifactServerRelease' \
      "$REPO_ROOT#packages.x86_64-linux.artifact-server.passthru.release"
  )" || fail 'could not render the artifact-server release'

  jq -e '
    (.version == "0.1.2") and
    (.url == "https://github.com/plannotator/artifact-server/releases/download/v0.1.2/artifact-server-0.1.2-node.tar.gz") and
    (.sha256 == "f6a289c4e2c93d2e8bc9af792796b9c5c7e87e41d3c3e878e267c7db6d336fe4")
  ' <<<"$release" >/dev/null \
    || fail "artifact-server release is not the pinned tarball: $release"
}

@test "workstation profile ships the publishing toolchain" {
  local tools

  tools="$(rendered_artifact_tools workstation)" \
    || fail 'could not render the workstation toolchain'

  jq -e '
    (.packages | index("artifact-server")) and
    (.packages | index("chromium")) and
    (.packages | index("dejavu-fonts")) and
    .fontconfigEnabled
  ' <<<"$tools" >/dev/null \
    || fail "workstation toolchain is incomplete: $tools"
}

@test "desktop profile ships the publishing toolchain" {
  local tools

  tools="$(rendered_artifact_tools desktop)" \
    || fail 'could not render the desktop toolchain'

  jq -e '
    (.packages | index("artifact-server")) and
    (.packages | index("chromium")) and
    (.packages | index("dejavu-fonts")) and
    .fontconfigEnabled
  ' <<<"$tools" >/dev/null \
    || fail "desktop toolchain is incomplete: $tools"
}

readonly HOME_MANAGER_SCRIPT='.chezmoiscripts/run_onchange_after_apply-home-manager.sh.tmpl'

render_home_manager_script() {
  local source_dir="$1"
  local output="$2"
  local destination="$BATS_TEST_TMPDIR/destination"

  mkdir -p "$destination"
  chezmoi \
    --source "$source_dir" \
    --destination "$destination" \
    --config /dev/null \
    --config-format toml \
    --persistent-state "$BATS_TEST_TMPDIR/chezmoistate.boltdb" \
    execute-template \
    --file "$REPO_ROOT/$HOME_MANAGER_SCRIPT" \
    >"$output"
  chmod +x "$output"
}

@test "home manager script is a desktop-only target" {
  local destination="$BATS_TEST_TMPDIR/home"
  local profile
  local managed

  mkdir -p "$destination"
  for profile in workstation desktop; do
    managed="$(
      chezmoi \
        --source "$REPO_ROOT" \
        --destination "$destination" \
        --config /dev/null \
        --config-format toml \
        --override-data "{\"profile\":\"$profile\"}" \
        managed --include scripts --path-style relative
    )"
    if [[ "$profile" == desktop ]]; then
      grep -qx '.chezmoiscripts/apply-home-manager.sh' <<<"$managed" \
        || fail 'the desktop profile does not run the Home Manager script'
    elif grep -q 'apply-home-manager' <<<"$managed"; then
      fail 'the workstation profile runs the desktop Home Manager script'
    fi
  done
}

@test "home manager script switches the desktop profile with the running user" {
  local script="$BATS_TEST_TMPDIR/apply-home-manager.sh"
  local bin="$BATS_TEST_TMPDIR/bin"
  local log="$BATS_TEST_TMPDIR/nix.log"

  render_home_manager_script "$REPO_ROOT" "$script"

  mkdir -p "$bin"
  printf '#!%s\n' "$(command -v bash)" >"$bin/nix"
  cat >>"$bin/nix" <<'STUB'
printf '%s\n' "$USER $HOME $*" >>"$NIX_LOG"
STUB
  chmod +x "$bin/nix"

  NIX_LOG="$log" USER=wrong HOME="$BATS_TEST_TMPDIR/tester-home" PATH="$bin:$PATH" bash "$script"

  [[ "$(<"$log")" == "$(id -un) $BATS_TEST_TMPDIR/tester-home run $REPO_ROOT#home-manager -- switch --impure --flake $REPO_ROOT#desktop" ]] \
    || fail "unexpected switch command: $(<"$log")"
}

@test "home manager script exits 1 and names the Nix install step when nix is absent" {
  local script="$BATS_TEST_TMPDIR/apply-home-manager.sh"
  local empty="$BATS_TEST_TMPDIR/empty-path"
  local status=0
  local output

  render_home_manager_script "$REPO_ROOT" "$script"
  mkdir -p "$empty"

  output="$(PATH="$empty" "$(command -v bash)" "$script" 2>&1)" || status=$?

  [[ "$status" -eq 1 ]] || fail "expected exit status 1, got $status"
  [[ "$output" == *'Install Determinate Nix as in step 1 of BOOTSTRAP.md'* ]] \
    || fail "message does not name the Nix install step: $output"
}

@test "home manager script reruns when the Home Manager source changes" {
  local source_dir="$BATS_TEST_TMPDIR/source"
  local before="$BATS_TEST_TMPDIR/before.sh"
  local after="$BATS_TEST_TMPDIR/after.sh"

  mkdir -p "$source_dir"
  cp -R "$REPO_ROOT/flake.nix" "$REPO_ROOT/flake.lock" "$REPO_ROOT/home" \
    "$REPO_ROOT/packages" "$source_dir"

  render_home_manager_script "$source_dir" "$before"
  printf '# a comment\n' >>"$source_dir/home/artifact-tools.nix"
  render_home_manager_script "$source_dir" "$after"

  ! cmp -s "$before" "$after" \
    || fail 'a change under home/ left the script text, and its chezmoi hash, unchanged'
}
