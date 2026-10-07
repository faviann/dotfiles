#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}

assert_has_line() {
  local expected="$1"
  local file="$2"

  grep -Fqx -- "$expected" "$file" \
    || fail "expected $expected in $file"
}

assert_lacks_line() {
  local unexpected="$1"
  local file="$2"

  if grep -Fqx -- "$unexpected" "$file"; then
    fail "did not expect $unexpected in $file"
  fi
}

assert_lacks_text() {
  local unexpected="$1"
  local file="$2"

  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect $unexpected in $file"
  fi
}

run_chezmoi() {
  local source_dir="$1"
  local destination_dir="$2"
  local runtime_dir
  shift 2

  runtime_dir="$(dirname "$destination_dir")/runtime"
  mkdir -p "$runtime_dir"
  HOME="$destination_dir" \
  XDG_CACHE_HOME="$runtime_dir/cache" \
  XDG_CONFIG_HOME="$runtime_dir/config" \
  XDG_STATE_HOME="$runtime_dir/state" \
    chezmoi \
    --source "$source_dir" \
    --destination "$destination_dir" \
    --config /dev/null \
    --config-format toml \
    "$@"
}

@test "test_repository_only_paths_are_ignored" {
  local test_dir
  local source_dir
  local destination_dir
  local managed_file
  local ignored_file
  local path

  test_dir="$(mktemp -d)"
  source_dir="$test_dir/source"
  destination_dir="$test_dir/home"
  managed_file="$test_dir/managed"
  ignored_file="$test_dir/ignored"
  mkdir -p "$source_dir/docs" "$source_dir/tests" "$source_dir/scripts" \
    "$source_dir/home" "$source_dir/packages" "$source_dir/.github/workflows" \
    "$source_dir/dot_local/bin" "$destination_dir"
  cp "$REPO_ROOT/.chezmoiignore" "$source_dir/.chezmoiignore"

  for path in \
    README.md BOOTSTRAP.md AGENTS.md CLAUDE.md CONTRIBUTING.md \
    CONTEXT.md CONTEXT-MAP.md docs/guide.md tests/inventory.bats \
    scripts/update-dotnet-sdk .github/workflows/update-dotnet-sdk.yml \
    flake.nix flake.lock home/workstation.nix packages/moraine.nix; do
    printf 'repository only\n' >"$source_dir/$path"
  done
  printf 'intentional login profile\n' >"$source_dir/dot_bash_profile"
  printf 'intentional dotfile\n' >"$source_dir/dot_bashrc"
  printf '#!/usr/bin/env bash\n' \
    >"$source_dir/dot_local/bin/executable_update-agent-tools"
  printf '#!/usr/bin/env bash\n' \
    >"$source_dir/dot_local/bin/executable_workstation-update"

  run_chezmoi "$source_dir" "$destination_dir" \
    --override-data '{"is_workstation":false}' \
    managed --path-style relative >"$managed_file"
  run_chezmoi "$source_dir" "$destination_dir" \
    --override-data '{"is_workstation":false}' \
    ignored >"$ignored_file"

  for path in \
    README.md BOOTSTRAP.md AGENTS.md CLAUDE.md CONTRIBUTING.md \
    CONTEXT.md CONTEXT-MAP.md flake.nix flake.lock; do
    assert_lacks_line "$path" "$managed_file"
    assert_has_line "$path" "$ignored_file"
  done
  for path in \
    docs/guide.md tests/inventory.bats scripts/update-dotnet-sdk \
    .github/workflows/update-dotnet-sdk.yml home/workstation.nix \
    packages/moraine.nix; do
    assert_lacks_line "$path" "$managed_file"
  done
  for path in docs tests scripts home packages; do
    assert_has_line "$path" "$ignored_file"
  done
  assert_has_line '.bash_profile' "$managed_file"
  assert_has_line '.bashrc' "$managed_file"
  assert_has_line '.local/bin/update-agent-tools' "$managed_file"
  assert_has_line '.local/bin/workstation-update' "$managed_file"
}

