#!/usr/bin/env bats

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  bats_require_minimum_version 1.5.0
  export HOME="$BATS_TEST_TMPDIR/home"
  export STATE="$BATS_TEST_TMPDIR/stub-state" GH_LOG="$BATS_TEST_TMPDIR/real-gh-calls"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  unset GH_TOKEN GITHUB_TOKEN
  wrapper_bin="$HOME/.local/bin"
  real_bin="$BATS_TEST_TMPDIR/real-bin"
  mkdir -p "$wrapper_bin" "$real_bin" "$STATE/private" "$HOME/.config/github-tokens"
  printf 'main-token' >"$STATE/main-token"
  printf 'work-token\n' >"$HOME/.config/github-tokens/work"

  # Mirrors the real gh: an environment token wins over the stored login,
  # including for the git credential helper.
  cat >"$real_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|GH_TOKEN=%s\n' "$*" "${GH_TOKEN:-}" >>"$GH_LOG"
current_token="${GH_TOKEN:-$(cat "$STATE/main-token")}"
case "$*" in
  'auth git-credential get')
    cat >/dev/null
    printf 'username=x-access-token\npassword=%s\n' "$current_token"
    ;;
  api\ repos/*\ --jq\ *)
    repo="${2#repos/}"
    private=false
    [[ ! -e "$STATE/private/${repo/\//_}" ]] || private=true
    printf '%s\ttrunk\n' "$private"
    ;;
esac
STUB
  cp "$REPO_ROOT/dot_local/bin/executable_gh" "$wrapper_bin/gh"
  cp "$REPO_ROOT/dot_local/bin/executable_github-token" "$wrapper_bin/github-token"
  sed -i "1c #!$(command -v bash)" "$wrapper_bin/"* "$real_bin/gh"
  chmod +x "$wrapper_bin/"* "$real_bin/gh"
  export PATH="$wrapper_bin:$real_bin:$PATH"

  cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
    name = Test Operator
    email = operator@example.test
[credential "https://github.com"]
    helper =
    helper = !gh auth git-credential
[credential "https://github.com/example-org"]
    helper =
    helper = !github-token credential work
EOF

  checkout="$BATS_TEST_TMPDIR/checkout"
  git init --quiet --initial-branch=main "$checkout"
  git -C "$checkout" commit --quiet --allow-empty -m initial
  git -C "$checkout" remote add origin git@github.com:faviann/project.git
}

# The last real gh call, which is the command itself; the private-fork check
# calls gh before it.
real_gh_command() {
  tail -n 1 "$GH_LOG"
}

add_upstream() {
  git -C "$checkout" remote add upstream https://github.com/example-org/project.git
}

@test "test_wrapper_routes_an_explicit_repository_to_its_owners_token" {
  gh pr list --repo example-org/project
  [ "$(real_gh_command)" = 'pr list --repo example-org/project|GH_TOKEN=work-token' ]
  gh pr list -R example-org/project
  [ "$(real_gh_command)" = 'pr list -R example-org/project|GH_TOKEN=work-token' ]
  gh issue list --repo faviann/project
  [ "$(real_gh_command)" = 'issue list --repo faviann/project|GH_TOKEN=' ]
}

@test "test_wrapper_routes_a_pull_request_url_to_its_owners_token" {
  cd "$checkout"
  gh pr view https://github.com/example-org/project/pull/7 --comments
  [ "$(real_gh_command)" = 'pr view https://github.com/example-org/project/pull/7 --comments|GH_TOKEN=work-token' ]

  gh issue comment 5 --body 'https://github.com/example-org/project/pull/7 fixed this'
  [ "$(real_gh_command)" = 'issue comment 5 --body https://github.com/example-org/project/pull/7 fixed this|GH_TOKEN=' ]
}

@test "test_wrapper_routes_api_repository_endpoints_to_their_owners_token" {
  gh api repos/example-org/project/pulls --paginate
  [ "$(real_gh_command)" = 'api repos/example-org/project/pulls --paginate|GH_TOKEN=work-token' ]
  gh api /repos/example-org/project
  [ "$(real_gh_command)" = 'api /repos/example-org/project|GH_TOKEN=work-token' ]
  gh api repos/faviann/project/pulls
  [ "$(real_gh_command)" = 'api repos/faviann/project/pulls|GH_TOKEN=' ]
}

@test "test_wrapper_routes_repo_view_and_clone_by_their_repository_argument" {
  gh repo view example-org/project
  [ "$(real_gh_command)" = 'repo view example-org/project|GH_TOKEN=work-token' ]
  gh repo clone example-org/project target -- --depth 1
  [ "$(real_gh_command)" = 'repo clone example-org/project target -- --depth 1|GH_TOKEN=work-token' ]
}

@test "test_wrapper_routes_a_checkout_by_gh_base_repository_choice" {
  cd "$checkout"
  gh pr list
  [ "$(real_gh_command)" = 'pr list|GH_TOKEN=' ]

  add_upstream
  gh pr list
  [ "$(real_gh_command)" = 'pr list|GH_TOKEN=work-token' ]

  git config remote.origin.gh-resolved base
  gh pr list
  [ "$(real_gh_command)" = 'pr list|GH_TOKEN=' ]

  git remote remove upstream
  git config remote.origin.gh-resolved example-org/project
  gh pr list
  [ "$(real_gh_command)" = 'pr list|GH_TOKEN=work-token' ]
}

@test "test_wrapper_never_routes_gh_auth_even_in_an_org_checkout" {
  cd "$checkout"
  add_upstream
  : >"$GH_LOG"
  run gh auth git-credential get <<<$'protocol=https\nhost=github.com\npath=faviann/project\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *'password=main-token'* ]]
  [ "$(cat "$GH_LOG")" = 'auth git-credential get|GH_TOKEN=' ]
}

@test "test_wrapper_respects_a_token_already_in_the_environment" {
  cd "$checkout"
  add_upstream
  : >"$GH_LOG"
  GH_TOKEN=explicit-token gh pr list
  [ "$(cat "$GH_LOG")" = 'pr list|GH_TOKEN=explicit-token' ]
  : >"$GH_LOG"
  GITHUB_TOKEN=explicit-token gh pr list
  [ "$(cat "$GH_LOG")" = 'pr list|GH_TOKEN=' ]
}

@test "test_wrapper_passes_through_targets_it_cannot_route" {
  : >"$GH_LOG"
  gh pr list --repo ghe.example.test/example-org/project
  [ "$(cat "$GH_LOG")" = 'pr list --repo ghe.example.test/example-org/project|GH_TOKEN=' ]
  : >"$GH_LOG"
  gh repo clone project
  [ "$(cat "$GH_LOG")" = 'repo clone project|GH_TOKEN=' ]
}

setup_private_fork_branch() {
  local fork="$BATS_TEST_TMPDIR/fork.git"

  cd "$checkout" || return
  add_upstream
  touch "$STATE/private/example-org_project"
  git init --quiet --bare "$fork"
  git config --global url."$fork".insteadOf git@github.com:faviann/project.git
  git checkout --quiet -b feat/thing
  git push --quiet origin feat/thing
  : >"$GH_LOG"
}

@test "test_wrapper_hands_off_a_private_fork_pull_request_to_the_browser" {
  setup_private_fork_branch
  run --separate-stderr gh pr create --title 'Fix: a & b' --body $'line one\nline two' \
    --base release --draft --label bug
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = 'https://github.com/example-org/project/compare/release...faviann:project:feat/thing?expand=1&title=Fix%3A%20a%20%26%20b&body=line%20one%0Aline%20two' ]
  [[ "$output" == *'gh pr view --repo example-org/project faviann:feat/thing'* ]]
  run ! grep -q '^pr create' "$GH_LOG"

  run --separate-stderr gh pr create -t 'From stdin' --body-file - <<<'piped body'
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = 'https://github.com/example-org/project/compare/trunk...faviann:project:feat/thing?expand=1&title=From%20stdin&body=piped%20body' ]
  run ! grep -q '^pr create' "$GH_LOG"
}

@test "test_wrapper_requires_the_fork_branch_to_be_pushed_before_hand_off" {
  setup_private_fork_branch
  git checkout --quiet -b feat/unpushed
  run gh pr create --title 'Not yet'
  [ "$status" -eq 1 ]
  [[ "$output" == *'branch feat/unpushed is not on origin (faviann/project); push it first'* ]]
  [[ "$output" != *compare* ]]
  run ! grep -q '^pr create' "$GH_LOG"
}

@test "test_wrapper_lets_gh_open_pull_requests_it_can_open" {
  setup_private_fork_branch
  rm "$STATE/private/example-org_project"
  run gh pr create --title Public
  [ "$status" -eq 0 ]
  [ "$(real_gh_command)" = 'pr create --title Public|GH_TOKEN=work-token' ]

  # A branch pushed to the private base repository itself needs no fork.
  touch "$STATE/private/example-org_project"
  git remote set-url origin https://github.com/example-org/project.git
  git remote remove upstream
  run gh pr create --title Direct
  [ "$status" -eq 0 ]
  [ "$(real_gh_command)" = 'pr create --title Direct|GH_TOKEN=work-token' ]
}
