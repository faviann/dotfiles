# Sandcastle upstream's recommended working model

Researched 2026-07-16 against the latest upstream release,
[Sandcastle v0.12.0 (published 2026-06-29)](https://github.com/mattpocock/sandcastle/releases/tag/v0.12.0),
at commit
[`e99f832f26dc9d245c019a9ddd19fa5dee792427`](https://github.com/mattpocock/sandcastle/tree/e99f832f26dc9d245c019a9ddd19fa5dee792427).
All source links below are pinned to that release commit.

## Short answer

Upstream recommends treating Sandcastle as a **repository-local TypeScript
orchestrator**, not as a workstation-wide task daemon. Install it in the target
repository, run `sandcastle init`, customize the generated `.sandcastle/` code
and prompts, then start the foreground workflow with `npm run sandcastle` (which
runs the generated TypeScript entry point).

There are two different layers:

- The core library deliberately imposes no task-management policy. A custom
  workflow can pass an explicit issue number through `promptArgs` or an inline
  prompt.
- The stock GitHub Issues templates are autonomous backlog workers. Their
  generated query scans open issues carrying the `Sandcastle` label, and the
  prompt tells the agent or planner to choose work from that list. An explicit
  issue URL or number is **not** the stock simple-loop selection path.

That means the dotfiles pilot's label-scanned selection was faithful to the
upstream GitHub template. Replacing it with an explicit issue argument would be
a reasonable simplification, but it would be our custom workflow rather than
upstream's generated happy path.

## Documented happy path

### 1. Install and scaffold in each repository

The quick start installs Sandcastle as a development dependency and scaffolds a
`.sandcastle/` directory:

```bash
npm install --save-dev @ai-hero/sandcastle
npx @ai-hero/sandcastle init
```

`init` asks for the coding agent, Docker or Podman, issue tracker, and workflow
template. It can scaffold a blank workflow, simple issue loop, sequential
implementation/review loop, or either of two parallel planning workflows. The
generated files are intended to be read and customized; upstream explicitly
describes `run()` as executing the prompt the repository supplies rather than
imposing its own workflow.
[Quick start](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L19-L63),
[templates and init](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L750-L796),
[prompt philosophy](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L560-L577)

The generated next steps say to add
`"sandcastle": "npx tsx .sandcastle/main.mts"` (or `main.ts`) to the
repository's `package.json`, then run `npm run sandcastle`.
[Generated next steps](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L643-L690)

### 2. Supply credentials to the sandbox

For Codex, v0.12.0 generates a container image that installs the Codex CLI and
an `.env.example` containing `OPENAI_KEY=`. Selecting GitHub Issues also adds
`GH_TOKEN=` and documents a fine-grained token with Issues read/write and
Metadata read permissions.
[Codex scaffold](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L275-L305),
[Codex environment placeholder](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L433-L441),
[GitHub token placeholder](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L530-L543)

The release does **not** scaffold host Codex subscription authentication. The
public Docker/Podman configuration supports arbitrary mounts, so a repository
can mount or stage Codex login state, but that remains custom configuration
rather than the documented Codex init path.
[Mount configuration](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L135-L149),
[`codex()` options](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/AgentProvider.ts#L749-L780)

### 3. Start a foreground run

The generated command runs the repository's TypeScript program in the
foreground. For a one-shot task, upstream says to use `run()`, which owns sandbox
creation and cleanup; `createSandbox()` is for several agents or rounds sharing
one sandbox. Logging defaults to a timestamped file under `.sandcastle/logs/`.
[One-shot lifecycle](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L261-L265),
[logging](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L216-L247)

For Codex AFK runs, Sandcastle invokes `codex exec --json`. Unless an automatic
approvals reviewer is configured, it passes
`--dangerously-bypass-approvals-and-sandbox`; the outer Docker or Podman
container is therefore the intended safety boundary.
[Codex command construction](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/AgentProvider.ts#L782-L813)

Sandcastle captures a completed Codex session back to the host and can resume a
conversation in a new sandbox, but that is agent-session continuation, not a
durable background-job mechanism. Upstream's launch remains a foreground
process; using tmux for disconnect survival is an external operating choice.
[Session capture and resume](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L885-L927)

### 4. Let the selected template choose and perform work

When GitHub Issues and label creation are selected, the scaffold's task query is:

```bash
gh issue list --state open --label Sandcastle --limit 100 \
  --json number,title,body,labels,comments ...
```

The simple-loop prompt calls that query at the start of each iteration, treats
the returned list as the sole backlog, asks the agent to choose the
highest-priority unblocked issue, and tells it to explore, plan, implement,
verify, make one commit, and close the issue. The generated loop defaults to
three agent invocations, one issue per invocation; setting `maxIterations: 1`
is its documented single-shot mode.
[GitHub tracker commands](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L530-L543),
[simple-loop prompt](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/prompt.md#L1-L53),
[simple-loop runtime](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/main.mts#L20-L33)

Upstream does not call `gh label view`. During `init` it offers to run the valid
`gh label create "Sandcastle" ...` command, and at runtime it uses the valid
`gh issue list --label Sandcastle` query. If label creation is declined, the
scaffolder removes the label filter from its Markdown prompts, so the stock
templates see **all** open issues rather than switching to explicit issue
selection.
[Label prompt and creation](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/cli.ts#L396-L417),
[filter removal](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L817-L848)

The list command filters by open state and label only. The generated workflow
does not atomically claim an issue, filter by assignee, or query GitHub's native
blocking relationships. “Highest priority” and “not blocked” are prompt-level
judgments made by the agent. Multiple independently started workers can
therefore select the same issue.

Core Sandcastle also supports explicit selection: its public API documents
`promptArgs: { ISSUE_NUMBER: "42" }`, and the prompt system substitutes such
arguments into a repository-owned prompt file. That is a supported customization,
not the generated GitHub simple loop.
[Explicit prompt arguments](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L175-L190),
[prompt substitution](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L597-L607)

### 5. Keep git effects local unless the workflow adds a remote handoff

Branch behavior is configured per sandbox:

- `head` writes directly into the current host checkout and is the Docker/Podman
  default;
- `merge-to-head` uses a temporary worktree and locally merges its result into
  the current host `HEAD`;
- `branch` leaves commits on a named local worktree branch.

The stock simple loop explicitly chooses `merge-to-head`. Its prompt tells the
agent to create a commit and close the issue. No stock template performs
`git push` or `gh pr create`, so a pushed branch, draft PR, human review gate, or
GitHub merge is repository-specific workflow code rather than the default
handoff.
[Branch strategies](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L548-L558),
[simple-loop branch choice](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/main.mts#L24-L39),
[commit and close instructions](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/prompt.md#L28-L47)

## Direct comparison with the dotfiles pilot

| Concern | Upstream generated GitHub simple loop | Dotfiles pilot implication |
| --- | --- | --- |
| Work selection | Scan open `Sandcastle`-labelled issues; agent chooses from the list | The pilot's label scan exercised the stock selection model. An explicit issue would be a custom simplification. |
| Run size | Three iterations by default; `1` is documented single-shot mode | Restricting the pilot to one issue/iteration was an upstream-supported setting. |
| Git endpoint | Temporary branch merged locally into host `HEAD` | Leaving one local branch unmerged deliberately used upstream's `branch` strategy instead of the simple-loop default. |
| Issue endpoint | Agent commits, then closes with a completion comment | Any review-before-close rule is a prompt customization. |
| Remote endpoint | No push or PR | A draft-PR handoff would be an added workflow and need broader GitHub permissions. |
| Codex auth | Scaffolded environment credential | The pilot's host-subscription staging/mount was custom configuration supported by generic mounts, not the documented init path. |
| Disconnect survival | Foreground process and file logs | tmux was an external launcher choice, not Sandcastle setup required by upstream. |

## Bottom line

Upstream's ordinary experience is simpler than the proof harness: scaffold once,
put credentials in `.sandcastle/.env`, label work `Sandcastle`, and run the
repository script. The complexity in the pilot came from making that loose,
prompt-driven loop fail closed around exactly one disposable issue, preserving a
reviewable local branch, reusing Codex subscription auth, proving disconnect
survival, and verifying cleanup. Those are local safety and operability
requirements; they are not all part of Sandcastle's stock happy path.