@test "test_fish_is_ignored_only_on_the_configured_workstation" {
  local test_dir
  local source_dir
  local destination_dir
  local managed_file
  local ignored_file

  test_dir="$(mktemp -d)"
  source_dir="$test_dir/source"
  destination_dir="$test_dir/home"
  managed_file="$test_dir/managed"
  ignored_file="$test_dir/ignored"
  mkdir -p "$source_dir/dot_config/fish/functions" "$destination_dir"
  cp "$REPO_ROOT/.chezmoiignore" "$source_dir/.chezmoiignore"
  printf 'set fish_greeting\n' >"$source_dir/dot_config/fish/config.fish"
  printf 'function fish_greeting\nend\n' \
    >"$source_dir/dot_config/fish/functions/fish_greeting.fish"

  run_chezmoi "$source_dir" "$destination_dir" \
    --override-data '{"is_workstation":true}' \
    managed --path-style relative >"$managed_file"
  run_chezmoi "$source_dir" "$destination_dir" \
    --override-data '{"is_workstation":true}' \
    ignored >"$ignored_file"

  assert_lacks_line '.config/fish/config.fish' "$managed_file"
  assert_lacks_line '.config/fish/functions/fish_greeting.fish' "$managed_file"
  assert_has_line '.config/fish' "$ignored_file"

  run_chezmoi "$source_dir" "$destination_dir" \
    --override-data '{"is_workstation":false}' \
    managed --path-style relative >"$managed_file"
  run_chezmoi "$source_dir" "$destination_dir" \
    --override-data '{"is_workstation":false}' \
    ignored >"$ignored_file"

  assert_has_line '.config/fish/config.fish' "$managed_file"
  assert_has_line '.config/fish/functions/fish_greeting.fish' "$managed_file"
  assert_lacks_line '.config/fish' "$ignored_file"
}

@test "test_dry_run_proposes_only_intentional_targets" {
  local test_dir
  local source_dir
  local destination_dir
  local dry_run_file
  local path

  test_dir="$(mktemp -d)"
  source_dir="$test_dir/source"
  destination_dir="$test_dir/home"
  dry_run_file="$test_dir/dry-run"
  mkdir -p "$source_dir/docs" "$source_dir/tests" "$source_dir/home" \
    "$source_dir/dot_local/bin" "$destination_dir"
  cp "$REPO_ROOT/.chezmoiignore" "$source_dir/.chezmoiignore"

  for path in \
    README.md docs/guide.md tests/inventory.bats \
    flake.nix home/workstation.nix; do
    printf 'repository only\n' >"$source_dir/$path"
  done
  printf 'intentional login profile\n' >"$source_dir/dot_bash_profile"
  printf 'intentional dotfile\n' >"$source_dir/dot_bashrc"
  printf '#!/usr/bin/env bash\n' \
    >"$source_dir/dot_local/bin/executable_update-agent-tools"
  printf '#!/usr/bin/env bash\n' \
    >"$source_dir/dot_local/bin/executable_workstation-update"

  run_chezmoi "$source_dir" "$destination_dir" \
    --override-data '{"is_workstation":false}' \
    apply --dry-run --verbose >"$dry_run_file"

  grep -Fq 'diff --git a/.bash_profile b/.bash_profile' "$dry_run_file" \
    || fail 'dry-run did not propose the intentional login profile'
  grep -Fq 'diff --git a/.bashrc b/.bashrc' "$dry_run_file" \
    || fail 'dry-run did not propose the intentional bashrc target'
  grep -Fq \
    'diff --git a/.local/bin/update-agent-tools b/.local/bin/update-agent-tools' \
    "$dry_run_file" \
    || fail 'dry-run did not propose the intentional maintenance executable'
  grep -Fq \
    'diff --git a/.local/bin/workstation-update b/.local/bin/workstation-update' \
    "$dry_run_file" \
    || fail 'dry-run did not propose the intentional login executable'
  for path in README.md docs/guide.md tests/inventory.bats flake.nix home/workstation.nix; do
    assert_lacks_text "$path" "$dry_run_file"
  done
  [[ -z "$(find "$destination_dir" -mindepth 1 -print -quit)" ]] \
    || fail 'dry-run changed the isolated destination'
}
