#!/usr/bin/env bats
set -euo pipefail

# dev-session is exercised against a real disposable repository and a Herdr
# stub that models only the workspace, pane, and agent surface the command
# uses. Git behavior is therefore real; Herdr behavior is observable.

setup() {
  bats_require_minimum_version 1.5.0
  export HOME="$BATS_TEST_TMPDIR/home"
  export BIN="$HOME/.local/bin"
  mkdir -p "$BIN" "$HOME/repos"
  export COMMAND="$BATS_TEST_DIRNAME/../dot_local/bin/executable_dev-session"
  export COMMAND_LOG="$BATS_TEST_TMPDIR/herdr-commands"
  export HERDR_STATE="$BATS_TEST_TMPDIR/herdr-state.json"
  : >"$COMMAND_LOG"
  printf '{"seq":0,"workspaces":[],"tabs":[],"panes":[]}\n' >"$HERDR_STATE"

  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

  # The command prepends ~/.local/bin to PATH, which is where the stub lives.
  install_herdr_stub
  create_disposable_repository
}

create_disposable_repository() {
  local seed="$BATS_TEST_TMPDIR/seed"

  git init -q -b main "$seed"
  git -C "$seed" commit -q --allow-empty -m 'initial'
  git clone -q --bare "$seed" "$BATS_TEST_TMPDIR/origin.git"
  clone_project demo
  export REPOSITORY="$HOME/repos/demo"
  export WORKTREE="$HOME/worktrees/demo/issue-7"
}

clone_project() {
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$HOME/repos/$1"
}

install_herdr_stub() {
  printf '#!%s\n' "$(command -v bash)" >"$BIN/herdr"
  cat >>"$BIN/herdr" <<'STUB'
set -euo pipefail

printf '%s\n' "$*" >>"$COMMAND_LOG"
state="$HERDR_STATE"

emit() { jq -nc --argjson result "$1" '{id:"stub",result:$result}'; }
save() { printf '%s\n' "$1" >"$state"; }
next_id() {
  local seq
  seq="$(( $(jq -r '.seq' "$state") + 1 ))"
  save "$(jq -c --argjson seq "$seq" '.seq = $seq' "$state")"
  printf '%s\n' "$seq"
}

group="$1"
subcommand="$2"
shift 2

case "$group:$subcommand" in
  workspace:list)
    emit "$(jq -c '{type:"workspace_list",workspaces:.workspaces}' "$state")"
    ;;
  workspace:create)
    cwd='' label=''
    while (( $# )); do
      case "$1" in
        --cwd) cwd="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    seq="$(next_id)"
    workspace="w$seq" tab="w$seq:t1" pane="w$seq:p1"
    save "$(jq -c \
      --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" \
      --arg cwd "$cwd" --arg label "$label" '
      .workspaces += [{workspace_id:$workspace,label:$label}]
      | .tabs += [{tab_id:$tab,workspace_id:$workspace}]
      | .panes += [{pane_id:$pane,workspace_id:$workspace,tab_id:$tab,cwd:$cwd}]
    ' "$state")"
    emit "$(jq -nc \
      --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" '
      {type:"workspace_created",workspace:{workspace_id:$workspace},
       tab:{tab_id:$tab},root_pane:{pane_id:$pane}}
    ')"
    ;;
  workspace:close)
    save "$(jq -c --arg workspace "$1" '
      .workspaces |= map(select(.workspace_id != $workspace))
      | .tabs |= map(select(.workspace_id != $workspace))
      | .panes |= map(select(.workspace_id != $workspace))
    ' "$state")"
    emit '{"type":"workspace_closed"}'
    ;;
  tab:create)
    workspace='' cwd=''
    while (( $# )); do
      case "$1" in
        --workspace) workspace="$2"; shift 2 ;;
        --cwd) cwd="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    seq="$(next_id)"
    tab="$workspace:t$seq" pane="$workspace:p$seq"
    save "$(jq -c \
      --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" \
      --arg cwd "$cwd" '
      .tabs += [{tab_id:$tab,workspace_id:$workspace}]
      | .panes += [{pane_id:$pane,workspace_id:$workspace,tab_id:$tab,cwd:$cwd}]
    ' "$state")"
    emit "$(jq -nc --arg tab "$tab" --arg pane "$pane" \
      '{type:"tab_created",tab:{tab_id:$tab},root_pane:{pane_id:$pane}}')"
    ;;
  pane:list)
    workspace=''
    while (( $# )); do
      case "$1" in
        --workspace) workspace="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    emit "$(jq -c --arg workspace "$workspace" \
      '{type:"pane_list",panes:[.panes[]|select(.workspace_id == $workspace)]}' \
      "$state")"
    ;;
  pane:send-keys)
    emit '{"type":"keys_sent"}'
    ;;
  pane:close)
    save "$(jq -c --arg pane "$1" '.panes |= map(select(.pane_id != $pane))' "$state")"
    emit '{"type":"pane_closed"}'
    ;;
  agent:list)
    emit "$(jq -c '{type:"agent_list",agents:[.panes[]|select(has("agent"))]}' "$state")"
    ;;
  agent:get)
    agent="$(jq -c --arg target "$1" \
      '[.panes[]|select(has("agent") and (.pane_id == $target or .name == $target))][0]' \
      "$state")"
    [[ "$agent" != null ]] || { printf 'no such agent\n' >&2; exit 1; }
    emit "$(jq -nc --argjson agent "$agent" '{type:"agent_info",agent:$agent}')"
    ;;
  agent:start)
    name="$1"
    shift
    pane=''
    while (( $# )); do
      case "$1" in
        --pane) pane="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "${HERDR_START_RESULT:-idle}" in
      fail) printf 'agent_start_failed\n' >&2; exit 1 ;;
      blocked) status=blocked ;;
      *) status="${HERDR_START_RESULT:-idle}" ;;
    esac
    # Herdr requires a valid name that no live agent already holds.
    [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] \
      || { printf 'invalid_agent_name\n' >&2; exit 1; }
    jq -e --arg name "$name" \
      '[.panes[] | select(has("agent") and .name == $name)] | length == 0' \
      "$state" >/dev/null \
      || { printf 'agent_name_in_use\n' >&2; exit 1; }
    save "$(jq -c --arg pane "$pane" --arg name "$name" --arg status "$status" '
      .panes |= map(
        if .pane_id == $pane then
          . + {agent:"codex",agent_status:$status,name:$name}
        else . end
      )
    ' "$state")"
    if [[ "$status" == blocked ]]; then
      printf 'agent_not_ready\n' >&2
      exit 1
    fi
    emit '{"type":"agent_started"}'
    ;;
  *)
    printf 'unsupported stub command: %s %s\n' "$group" "$subcommand" >&2
    exit 90
    ;;
