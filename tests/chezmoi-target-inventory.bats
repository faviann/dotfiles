#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}

# Every managed target and the machine profiles that get it.
readonly INVENTORY='
.agents/AGENTS.md                               workstation desktop
.ansible/ssh/proxmox_lxc                        workstation bootstrap
.ansible/ssh/proxmox_lxc.pub                    workstation bootstrap
.ansible/vault-pass                             workstation bootstrap
.bash_profile                                   workstation bootstrap desktop
.bashrc                                         workstation bootstrap desktop
.chezmoiscripts/github-known-hosts.sh           workstation desktop
.chezmoiscripts/install-herdr-integrations.sh   workstation desktop
.chezmoiscripts/install-herdr.sh                workstation desktop
.chezmoiscripts/install-packages.sh             desktop
.chezmoiscripts/reconcile-agent-skills.sh       workstation desktop
.chezmoiscripts/switch-chezmoi-origin-to-ssh.sh workstation desktop
.claude/CLAUDE.md                               workstation desktop
.claude/hooks/track-session-prs.sh              workstation desktop
.claude/settings.json                           workstation desktop
.claude/statusline.sh                           workstation desktop
.codex/AGENTS.md                                workstation desktop
.config/claude/gateway-admin-key                workstation desktop
.config/claude/gateway-token                    workstation desktop
.config/fish/config.fish                        desktop
.config/fish/functions/fish_greeting.fish       desktop
.config/git/ignore                              workstation bootstrap desktop
.config/github-tokens/work                      workstation desktop
.config/opencode/AGENTS.md                      workstation desktop
.gitconfig                                      workstation desktop
.local/bin/dev-session                          workstation
.local/bin/gh                                   workstation desktop
.local/bin/github-token                         workstation desktop
.local/bin/update-agent-tools                   workstation
.local/bin/workstation-update                   workstation
.npmrc                                          workstation desktop
.pi/agent/AGENTS.md                             workstation desktop
.ssh/allowed_signers                            workstation desktop
.ssh/config                                     workstation desktop
.ssh/id_ed25519                                 workstation desktop
.ssh/id_ed25519.pub                             workstation desktop
'

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

assert_profile_inventory() {
  local profile="$1"
  local test_dir

  test_dir="$(mktemp -d)"
  mkdir -p "$test_dir/home"
  awk -v profile="$profile" \
    'NF { for (i = 2; i <= NF; i++) if ($i == profile) print $1 }' \
    <<<"$INVENTORY" | LC_ALL=C sort >"$test_dir/expected"
  run_chezmoi "$REPO_ROOT" "$test_dir/home" \
    --override-data "{\"profile\":\"$profile\"}" \
    managed --include files,symlinks,scripts --path-style relative \
    | LC_ALL=C sort >"$test_dir/actual"

  diff -u "$test_dir/expected" "$test_dir/actual"
}

@test "test_workstation_profile_manages_its_inventory" {
  assert_profile_inventory workstation
}

@test "test_bootstrap_profile_manages_its_inventory" {
  assert_profile_inventory bootstrap
}

@test "test_desktop_profile_manages_its_inventory" {
  assert_profile_inventory desktop
}

@test "test_repository_only_paths_are_ignored" {
  local test_dir
  local source_dir
  local destination_dir
  local managed_file
  local path

  test_dir="$(mktemp -d)"
  source_dir="$test_dir/source"
  destination_dir="$test_dir/home"
  managed_file="$test_dir/managed"
  mkdir -p "$source_dir/docs" "$source_dir/tests" "$source_dir/scripts" \
    "$source_dir/home" "$source_dir/packages" "$source_dir/.github/workflows" \
    "$destination_dir"
  cp "$REPO_ROOT/.chezmoiignore" "$source_dir/.chezmoiignore"

  for path in \
    README.md BOOTSTRAP.md AGENTS.md CLAUDE.md CONTRIBUTING.md \
    CONTEXT.md CONTEXT-MAP.md docs/guide.md tests/inventory.bats \
    scripts/update-dotnet-sdk .github/workflows/update-dotnet-sdk.yml \
    flake.nix flake.lock home/workstation.nix packages/moraine.nix; do
    printf 'repository only\n' >"$source_dir/$path"
  done

  run_chezmoi "$source_dir" "$destination_dir" \
    --override-data '{"profile":"workstation"}' \
    managed --path-style relative >"$managed_file"

  [[ ! -s "$managed_file" ]] \
    || fail "repository-only paths are managed: $(cat "$managed_file")"
}
