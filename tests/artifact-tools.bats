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