esac
STUB
  chmod +x "$BIN/herdr"
}

herdr_state() { jq -c "$1" "$HERDR_STATE"; }

set_agent_status() {
  local pane="$1" status="$2"
  local updated
  updated="$(jq -c --arg pane "$pane" --arg status "$status" \
    '.panes |= map(if .pane_id == $pane then .agent_status = $status else . end)' \
    "$HERDR_STATE")"
  printf '%s\n' "$updated" >"$HERDR_STATE"
}

kill_agent() {
  local pane="$1"
  local updated
  updated="$(jq -c --arg pane "$pane" \
    '.panes |= map(if .pane_id == $pane then del(.agent,.agent_status,.name) else . end)' \
    "$HERDR_STATE")"
  printf '%s\n' "$updated" >"$HERDR_STATE"
}

add_foreign_pane() {
  local workspace="$1"
  local updated
  updated="$(jq -c --arg workspace "$workspace" \
    '.panes += [{pane_id:"\($workspace):pX",workspace_id:$workspace,tab_id:"\($workspace):tX",cwd:"/elsewhere"}]' \
    "$HERDR_STATE")"
  printf '%s\n' "$updated" >"$HERDR_STATE"
}

assert_branch_exists() {
  git -C "$REPOSITORY" show-ref --verify --quiet refs/heads/issue-7 \
    || { printf 'FAIL: issue-7 is gone\n' >&2; return 1; }
}

