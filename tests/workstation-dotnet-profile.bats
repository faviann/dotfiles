#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}

@test "test_workstation_profile_includes_dotnet_10_lts_sdk" {
  local dotnet_sdk_package

  dotnet_sdk_package="$(
    rendered_json '.dotnetSdkPackage' \
      "$REPO_ROOT#homeConfigurations.workstation.config.home.packages" \
      --apply '
        packages:
        let
          package = builtins.head (
            builtins.filter
              (package: (package.pname or package.name) == "dotnet-sdk-wrapped")
              packages
          );
        in
        {
          pname = package.pname or package.name;
          inherit (package) version;
        }
      '
  )" || fail 'could not render the workstation .NET SDK package'

  jq -e '
    (.pname == "dotnet-sdk-wrapped") and
    (.version | startswith("10."))
  ' <<<"$dotnet_sdk_package" >/dev/null \
    || fail 'rendered workstation package profile does not include the .NET 10 LTS SDK'
}

@test "test_each_profile_includes_the_dotnet_sdk_and_search_tools" {
  local profile
  local packages

  for profile in workstation desktop; do
    packages="$(
      rendered_json ".artifactTools.$profile.packages" \
        "$REPO_ROOT#homeConfigurations.$profile.config.home.packages" \
        --apply 'packages: map (package: package.pname or package.name) packages'
    )" || fail "could not render the $profile package names"

    jq -e '
      index("dotnet-sdk-wrapped") and index("ripgrep") and
      index("fd") and index("fzf")
    ' <<<"$packages" >/dev/null \
      || fail "$profile profile lacks the .NET SDK or a search tool: $packages"
  done
}
