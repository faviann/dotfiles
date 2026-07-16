# Sandcastle's intended Codex operating model

Researched 2026-07-16 against Sandcastle's upstream repository, release,
documentation, templates, and implementation. All source-code links are pinned to
commit `e99f832f26dc9d245c019a9ddd19fa5dee792427`.

## Conclusion

Sandcastle is intended to be a **repo-local TypeScript orchestration library and
scaffold**, launched as a foreground host process, with the coding agent running
inside a selected sandbox. For the ordinary local Codex path, the repository owns
the `.sandcastle/` workflow, prompt, container recipe, ignored secrets, logs, and
worktrees; the workstation supplies Git, npm/Node tooling, Docker or Podman, the
locally built image, and the host-side Codex session archive.

The upstream-supported path for this map is therefore: install Sandcastle in the
target repository, scaffold a Codex + Docker/Podman workflow, use an explicit
`branch` strategy for the disposable pilot, inject separate OpenAI and GitHub
credentials through `.sandcastle/.env`, and invoke the generated TypeScript entry
point. This supports a contained issue-to-branch experiment with inspectable logs
and resumable *agent conversations*. It does **not** by itself provide a durable
daemon, detached job runner, automatic restart, remote queue, notification system,
or process-level continuation after an SSH or terminal disconnect.

## Release state