@test "test_ensure_creates_the_session_then_repeats_without_duplicate_resources" {
  run -0 bash "$COMMAND" ensure demo 7
  local first="$output"

  jq -e '
    (.project == "demo") and (.issue == "7") and (.branch == "issue-7")
    and (.repository | endswith("/repos/demo"))
    and (.worktree | endswith("/worktrees/demo/issue-7"))
    and (.target == "w1:p1") and (.worker_state == "idle")
  ' <<<"$first" >/dev/null

  [ -d "$WORKTREE" ]
  assert_branch_exists
  [[ "$(git -C "$WORKTREE" rev-parse issue-7)" == "$(git -C "$REPOSITORY" rev-parse origin/main)" ]]
  # Codex is launched with the pinned model and reasoning effort plus trust for
  # this worktree alone, and with nothing else.
  local launch
  launch="$(grep -F 'agent start ' "$COMMAND_LOG")"
  [[ "$launch" =~ ^'agent start demo-7-'[0-9a-f]{8}' --kind codex --pane w1:p1 -- -m gpt-5.6-luna -c model_reasoning_effort="xhigh" -c projects={"'"$WORKTREE"'"={trust_level="trusted"}}'$ ]]
  # Codex leaves a terminal keyboard report as pending shell input when it
  # exits, so the launch pane's input line is discarded first.
  [[ "$(grep -n 'pane send-keys w1:p1 ctrl+u' "$COMMAND_LOG" | cut -d: -f1)" \
    -lt "$(grep -n 'agent start demo-7-' "$COMMAND_LOG" | cut -d: -f1)" ]]

  : >"$COMMAND_LOG"
  run -0 bash "$COMMAND" ensure demo 7
  [[ "$output" == "$first" ]]
  run ! grep -Eq '^(workspace create|tab create|agent start|pane close|workspace close)' "$COMMAND_LOG"
  [[ "$(herdr_state '[(.workspaces|length),(.panes|length)]')" == '[1,1]' ]]
}

@test "test_distinct_session_identities_get_distinct_valid_worker_names" {
  local project
  local names

  # These four identities collapse onto one readable launch name: two differ
  # only past Herdr's length limit, two only in characters Herdr disallows.
  for project in a-very-long-project-name-variant-one \
    a-very-long-project-name-variant-two Foo.Bar foo-bar; do
    clone_project "$project"
    run -0 bash "$COMMAND" ensure "$project" 7
  done

  names="$(herdr_state '[.panes[] | select(has("agent")) | .name]')"
  [[ "$(jq 'length' <<<"$names")" == 4 ]]
  [[ "$(jq 'unique | length' <<<"$names")" == 4 ]]
  [[ "$(jq '[.[] | select(test("^[a-z][a-z0-9_-]{0,31}$"))] | length' <<<"$names")" == 4 ]]
}

@test "test_ensure_relaunches_a_dead_worker_and_preserves_uncommitted_work" {
  run -0 bash "$COMMAND" ensure demo 7
  printf 'work in progress\n' >"$WORKTREE/notes.txt"
  git -C "$WORKTREE" add notes.txt
  printf 'more\n' >>"$WORKTREE/notes.txt"
  kill_agent w1:p1
  : >"$COMMAND_LOG"

  run -0 bash "$COMMAND" ensure demo 7
  jq -e '.target == "w1:p1" and .worker_state == "idle"' <<<"$output" >/dev/null
  grep -Fq 'pane send-keys w1:p1 ctrl+u' "$COMMAND_LOG"
  grep -Eq 'agent start demo-7-[0-9a-f]{8} --kind codex --pane w1:p1' "$COMMAND_LOG"
  run ! grep -Eq '^(workspace create|tab create)' "$COMMAND_LOG"
  [[ "$(cat "$WORKTREE/notes.txt")" == $'work in progress\nmore' ]]
  [[ -n "$(git -C "$WORKTREE" status --porcelain)" ]]
}

@test "test_ensure_adds_a_session_tab_when_no_shell_pane_is_available" {
  run -0 bash "$COMMAND" ensure demo 7
  # The worker's pane is gone entirely, as after a closed pane rather than a
  # mere agent exit.
  printf '%s\n' "$(jq -c '.panes = []' "$HERDR_STATE")" >"$HERDR_STATE"
  : >"$COMMAND_LOG"

  run -0 bash "$COMMAND" ensure demo 7
  grep -Fq 'tab create --workspace w1' "$COMMAND_LOG"
  run ! grep -Fq 'workspace create' "$COMMAND_LOG"
  [[ "$(herdr_state '.workspaces|length')" == 1 ]]
}

@test "test_ensure_rejects_the_issue_branch_checked_out_elsewhere" {
  git -C "$REPOSITORY" worktree add -q -b issue-7 \
    "$BATS_TEST_TMPDIR/elsewhere" origin/main

  run -1 bash "$COMMAND" ensure demo 7
  [[ "$output" == *'issue-7 is checked out in'*'/elsewhere'* ]]
  [ ! -d "$WORKTREE" ]
  [[ "$(herdr_state '.panes|length')" == 0 ]]
}

