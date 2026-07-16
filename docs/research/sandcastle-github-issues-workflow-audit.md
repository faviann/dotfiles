# Sandcastle v0.12.0 GitHub Issues workflow audit

Researched 2026-07-16 against the upstream v0.12.0 tag at commit
[`e99f832f26dc9d245c019a9ddd19fa5dee792427`](https://github.com/mattpocock/sandcastle/tree/e99f832f26dc9d245c019a9ddd19fa5dee792427).
This note distinguishes Sandcastle's runtime guarantees from behavior merely
requested in its generated prompts.

## Answer for the disposable pilot

Yes: a pilot intended to evaluate Sandcastle's GitHub Issues workflow should
preserve discovery through the `Sandcastle` label. Bypassing the query and
injecting an issue number would test a custom single-task wrapper, not the
upstream issue-picking workflow. The generated GitHub integration's canonical
query is `gh issue list --state open --label Sandcastle ...`; it includes up to
100 issues with their bodies, labels, and comment bodies.
[GitHub tracker registry](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L530-L543)

The smallest safe adaptation is:

1. use the GitHub Issues choice and keep the `Sandcastle` label filter;
2. put that label on only the disposable pilot issue;
3. make the embedded list command fail non-zero unless its result contains
   exactly one issue, so the failure happens during prompt expansion before
   Codex starts (Sandcastle aborts when an embedded command fails);
4. set `maxIterations: 1` and use an explicit disposable
   `branch` strategy rather than the simple loop's `merge-to-head` default;
5. remove the stock instruction to close the issue and leave it open for human
   review.

[Prompt-command failure semantics](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L579-L595),
[simple-loop runtime defaults](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/main.mts#L20-L49),
[stock close instruction](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/prompt.md#L28-L47)

The count check belongs in the prompt's embedded shell command, not only in a
host-side preflight, because a separate preflight leaves a race before Codex
receives the issue list. This is a small customization of the generated prompt,
not a Sandcastle option. A second pilot-only label may further reduce operator
mistakes, but the query should still require `Sandcastle` if the aim is to
exercise upstream discovery.

A pushed branch and draft PR are **not** part of any stock v0.12.0 GitHub Issues
template. Adding them is a separate prompt or host-side handoff step and requires
GitHub repository-content and pull-request permissions beyond init's documented
Issues read/write plus Metadata read token. The lowest-deviation first pass ends
with a local commit on the explicit branch and an open issue; a draft-PR endpoint
is valid only if the pilot deliberately chooses to test that custom extension.
[scaffolded token permissions](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L540-L543)

## Installation and initialization

The documented setup is repository-local:

```bash
npm install --save-dev @ai-hero/sandcastle
npx @ai-hero/sandcastle init
```

Init asks for an agent, Docker or Podman, an issue tracker, and one of five
templates: blank, simple loop, sequential reviewer, parallel planner, or parallel
planner with review. Each interactive choice has a flag for non-interactive
initialization. Selecting GitHub Issues installs `gh` in the generated image and
adds `GH_TOKEN` to `.sandcastle/.env.example`.
[quick start](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L19-L52),
[templates and init flags](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L750-L796),
[GitHub CLI image fragment](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L497-L503)

The blank template has no issue workflow: its prompt contains only placeholders.
The four nonblank templates consume the issue-tracker substitutions. Sandcastle's
core explicitly has no built-in opinion about task management; the GitHub
behavior lives in scaffolded TypeScript and Markdown that the repository is
expected to customize.
[blank prompt](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/blank/prompt.md),
[prompt philosophy](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L560-L577)

## Label creation and filtering

For GitHub Issues, init asks whether to create a `Sandcastle` label. If accepted,
it executes:

```text
gh label create "Sandcastle" --description "Issues for Sandcastle to work on" --color "F9A825"
```

Errors and stderr are intentionally swallowed, so successful init does not prove
that authentication worked or that the label now exists. If label creation is
declined, init does **not** leave the workflow safely disabled: it mechanically
removes ` --label Sandcastle` from every generated Markdown file, causing the
templates to query all open issues instead.
[label prompt and ignored creation failure](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/cli.ts#L396-L417),
[filter removal](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L817-L848)

The actual query filters only on open state and label. Despite prompt prose saying
the list is “filtered to issues ready for work,” the command does not query native
dependency or assignment state. It returns a maximum of 100 issues and no
assignee field. “Ready,” priority, and blocked status are inferred by the model
from the returned issue text.
[query definition](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L530-L537),
[selection instructions](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/prompt.md#L1-L27)

## List, select, view, and claim behavior

- **List:** every prompt expansion runs the generated `gh issue list` inside the
  sandbox. In a multi-iteration `run()`, this gives each iteration a fresh issue
  list. A non-zero list command fails the run before the agent is invoked.
  [dynamic prompt expansion](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L579-L595)
- **Select:** simple loop and sequential reviewer give the entire list to the
  agent and tell it to choose the highest-priority unblocked issue. There is no
  deterministic ordering or code-level selection. Parallel planner asks a model
  to infer a dependency graph and returns a schema-validated list of candidate
  issue ids and deterministic branch names.
  [simple-loop selection](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/prompt.md#L13-L27),
  [planner prompt](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/parallel-planner/plan-prompt.md)
- **View:** the tracker substitution exposes `gh issue view <ID>`. The parallel
  implementer prompt tells the agent to use it, while simple loop and sequential
  reviewer normally rely on the body and comments already embedded in the list.
  There is no orchestrator-level fetch or validation of the selected issue.
  [view substitution](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L534-L537),
  [parallel implementer prompt](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/parallel-planner/implement-prompt.md#L1-L10)
- **Claim:** none of the generated commands assign the issue, remove its label,
  create a lock, or otherwise claim it. Concurrent workers can choose the same
  issue. The templates also do not use GitHub's native blocking relationships.

## Template iteration and branch behavior

| Template | Iteration boundary | Branch behavior | Issue lifecycle |
| --- | --- | --- | --- |
| Blank | One `run()` iteration by default | Docker's bind-mount default is `head` unless customized | None |
| Simple loop | One agent invocation per issue, up to 3 in one `run()`; the completion signal may stop early | Explicit `merge-to-head`; all issue commits share the temporary branch and merge into host HEAD after the run | Agent chooses, commits, and closes one issue per prompt iteration |
| Sequential reviewer | Up to 10 outer cycles; one implementer invocation and then one reviewer invocation per cycle | A timestamped explicit local branch per cycle, shared by implementer and reviewer; no merge step | Implementer prompt selects and closes before the reviewer runs |
| Parallel planner | Up to 10 plan/execute/merge rounds; planner gets 1 invocation; each fixed-issue implementer allows up to 100 invocations; merger gets 1 | Deterministic `sandcastle/issue-<id>` local branches; a merger agent runs in Docker's default `head` checkout and executes local merges | Implementers do not close; merger prompt closes branches' issues after it attempts merges |
| Parallel planner with review | Same as parallel planner, plus one reviewer invocation per issue pipeline | Same as parallel planner; implementer and reviewer share each explicit branch | Same close-at-merge prompt |

[simple-loop implementation](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/main.mts),
[sequential-reviewer implementation](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/sequential-reviewer/main.mts#L31-L119),
[parallel-planner implementation](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/parallel-planner/main.mts#L37-L204),
[branch strategies](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L550-L558)

`maxIterations` is a cap on agent invocations, not a transaction boundary. The
engine detects the configured completion signal and stops a loop early, but the
prompt must tell the model when to emit it. In the parallel implementer, repeated
iterations retain the same fixed issue prompt and branch; they do not select 100
different issues.
[iteration and completion options](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L186-L188),
[completion convention](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L643-L664)

## Commit, push, PR, comment, and close behavior

Sandcastle observes commits produced during a run and applies the configured
local branch strategy. The templates instruct agents to create commits, and the
parallel orchestrators use `result.commits.length` to decide whether to review or
merge a branch. Sandcastle does not itself create the commits.
[run result fields](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L106-L122),
[parallel commit gate](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/parallel-planner/main.mts#L143-L173)

No generated template runs `git push`, `gh pr create`, or any equivalent. All
branches and merges are local. There is no stock draft PR, review request, merge
through GitHub, or remote branch cleanup behavior.

Closing is also prompt-driven. The tracker substitution is `gh issue close <ID>
--comment "Completed by Sandcastle"`. Simple loop and sequential reviewer tell
the implementer to run it after tests and a commit. Parallel templates tell the
merger agent to run it after merging. Sandcastle does not verify that the issue
was closed, couple closure atomically to the commit/merge, or enforce the
explanatory comment promised by the prose. On blockage, the simple prompt tells
the agent to leave a comment and move on but supplies no dedicated comment
command or structured blocker state.
[close command](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L534-L543),
[simple close/block instructions](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/prompt.md#L28-L53),
[parallel merge/close prompt](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/parallel-planner/merge-prompt.md)

## Logs and recovery

`run()` defaults to timestamped file logging under `.sandcastle/logs/`; callers
can choose stdout, include raw provider lines, and receive typed stream events.
Results expose iterations, stdout, commits, branch, completion signal, log path,
and (when available) session identifiers. These records describe the agent run,
not a durable GitHub queue state machine.
[logging options](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L216-L258),
[result fields](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L401-L417)

Codex session capture is enabled by default: after an iteration, Sandcastle copies
the rollout JSONL from the sandbox to the host's `~/.codex/sessions/...` tree.
`resumeSession` or `result.resume()` can continue that conversation in a new
sandbox, but resume is a single agent iteration and requires the captured host
file. This does not restore label selection, issue claim, outer-template loop
position, or a killed Sandcastle process.
[session capture and resume](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L885-L927)

Worktree cleanup preserves a dirty worktree path for inspection; isolated
provider sync failures can preserve patches and recovery commands. Those are git
artifact recovery aids, not automatic retry of GitHub mutations.
[worktree close result](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L413-L417),
[sync-out recovery implementation](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/syncOut.ts)

## Runtime controls versus prompt guidance

| Concern | Implemented in code | Left to the agent prompt or absent |
| --- | --- | --- |
| Candidate retrieval | Executes the embedded shell command; aborts on non-zero exit | Whether the resulting candidates are semantically ready |
| Label gate | Present in the generated query when label creation is accepted | Label creation errors are ignored; no exact-count assertion |
| Selection | Planner JSON is schema-validated in parallel templates | Priority and issue choice in simple/sequential templates |
| Claim/concurrency | Separate branches in parallel templates | No issue assignment, lease, atomic claim, or duplicate-work prevention |
| Blocking | Planner output shape is validated | Dependency inference is model reasoning over text, not GitHub relationship state |
| Iterations | Caps, completion-signal detection, and outer loops | “One issue per iteration” and when to emit completion |
| Git state | Worktree/branch creation, local merge strategy, commit discovery | Creating commits and deciding their contents/messages |
| GitHub mutation | Executes whatever `gh` commands the agent chooses to invoke | Commenting and closing; no verification or transaction |
| Remote handoff | None | No push or PR workflow exists in stock templates |
| Recovery | Logs, dirty worktree preservation, captured Codex conversation | No durable queue ledger or restoration of issue workflow position |

The important operating-model consequence is that the label query is real
mechanism, while almost everything after it is a suggested policy. Treating the
stock prompt as if it supplied queue claims, dependency enforcement, or a
review-gated PR workflow would overstate v0.12.0.

## Comparison with the existing operating-model note

Compared with
[`docs/research/sandcastle-codex-operating-model.md`](./sandcastle-codex-operating-model.md):

### Accurate

- It correctly identifies the generated label-filtered `gh issue list`, issue
  close command, lack of durable claim/lease, prompt-only “not blocked” decision,
  lack of a draft-PR step, and absence of a durable process state machine.
- Its recommendation to avoid `head` and stock `merge-to-head` for an isolated
  no-merge pilot is consistent with the branch-strategy implementation.
- Its account of file logs, captured Codex sessions, and the limits of session
  resume is consistent with upstream.

### Missing or misleading

- Its final recommendation says to use a blank template with “a disposable issue
  selected explicitly.” That is safe as a custom wrapper but does not preserve or
  evaluate Sandcastle's intended label-discovery workflow. A label-preserving,
  exactly-one fail-closed query is the closer pilot.
- “Optionally creates a `Sandcastle` label” omits two consequential details:
  label-creation failures are swallowed, and opting out strips the filter and
  exposes every open issue.
- It does not state the list's 100-issue cap, inclusion of full bodies and comment
  bodies, absence of assignees/dependency fields, or lack of an exact-candidate
  guard.
- Saying the stock issue templates “choose an issue ... implement and commit,
  then close it” compresses materially different workflows. Blank has no issue
  flow; sequential closes before review; parallel implementers do not close and
  instead rely on a later merger-agent prompt.
- It mentions `gh issue view` as scaffolded behavior without distinguishing that
  simple/sequential normally consume the embedded list payload, while only the
  parallel implement prompt explicitly directs a view.
- It says upstream lacks a draft-PR step, but does not make explicit that there is
  no push at all and that the documented token permissions cannot support a
  pushed branch/PR without expansion.
- It does not clearly separate local branch/merge mechanics and commit detection,
  which Sandcastle enforces, from commit, close, comment, selection, and blocking
  behavior, which the agent follows only through prompt instructions.