- The latest upstream GitHub release is [v0.12.0, published 2026-06-29](https://github.com/mattpocock/sandcastle/releases/tag/v0.12.0).
- The release tag, the `main` branch inspected on 2026-07-16, and the package's
  declared version all resolve to
  [`e99f832f26dc9d245c019a9ddd19fa5dee792427`](https://github.com/mattpocock/sandcastle/tree/e99f832f26dc9d245c019a9ddd19fa5dee792427);
  [`package.json` declares `0.12.0`](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/package.json#L1-L5).
- This is a fast-moving pre-1.0 project: the changelog shows Codex support first
  arriving in 0.2.0 and substantial changes to session capture, approval handling,
  GitHub credentials, logging, and recovery through 0.12.0. The pilot should pin
  `@ai-hero/sandcastle` in a lockfile rather than rely on an unbounded `npx` fetch.
  [Codex provider introduction](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/CHANGELOG.md#L465-L479)

## Intended lifecycle

### Install and scaffold

Upstream's primary installation is per repository:

```bash
npm install --save-dev @ai-hero/sandcastle
npx @ai-hero/sandcastle init
```

`init` interactively chooses an agent, sandbox provider, issue tracker, and
template, then writes `.sandcastle/`; every prompt also has a flag for scripted
initialization. The supported local sandbox choices exposed by `init` are Docker
and Podman. The generated Codex image starts from `node:22-bookworm`, installs
Git/curl/jq, installs `@openai/codex` globally, creates an unprivileged `agent`
user aligned to the host UID/GID, and sleeps until Sandcastle executes in it.
[Quick start](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L19-L52),
[init behavior and flags](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L750-L796),
[Codex Dockerfile template](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L275-L306)

The generated entry point imports `@ai-hero/sandcastle` and is run with
`npx tsx .sandcastle/main.mts` (or `main.ts` when the host package is ESM).
Upstream's next steps explicitly recommend adding that command as a repository
`package.json` script. Rich templates also assume `node_modules`, run
`npm install` inside the sandbox, and may add a host schema dependency. Thus
upstream does not offer a workstation-global installation model that leaves a
non-Node repository untouched: such a wrapper could be built with the public API,
but it would be a local design rather than the documented scaffold.
[Generated next steps](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L643-L690),
[simple-loop runtime assumptions](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/main.mts#L1-L50)

### Invoke Codex

The generated main file calls `run({ agent: codex("gpt-5.4"), sandbox: ...,
promptFile: ... })`. For AFK execution the provider runs `codex exec --json`,
selects the configured model and optional reasoning effort, sends the prompt on
stdin, and parses Codex's JSONL events. By default it also passes
`--dangerously-bypass-approvals-and-sandbox`: Sandcastle treats its outer sandbox
as the safety boundary. An optional `approvalsReviewer: "auto_review"` instead
uses Codex's on-request approvals with `danger-full-access`, so the reviewer—not
Codex's filesystem sandbox—becomes the per-action boundary.
[Codex provider command construction](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/AgentProvider.ts#L749-L824)

`interactive()` is a separate, attached TUI path. It invokes `codex --model ...`
inside the selected sandbox and is useful for a human-guided session, but it is
not the AFK workflow or a persistence mechanism.
[Sandbox and interactive entry points](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L66-L100)

### Sandbox and git effects

For Docker and Podman, Sandcastle bind-mounts a host checkout or worktree into the
container. This isolates the agent process and toolchain, but it is intentionally
not a copy-on-write filesystem boundary: the agent writes the mounted host files
directly and receives any injected credentials and configured network access.
[Bind-mount behavior](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L548-L558)

The branch strategy determines the host-side blast radius:

- `head` is the bind-mount default and writes directly into the current host
  checkout. It is unsuitable for the map's isolated disposable pilot.
- `merge-to-head` creates a temporary worktree/branch and automatically merges it
  into host `HEAD` when done. The stock `simple-loop` template chooses this, so it
  conflicts with the pilot's “no merge” constraint.
- `branch` creates or reuses a named worktree under `.sandcastle/worktrees/` and
  leaves commits on that explicit branch. This is the upstream-aligned pilot
  choice; it avoids automatic merge while keeping the run separate from the main
  checkout.

[Branch strategies](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L548-L558),
[stock simple-loop strategy](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/main.mts#L24-L39)

### Authenticate

The Codex scaffold's `.env.example` asks for `OPENAI_KEY`; selecting GitHub Issues
adds `GH_TOKEN`. The generated Dockerfile does not copy or mount the workstation's
`~/.codex` authentication state, and upstream does not document a Codex
subscription/OAuth flow analogous to its explicit Claude setup-token flow.
Therefore the evidence supports a sandbox-specific API credential, not an
assumption that an existing host Codex login will automatically work in the
container. The exact `OPENAI_KEY` behavior should be validated in the pilot because
the scaffold is the only upstream authentication guidance for Codex.
[Codex environment scaffold](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L433-L442),
[Codex image contents](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L275-L306)

`.sandcastle/.env` is ignored by the generated nested `.gitignore`. Sandcastle
reads only keys declared in that file, preferring its non-empty value and falling
back to the same key in the host process environment; a repository-root `.env` is
not consulted. The resulting values are injected into the agent sandbox. This
keeps secrets out of Git when the scaffold is retained, but does not put them in a
workstation secret store or narrow what the agent can read.
[Generated ignore rules](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L7-L10),
[environment resolution](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/EnvResolver.ts#L49-L73)

### Observe and recover

`run()` defaults to timestamped file logging under `.sandcastle/logs/`. A caller
can instead log to stdout, enable raw JSONL lines with `verbose`, or forward typed
text/tool/raw stream events through `onAgentStreamEvent`. Results expose
iterations, commits, branch, completion signal, session ID/file path, and usage;
Codex parsing recognizes session start, assistant messages, command starts, errors,
and token usage.
[Logging and stream options](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L216-L247),
[Codex event parser](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/AgentProvider.ts#L671-L747)

On an isolated-provider sync-out failure, Sandcastle preserves patches, diffs, and
untracked files under `.sandcastle/patches/<timestamp>/` and prints recovery
commands. Worktree-based failures can preserve the worktree and expose its path.
These are inspectable recovery aids, not automatic retry or job continuation.
[Two-phase sync-out recovery](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/syncOut.ts#L1-L10),
[recovery commands](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/RecoveryMessage.ts#L12-L82)

### Resume

After a successful resumable Codex iteration, Sandcastle copies the rollout JSONL
from `/home/agent/.codex/sessions/...` to the workstation's
`~/.codex/sessions/YYYY/MM/DD/...`, rewriting working-directory fields from the
sandbox path to the host repository path. Session capture is on by default.
`RunResult.resume(prompt)` or a later `run({ resumeSession: id })` copies that
file back into a new sandbox and invokes `codex exec resume <id>`; a resume is
exactly one iteration. `fork()` similarly uses `codex exec fork` but isolates only
the conversation record, not the git workspace.
[Capture and transfer implementation](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/AgentProvider.ts#L441-L488),
[documented capture/resume contract](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L885-L931),
[one-iteration resume decision](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/docs/adr/0011-resume-is-one-iteration.md#L1-L18)

This does not make the **Sandcastle process** resumable. It runs in the foreground;
on `SIGINT` or `SIGTERM`, upstream synchronously tears down registered sandboxes
and exits with status 1. There is no persisted run-state machine or reattach
command. In particular, session capture happens after an iteration has yielded a
session ID and reached the capture path, so an arbitrary disconnect cannot be
treated as a guaranteed checkpoint. Terminal/SSH survival requires an external
supervisor such as a persistent terminal or service manager, and restart semantics
would still need to be designed around branches, logs, and captured sessions.
[Shutdown behavior](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/shutdownRegistry.ts#L1-L53)

### Connect to GitHub Issues

Selecting `github-issues` during init:

1. installs the GitHub CLI in the image;
2. scaffolds `GH_TOKEN` with documented fine-grained permissions of Issues
   read/write and Metadata read;
3. optionally creates a `Sandcastle` label;
4. expands the workflow prompt by running `gh issue list --state open --label
   Sandcastle ...` inside the sandbox; and
5. gives the agent `gh issue view` and `gh issue close ... --comment` commands.

[GitHub tracker registry](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L497-L543)

The stock issue templates are opinionated autonomous backlog workers: they choose
an issue from the label-filtered list, implement and commit, then close it. They do
not implement a durable claim/lease, GitHub sub-issue dependency query, explicit
authorization gate, draft-PR handoff, human review gate, or failure-state machine.
“Not blocked” is prompt guidance interpreted by the agent, while the actual list
command fetches all open `Sandcastle`-labelled issues. For a harmless disposable
pilot, use the blank template or narrow the generated list/view/close logic; do not
run the stock loop against a production label and assume ticket-level safeguards.
[Stock issue workflow](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/templates/simple-loop/prompt.md#L1-L53)

## State ownership

| State | Intended location and ownership |
| --- | --- |
| Workflow code, prompts, Dockerfile/Containerfile, `.env.example`, nested `.gitignore` | Repo-local, normally committed under `.sandcastle/` |
| Sandcastle dependency and lock | Repo-local `package.json` and lockfile in the documented installation |
| Secrets | Repo-local but ignored `.sandcastle/.env`, optionally sourced from matching host process variables |
| Run logs | Repo-local but ignored `.sandcastle/logs/` |
| Worktrees and explicit run branches | Worktrees under ignored `.sandcastle/worktrees/`; branches and git metadata live in the repository |
| Failed isolated-sync artifacts | Repo-local `.sandcastle/patches/` when recovery is needed; notably the generated ignore file lists `.env`, `logs/`, and `worktrees/`, but not `patches/` |
| Codex conversation rollouts | Workstation-local `~/.codex/sessions/...` after capture; copied into a sandbox only for resume/fork |
| Docker/Podman engine and built `sandcastle:<repo>` image | Workstation-local prerequisite/cache; image name defaults from the repository directory |
| Live container and orchestrator process | Ephemeral workstation runtime; cleaned up on normal completion or process signal |
| GitHub issues, comments, labels | Remote repository state accessed directly from the sandbox with `GH_TOKEN` |

The important boundary is that “repo-local” does not necessarily mean “inside the
sandbox only”: Docker/Podman runs are bind-mounted, so repo-local worktrees are
host files visible to the container.

## Map assumptions checked against upstream

| Map assumption or preference | Upstream assessment |
| --- | --- |
| Codex-only pilot | **Supported.** Codex is a first-class agent factory and init choice. |
| Repo-scoped workflows | **Supported and preferred.** `.sandcastle/` and the package dependency live in each target repo. |
| Avoid turning dotfiles into a Node project solely for Sandcastle | **Not supported by the documented scaffold.** The normal install, script, templates, dependency copying, and hooks are Node/npm-shaped. A workstation wrapper would be custom integration work. |
| Isolated, reversible pilot | **Supported only with deliberate settings.** Use Docker/Podman plus an explicit disposable `branch`; the bind-mount default `head` writes to the live checkout and stock `merge-to-head` merges automatically. |
| Temporary branch | **Supported.** Explicit named branches/worktrees are a core strategy. |
| Draft PR allowed, no merge | **Partly supported.** No-merge is achieved with `branch`; upstream does not provide a draft-PR step, and stock issue templates close issues rather than open PRs. |
| Safe credential isolation | **Partial.** Ignored `.sandcastle/.env` and a dedicated fine-grained `GH_TOKEN` are supported, but credentials are injected into the agent container and Codex host OAuth state is not scaffolded. |
| Inspectable failure recovery | **Supported in part.** File logs, result metadata, preserved worktrees/patches, and host-captured Codex sessions exist; automatic retry/restart and a durable run ledger do not. |
| Survive terminal closure, SSH disconnection, and client offline | **Not supplied by Sandcastle.** The foreground process exits and tears down on signals. A persistent-terminal/service wrapper is external to upstream, and client-offline behavior depends on where that wrapper runs. |
| Host reboot recovery unnecessary | **Consistent with upstream.** No native reboot recovery exists. |
| GitHub Issues as queue | **Supported at a basic label-filtered backlog level.** The templates list/view/close with `gh`; production selection, claim, authorization, dependency, review, and recovery policy remain custom workflow decisions. |
| Easy removal | **Mostly supported.** Delete the repo-local dependency/config, remove the local image, and clean branches/worktrees. Captured `~/.codex/sessions` and any GitHub labels/comments/issues are separate residual state. |
| Reproducible versioning | **Partial.** The npm dependency can be locked, but the generated Codex Dockerfile installs unpinned `@openai/codex` and uses a moving base-image tag, so the default image is not fully reproducible. |
| Shared convention across repositories | **Not built in.** The public `cwd` option can target another repo, but artifacts remain anchored under that repo and upstream provides no synchronization/distribution mechanism for workflow config. [cwd contract](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/run.ts#L331-L346) |

## Consequences for the pilot decision

The least-assumptive upstream-aligned experiment is a **repo-local, pinned,
blank-template Codex workflow** using Docker or rootless Podman, a uniquely named
`branch` strategy, one iteration, a disposable issue selected explicitly, and
dedicated least-privilege API tokens. It should retain file logging and Codex
session capture, and it should verify the scaffolded Codex credential variable
before any broader design depends on it.

That experiment can answer whether Sandcastle's orchestration, worktree, logging,
and session transfer feel worthwhile. It cannot, without an additional wrapper,
validate the map's disconnect-survival requirement. Choosing the wrapper and
choosing whether dotfiles should accept repo-local Node machinery are separate
decisions exposed—not answered—by upstream.