@test "test_ensure_rejects_an_incompatible_checkout_at_the_expected_path" {
  git -C "$REPOSITORY" worktree add -q -b other "$WORKTREE" origin/main

  run -1 bash "$COMMAND" ensure demo 7
  [[ "$output" == *'already holds refs/heads/other instead of issue-7'* ]]
  [[ "$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD)" == other ]]
  [[ "$(herdr_state '.panes|length')" == 0 ]]
}

@test "test_ensure_rejects_an_unrelated_directory_at_the_expected_path" {
  mkdir -p "$WORKTREE"
  printf 'not a worktree\n' >"$WORKTREE/file"

  run -1 bash "$COMMAND" ensure demo 7
  [[ "$output" == *'is not a worktree of'* ]]
  [ -f "$WORKTREE/file" ]
}

@test "test_ensure_reuses_a_busy_worker_without_interrupting_it" {
  local worker_status

  run -0 bash "$COMMAND" ensure demo 7
  for worker_status in working blocked; do
    set_agent_status w1:p1 "$worker_status"
    : >"$COMMAND_LOG"

    run -0 bash "$COMMAND" ensure demo 7
    jq -e --arg status "$worker_status" \
      '.target == "w1:p1" and .worker_state == $status' <<<"$output" >/dev/null
    run ! grep -Eq '^(agent start|agent prompt|agent send-keys|agent focus|pane close|pane send-keys)' \
      "$COMMAND_LOG"
  done
}

@test "test_ensure_refuses_an_ambiguous_worker_match" {
  run -0 bash "$COMMAND" ensure demo 7
  printf '%s\n' "$(jq -c \
    '.panes += [(.panes[0] + {pane_id:"w1:p9"})]' "$HERDR_STATE")" >"$HERDR_STATE"
  : >"$COMMAND_LOG"

  run -1 bash "$COMMAND" ensure demo 7
  [[ "$output" == *'2 Herdr agents run in'* ]]
  run ! grep -Eq '^(agent start|pane close|workspace close)' "$COMMAND_LOG"
}

@test "test_ensure_requires_an_existing_repository" {
  run -1 bash "$COMMAND" ensure missing 7
  [[ "$output" == *'repos/missing is missing'* ]]
  [ ! -d "$HOME/repos/missing" ]
  [[ "$(herdr_state '.panes|length')" == 0 ]]
}

@test "test_ensure_reports_a_worker_that_never_appeared" {
  HERDR_START_RESULT=fail run -1 bash "$COMMAND" ensure demo 7
  [[ "$output" == *'no Codex worker is running in'* ]]
  [ -d "$WORKTREE" ]
}

@test "test_ensure_keeps_a_worker_blocked_on_its_own_startup_dialog" {
  HERDR_START_RESULT=blocked run -0 bash "$COMMAND" ensure demo 7
  jq -e '.target == "w1:p1" and .worker_state == "blocked"' <<<"$output" >/dev/null
}

@test "test_an_unreachable_herdr_refuses_once_and_starts_nothing" {
  printf '#!%s\nprintf "server unreachable\\n" >&2\nexit 1\n' \
    "$(command -v bash)" >"$BIN/herdr"

  run -1 bash "$COMMAND" ensure demo 7
  [[ "$output" == *'herdr agent list failed: server unreachable'* ]]
  [[ "$(grep -c '^dev-session:' <<<"$output")" == 1 ]]
}

@test "test_remove_deletes_the_session_and_preserves_the_branch" {
  run -0 bash "$COMMAND" ensure demo 7
  : >"$COMMAND_LOG"

  run -0 bash "$COMMAND" remove demo 7
  jq -e '
    .removed_workspace == "w1" and .removed_worktree == true
    and .branch_preserved == true and .removed_panes == []
  ' <<<"$output" >/dev/null
  grep -Fq 'workspace close w1' "$COMMAND_LOG"
  [ ! -d "$WORKTREE" ]
  assert_branch_exists
  [[ "$(herdr_state '[(.workspaces|length),(.panes|length)]')" == '[0,0]' ]]
}

