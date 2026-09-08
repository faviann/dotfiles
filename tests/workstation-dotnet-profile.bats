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
