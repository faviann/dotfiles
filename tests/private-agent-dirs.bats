#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

run_chezmoi() {
  local profile="$1"
  local home="$2"
  local runtime_dir="$BATS_TEST_TMPDIR/runtime-$profile"
  shift 2

  mkdir -p "$home" "$runtime_dir"
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
    --override-data "{\"profile\":\"$profile\"}" \
    "$@"
}

@test "test_agent_state_directories_are_owner_only_on_every_profile" {
  local profile home dir
  local -a dirs

  for profile in workstation desktop; do
    home="$BATS_TEST_TMPDIR/$profile"
    dirs=(.agents .claude .codex .config/opencode)
    [[ "$profile" != workstation ]] || dirs+=(.pi)
    for dir in "${dirs[@]}"; do
      mkdir -p "$home/$dir"
      chmod 775 "$home/$dir"
    done

    run_chezmoi "$profile" "$home" apply --force --recursive=false \
      "$home/.config" "${dirs[@]/#/$home/}"

    for dir in "${dirs[@]}"; do
      [[ "$(stat -c %a "$home/$dir")" == 700 ]] \
        || fail "$profile: ~/$dir is $(stat -c %a "$home/$dir"), not 700"
    done
  done
}