@test "test_remove_refuses_a_working_worker" {
  run -0 bash "$COMMAND" ensure demo 7
  set_agent_status w1:p1 working
  : >"$COMMAND_LOG"

  run -1 bash "$COMMAND" remove demo 7
  [[ "$output" == *'is working; wait for it to settle'* ]]
  [ -d "$WORKTREE" ]
  run ! grep -Eq '^(pane close|workspace close)' "$COMMAND_LOG"
}

@test "test_remove_proceeds_when_worker_activity_is_unknown" {
  run -0 bash "$COMMAND" ensure demo 7
  set_agent_status w1:p1 unknown

  run -0 bash "$COMMAND" remove demo 7
  [ ! -d "$WORKTREE" ]
  assert_branch_exists
}

@test "test_remove_refuses_a_dirty_worktree" {
  run -0 bash "$COMMAND" ensure demo 7
  printf 'uncommitted\n' >"$WORKTREE/notes.txt"
  : >"$COMMAND_LOG"

  run -1 bash "$COMMAND" remove demo 7
  [[ "$output" == *'has uncommitted work'* ]]
  [ -f "$WORKTREE/notes.txt" ]
  run ! grep -Eq '^(pane close|workspace close)' "$COMMAND_LOG"
  [[ "$(herdr_state '.panes|length')" == 1 ]]
}

@test "test_remove_leaves_unrelated_workspace_contents_alone" {
  run -0 bash "$COMMAND" ensure demo 7
  add_foreign_pane w1
  : >"$COMMAND_LOG"

  run -0 bash "$COMMAND" remove demo 7
  jq -e '.removed_panes == ["w1:p1"] and .removed_workspace == ""' \
    <<<"$output" >/dev/null
  run ! grep -Fq 'workspace close' "$COMMAND_LOG"
  [[ "$(herdr_state '[(.workspaces[].workspace_id),(.panes[].pane_id)]')" == '["w1","w1:pX"]' ]]
}

@test "test_remove_disposes_of_a_worker_moved_out_of_the_session_workspace" {
  run -0 bash "$COMMAND" ensure demo 7

  # Herdr gives a pane moved into another workspace a new workspace-qualified
  # ID. Here the session workspace keeps a spare shell at the worktree and the
  # destination workspace holds an unrelated pane.
  printf '%s\n' "$(jq -c --arg cwd "$WORKTREE" '
    .workspaces += [{workspace_id:"w2",label:"unrelated"}]
    | .tabs += [{tab_id:"w2:t1",workspace_id:"w2"}]
    | .panes += [
        {pane_id:"w1:p2",workspace_id:"w1",tab_id:"w1:t1",cwd:$cwd},
        {pane_id:"w2:p1",workspace_id:"w2",tab_id:"w2:t1",cwd:"/elsewhere"}
      ]
    | .panes |= map(
        if .pane_id == "w1:p1"
        then . + {pane_id:"w2:p2",workspace_id:"w2",tab_id:"w2:t1"}
        else . end
      )
  ' "$HERDR_STATE")" >"$HERDR_STATE"
  : >"$COMMAND_LOG"

  run -0 bash "$COMMAND" remove demo 7
  jq -e '.removed_workspace == "w1" and .removed_panes == ["w2:p2"]' \
    <<<"$output" >/dev/null
  [[ "$(herdr_state '[.panes[] | select(has("agent"))] | length')" == 0 ]]
  [[ "$(herdr_state '[(.workspaces[].workspace_id),(.panes[].pane_id)]')" \
    == '["w2","w2:p1"]' ]]
  [ ! -d "$WORKTREE" ]
  assert_branch_exists
}

@test "test_remove_tolerates_resources_that_are_already_gone" {
  run -0 bash "$COMMAND" ensure demo 7
  run -0 bash "$COMMAND" remove demo 7

  run -0 bash "$COMMAND" remove demo 7
  jq -e '
    .removed_workspace == "" and .removed_worktree == false
    and .removed_panes == [] and .branch_preserved == true
  ' <<<"$output" >/dev/null
  assert_branch_exists
}

@test "test_invalid_invocations_change_nothing" {
  run -64 bash "$COMMAND" ensure demo
  run -64 bash "$COMMAND" restart demo 7
  run -1 bash "$COMMAND" ensure ../escape 7
  [[ "$output" == *'invalid project name'* ]]
  run -1 bash "$COMMAND" ensure demo main
  [[ "$output" == *'invalid issue number'* ]]
  [ ! -d "$HOME/worktrees" ]
  [[ "$(wc -l <"$COMMAND_LOG")" == 0 ]]
}
