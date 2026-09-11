# dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io) + Bitwarden CLI.

See [BOOTSTRAP.md](BOOTSTRAP.md) for new machine setup.

## Repository-only files

[.chezmoiignore](.chezmoiignore) excludes repository documentation, tests,
scripts, `flake.nix`, `flake.lock`, and `home/` from chezmoi's home-directory
targets. Match target paths, not encoded source names (for example,
`.config/fish`, not `dot_config/fish`). Excluding an entire subtree requires
both its directory and contents patterns, such as `docs/` and `docs/**`.

Git and chezmoi exclusions are independent: `.chezmoiignore` does not prevent
publication, and Git ignore rules do not prevent chezmoi applying a source path.
Keep private or machine-local notes outside the canonical source checkout;
[workstation maintenance](#workstation-maintenance) rejects local content,
including ignored files. After changing the target inventory, inspect it before
applying:

```bash
chezmoi -S "$PWD" ignored --tree
chezmoi -S "$PWD" managed --path-style=source-relative --tree
```

## Repository validation

Behavioral tests use [Bats](https://bats-core.readthedocs.io/). Discover suites
and cases, then run one case or suite in the Nix development environment:

```bash
rg '^@test ' tests
nix develop -c bats --filter '^test_exact_case_name$' tests
nix develop -c bats tests/workstation-update.bats
```

Run focused shell analysis after changing Bash or shell templates:

```bash
nix run .#shellcheck
```

Use the complete flake validation as the sole full closeout gate:

```bash
nix flake check
```

It includes ShellCheck and every Bats suite in the declared Nix environment,
so a standalone full behavioral run immediately beforehand is redundant.

## Workstation Home Manager

The `workstation` Home Manager flake installs user tooling for the Debian LXC
workstation: the .NET 10 LTS SDK, Node.js/npm, `uv`, `gh`, `jq`, `ripgrep`,
`fd`, `fzf`, Hermes, and Moraine. Hermes is installed from
`github:NousResearch/hermes-agent` as a normal non-NixOS package; provider
credentials and runtime configuration stay in `~/.hermes`.

The .NET policy floats within major 10 while each published workstation
generation remains reproducible. A dedicated `dotnet-nixpkgs` flake input
isolates the SDK from the workstation's other Nix packages. The daily and
manually dispatchable `Update .NET 10 SDK` GitHub workflow invokes
`scripts/update-dotnet-sdk`, which advances only that input, rejects a major
change or downgrade, executes the SDK, builds the real Home Manager activation
package, and runs `nix flake check`. A validated version change is published
and merged through one automation PR; a failure leaves `main` on its last
known-good SDK.

Dotfiles and the complete AoE agent toolchain are maintained through one
operator-facing command:

```bash
workstation-update
```

The managed unit contains:

- the Bun runtime the harnesses execute under
- Agent of Empires (`aoe`)
- the standalone Codex CLI (`@openai/codex`)
- Claude Code (`@anthropic-ai/claude-code`)
- Pi (`@earendil-works/pi-coding-agent`)
- OpenCode (`opencode-ai`)
- Oh My Pi (`@oh-my-pi/pi-coding-agent`)
- the `codex-acp` adapter (`@agentclientprotocol/codex-acp`)
- the `claude-agent-acp` adapter
  (`@agentclientprotocol/claude-agent-acp`)
- the `pi-acp` adapter

[Bun's upstream installer](https://bun.sh/install) supplies its latest runtime,
selects a CPU-compatible build (including baseline x64), and replaces the binary
by renaming it into `~/.local/bin`. npm owns package versions, dependency
resolution, integrity checks, and installation; `aoe update --yes` owns AoE's
update. There is no repository-owned release discovery or version cache.

Before replacing executables, an npm dry run with
[`--engine-strict`](https://docs.npmjs.com/cli/v11/using-npm/config/#engine-strict)
checks package compatibility with Home Manager's Node runtime. This handles npm's
supported engine ranges, including transitive dependencies. npm does not enforce
Bun engines: the updater installs the latest Bun and runs Bun and the Bun-using
harnesses before restarting services. If an upstream package needs a newer Node,
update the nixpkgs input; installation failures leave running sessions alone.

`codex-acp` also contains its own compatible Codex runtime. npm resolves that
adapter's dependencies; updating `@openai/codex` alone does not update the runtime
used by structured Codex sessions.

Pi and Oh My Pi intentionally coexist while OMP is evaluated as a separate
harness. The `pi` command continues to use `~/.pi`; the distinct `omp` command
uses its own default `~/.omp` state. OMP does not replace Pi or the existing
`pi-acp` adapter.

Home Manager provides Node/npm and writes the npm prefix as
`/home/faviann/.local`; all npm-managed commands resolve from `~/.local/bin`.

Apply it through the Ansible-installed `workstation-setup` command, or build it
directly while developing dotfiles:

```bash
home-manager build --flake .#workstation
```

## Workstation Moraine

The workstation profile source-builds Moraine at commit `91cd7a13ba29`, the
mainline merge of upstream PR #658 after v0.7.3, with the upstream Rust 1.96.0
toolchain and locked Cargo closure. It installs matching CLI, ingest,
monitor-compatibility alias, and MCP executables, while reusing the unchanged,
hash-pinned v0.7.3 monitor assets. There is intentionally no separate monitor
unit; the unified MCP/backend executable owns the monitor HTTP listener, native
loopback `/mcp` endpoint, and private MCP socket. The source still reports
version 0.7.3, so use the commit-bearing `moraine --version` output, not the
semantic version alone, to identify this build.

The package temporarily gives Moraine's interactive query profile 8 GiB, its
ClickHouse user a 16 GiB aggregate limit, and managed ClickHouse a 48 GiB
process limit on this 64 GiB host. This keeps session discovery usable while
upstream issue #599's bounded summary query remains unresolved. Background
queries retain upstream's 256 MiB ceiling. Remove
`packages/moraine-managed-memory-headroom.patch` when a bounded upstream
discovery path is pinned. Managed ClickHouse refuses startup below 2 GiB of
detected memory; `moraine up` may restart it when managed resource settings
change.

Home Manager owns `~/.moraine/config.toml` as a read-only Nix-managed file.
Persistent ingestion state, ClickHouse data, logs, sockets, and process state
remain under `~/.moraine`. Do not use `moraine setup` or another config-writing
command to mutate the managed file; change this module and apply a new Home
Manager generation instead. The enabled sources backfill and watch active Codex
sessions recursively, archived sessions in Codex's flat archive directory, and
standard Claude Code project transcripts under `~/.claude/projects`. The
deployment-owned Claude source is named `claude-projects`, avoiding upstream
setup migrations that append unrelated default harnesses. Claude job timelines
under `~/.claude/jobs` are intentionally excluded. Moraine's default built-in
redaction runs before local storage.

The single `moraine.service` user unit is the operator surface for the local
stack. Upstream `moraine up` owns managed ClickHouse readiness, database
migrations, ingest, and unified-backend startup. The foreground unit monitors
aggregate Moraine health and restarts the complete stack on failure. Default
Moraine topology explicitly keeps the HTTP listener on `127.0.0.1:8080`, where
the pinned build serves `POST /mcp`, and its per-user MCP Unix socket at mode
0600; there is no non-loopback listener. Applying a Home Manager generation
restarts the service when the managed Moraine configuration changes, so
ingestion reloads newly declared sources.

For this pinned build, HTTP MCP requires an explicit loopback IP in
`backend.bind`: wildcards, non-loopback addresses, and `localhost` do not enable
`/mcp`, even with an `auth_token`. HTTP uses the default backend; named-backend
routing and `--project-only` retrieval remain stdio-only because HTTP has no
launch-directory context.

The workstation profile does not manage `~/.codex/config.toml` or register a
Codex MCP server. Moraine's local producer and query backend operate without a
Codex MCP registration; that integration can be added later if the workstation
needs Codex to query Moraine directly.

## Workstation Agent of Empires

Agent of Empires (`aoe`) is managed here as a user-level workstation tool, not in the Ansible repo.

- Install: `.chezmoiscripts/run_once_install-aoe.sh.tmpl` uses the upstream installer until there is a clean Nix package path.
- Bootstrap handoff: after chezmoi installs AoE and Home Manager provides
  Node/npm and loads the user units, Home Manager runs
  `update-agent-tools` when any managed command is missing. The existing
  `workstation-setup` handoff therefore installs the full toolchain without a
  separate package-discovery or Ansible step.
- SSH login: `dot_bash_profile.tmpl` loads the Nix and Home Manager environment
  and opens a plain shell. Maintenance, tmux, and AoE are explicit commands.
- Shell choice: the workstation is bash-based; `.chezmoiignore` excludes fish config on the host named `workstation`, not on LXC guests generally.
- Dashboard: `home/workstation.nix` declares the `aoe-serve.service`, `aoe-lan-proxy.service`, and `aoe-lan-proxy.socket` user units. The socket exposes `0.0.0.0:4001` and proxies to the localhost service.
- Reboot survival: Ansible enables lingering for the workstation user with `loginctl enable-linger <user>`.

AoE's `acp.allow_agent_install` host-package setting remains off. Dotfiles owns
package installation; the AoE dashboard does not.

### Workstation maintenance

Run `workstation-update` for routine maintenance. It validates the chezmoi
source as a clean, canonical `main` checkout, fetches `origin/main`, and delegates
the fast-forward to Git. It then previews, applies, and verifies chezmoi targets,
calls `workstation-setup`, and refreshes the agent tools. Every invocation runs
these reconciliation steps, including when the source commit is unchanged.
This makes failed maintenance retryable without an applied-commit cache.
`workstation-setup`, installed by Ansible, owns workstation configuration
freshness and decides whether the Home Manager build needs activation.

Git owns index, worktree, and ref updates through
[`merge --ff-only --no-autostash --no-overwrite-ignore`](https://git-scm.com/docs/git-merge).
Chezmoi owns target reconciliation and
[conflict prompts](https://www.chezmoi.io/reference/commands/apply/).
The wrapper forces neither source convergence nor target overwrites. Run it
with exclusive use of the source checkout; its lock serializes maintenance
commands, not arbitrary concurrent Git commands or editors.

`workstation-update` never rewrites `flake.lock`. .NET release discovery and
publication happen through the dedicated GitHub workflow; maintenance delivers
that validated commit through the same path as other workstation changes.
For maintainer recovery or an on-demand refresh, run
`scripts/update-dotnet-sdk` from a clean canonical checkout.

The command refuses unsafe source states such as local content, a non-canonical
origin, the wrong branch or upstream, and ahead or diverged history. It does
not reset or discard local work. If ACP sessions are running, an interactive
update reports only their count and asks once before changing agent-tool state
or running processes. Declining leaves the toolchain and running processes
alone. For unattended use, `workstation-update --yes` authorizes those
agent-session restarts; it does not authorize overwriting local dotfile changes
or bypass any source guard.

When applying Bitwarden-backed templates, the command reuses a valid
`BW_SESSION`. If the vault is locked during an interactive update, it prompts
once and shares the resulting session with preview, apply, and verification.
Unattended runs must export a valid session before invoking the updater.
Chezmoi lifecycle scripts run and must succeed during apply; post-apply
verification checks durable targets without rerunning those actions.

All installations, harness execution checks, and `aoe acp doctor` must succeed
before activation begins. The updater then restarts the AoE user service,
replaces the ACP workers captured before consent, and performs bounded service,
ACP diagnostic, and worker-health checks. Each captured session must have a new,
live, current worker, with none of its old workers still alive.

There is no automatic rollback. On failure, use the command's diagnostics,
`systemctl --user status aoe-serve.service`, and
`journalctl --user-unit aoe-serve.service` to correct the problem, then rerun
`workstation-update`. Installation failures happen before process restarts.
Success is reported only after activation checks pass; no separate status cache
needs repairing.

The lower-level `update-agent-tools` command remains available for targeted
recovery when a dotfiles/source or workstation-configuration failure prevents
`workstation-update` from reaching its agent-tool phase. Use it only to repair
that agent-tool state, then return to `workstation-update` for routine
maintenance. Home Manager also uses `update-agent-tools` during bootstrap when
managed commands are missing. This does not authorize disrupting existing ACP
workers: fresh workstations proceed unattended, while existing workers require
consent. If activation cannot prompt, run `update-agent-tools --yes` explicitly
to authorize the repair, then rerun `workstation-update`.

### Login and maintenance ownership

Login only loads the shell PATH, Nix environment, and Home Manager session
variables. It performs no network checks or updates, does not source `.bashrc`,
and does not launch tmux or AoE. Package managers resolve releases during
explicit maintenance, chezmoi tracks target state, and `workstation-setup`
checks configuration freshness. Only maintenance lock files are active under
`~/.local/state/workstation-update` and `~/.local/state/update-agent-tools`;
there is no freshness cache or workstation-side update scheduler.

An explicit maintenance run may reinstall current agent versions and restart
their services, so choose an appropriate maintenance window.

## Workstation herdr

[herdr](https://herdr.dev) is a terminal agent multiplexer, installed for
evaluation alongside AoE. It is not an AoE replacement: AoE serves conversations
over HTTP, while herdr is a TUI.

- Install: `.chezmoiscripts/run_once_install-herdr.sh.tmpl` uses the upstream
  installer until there is a clean Nix package path. herdr is packaged in
  nixpkgs, but not in the pinned nixpkgs revision.
- Updates: manual `herdr update`, outside `workstation-update` and from a
  terminal outside Herdr with the service stopped.
- Configuration: `~/.config/herdr/config.toml` is optional and app-owned.
- Supervision: Home Manager owns the foreground `herdr.service` under
  `default.target`, with user lingering for boot startup and a five-second
  failure-restart delay. Intentional stops remain stopped. Shutdown ends pane
  processes; restore from `~/.config/herdr/session.json` is reconstructive.

Use the [Herdr operations and recovery runbook](docs/herdr-supervision-runbook.md)
for service control, safe updates, detached-server recovery, and restore limits.

## Workstation dev sessions

`dev-session` provisions and removes the coding-worker environment for one
GitHub issue. An orchestrator calls it, then talks to the worker directly
through Herdr; `dev-session` never sends a work prompt, interprets work,
reviews code, or decides completion.

```bash
dev-session ensure <project> <issue>
dev-session remove <project> <issue>
```

Identity is the `<project, issue>` pair, and every resource is derived from it:
the repository `~/repos/<project>`, the branch `issue-<issue>`, the worktree
`~/worktrees/<project>/issue-<issue>`, a Herdr workspace labelled
`<project>/issue-<issue>`, and the Codex worker running in that worktree. Git
and Herdr are the only sources of truth; no session database, pane-ID tracking,
or background supervision is kept. The command resolves its own PATH, so it
runs unchanged over Lobu and other non-interactive transports.

`ensure` reuses whatever already matches and creates only what is missing. A
new issue branch starts from the repository's default branch; an existing one is
reused without reset or rebase, and a dirty worktree is valid. The worker is
discovered by the expected worktree's working directory, so a working or blocked
worker is reused and never interrupted. A missing or dead worker is replaced
with a fresh Codex worker launched as
`-m gpt-5.6-luna -c 'model_reasoning_effort="xhigh"'`, keeping the
workstation's own Codex approval and sandbox settings. Before launching, the
pending input line of the target pane is discarded: Codex leaves its terminal
keyboard report as pending shell input when it exits, and that fragment would
otherwise corrupt the next launch command. Contradictory state —
the issue branch checked out elsewhere, a foreign checkout at the expected
path, or more than one worker or workspace matching the session — is reported
instead of repaired. `ensure` prints JSON naming the repository, issue, branch,
worktree, current Herdr target, and observed worker state. Success means the
worker exists and Herdr can address it, not that it is idle.

`remove` deletes only the session's own worker panes, its workspace, and its
worktree. It refuses to interrupt a working worker or to remove a dirty
worktree, proceeds when worker activity cannot be determined, leaves unrelated
workspace contents alone, and tolerates resources a partial cleanup already
removed. The local branch, its remote counterpart, and the pull request all
survive. There is no force cleanup: resolve a refusal by hand.

Missing repositories are never cloned.

## Workstation Collie

Collie is installed and controlled through Herdr. Its plugin checkout,
configuration, state, and generated `collie.service` remain app-owned and
outside `workstation-update`. Dotfiles owns the Bun prerequisite, the boot-time
`collie-bootstrap.service` handoff, and the origin forwarder from `0.0.0.0:8788`
to Collie's loopback listener at `127.0.0.1:8787`. A Home Manager drop-in makes
the app want the forwarder socket without taking ownership of its generated
unit. Collie reconnects independently when Herdr returns.

See the [Collie operator runbook](docs/collie-pilot-runbook.md) for configuration,
manual updates, origin isolation, Web Push, and
[rebuild recovery](docs/collie-pilot-runbook.md#recovery-after-an-lxc-rebuild).
The bootstrap regenerates the service from a surviving plugin installation;
it does not provide VAPID or subscription-state persistence.

## Workstation Lobu

[Lobu](https://lobu.admin.faviann.com) registers the workstation as a headless device
and polls the self-hosted control plane outward over HTTPS. The service selects
the stable `homelab` context independently of the globally active CLI context and
verifies its self-hosted origin before startup. No inbound route, listener, or
reverse-proxy configuration is involved.

- Install: Home Manager activation runs `scripts/lobu-bootstrap`, which installs
  `@lobu/cli` under `~/.local` when the CLI is missing. It preserves an existing
  executable and never authenticates.
- Updates: manual, outside `update-agent-tools`, and not version-pinned.
- Credentials: `lobu login` is interactive and human-owned. No token, device
  identifier, or generated credential is committed to this repository.
- Interactive default: shell sessions and the systemd user manager both export
  `LOBU_CONTEXT=homelab`, so an ad-hoc `lobu daemon` started from a terminal,
  Codex, or Herdr targets the self-hosted control plane instead of the globally
  selected CLI context. The hosted `lobu` context stays available and
  selectable, and an explicit `LOBU_CONTEXT` or `--context` still wins.
- Supervision: Home Manager owns `lobu.service` under `default.target`, with
  user lingering for boot startup. Failures restart after thirty seconds, a
  flat interval chosen so a permanent authentication fault retries against the
  control plane slowly without ever degrading recovery from an isolated one.
  Intentional stops remain stopped. Startup is gated on the presence of
  `~/.config/lobu/credentials.json`, so the unit stays inactive until login.

Durable state under `~/.config/lobu` is owned by homelab-iac's persistent-home
mapping, not by dotfiles. That mapping
([homelab-iac#271](https://github.com/faviann/homelab-iac/pull/271)) must be
deployed before applying this configuration or running `lobu login`. The
self-hosted origin from
[homelab-iac#275](https://github.com/faviann/homelab-iac/issues/275) must also be
deployed and validated first.

Use the [Lobu bootstrap and recovery runbook](docs/lobu-runbook.md) for rollout
order, first deployment, service control, re-authentication, manual upgrades,
and deferred live validation.

## Workstation artifact publishing

The shared `publish-artifact` skill turns a completed file or prepared
directory tree into a browser URL. It discovers its mapping at
`~/.config/faviann-skills/artifacts.json` and rereads it on every publication;
without that file it keeps its local-file handoff.

Home Manager is the sole owner of that user file on the workstation. It is
declared in `home/workstation.nix` and installed as a normal configuration
symlink, which the publisher's discovery accepts. The agreed mapping is:

| Field | Value |
| --- | --- |
| `directory` | `/ephemeral/workstation/artifacts` |
| `baseUrl` | `https://artifacts.admin.faviann.com` |

Dotfiles owns nothing else here.
[homelab-iac#272](https://github.com/faviann/homelab-iac/issues/272) owns the
publishing root, its permissions, the static server, routing, storage and
retention, and the admin forward-auth tier. The endpoint is reachable from
outside the LAN without VPN, subject to admin login; publications are retained
until deliberate cleanup and survive source removal and LXC rebuilds.

The two values are a shared agreement between the repositories with no
automatic synchronization: change them in both, together. The publisher's
optional `FAVIANN_SKILLS_ARTIFACT_CONFIG` per-session override remains
available, and is deliberately not set as a global session variable.

Applying this configuration before the infrastructure is deployed installs a
mapping the publisher will accept but whose URLs do not resolve. Deploy
homelab-iac#272 first, then apply dotfiles, then verify a publication
end to end.

## SSH key rotation

The Bitwarden item and GitHub identity setup are defined in
[bootstrap](BOOTSTRAP.md#bitwarden-ssh-key-item). To replace that identity:

1. Generate a replacement Ed25519 key on a trusted machine.
2. Update the Bitwarden item notes with the replacement private key and the
   `public_key` custom field with its matching public key.
3. Register the replacement in GitHub as both an Authentication Key and a
   Signing Key.
4. Unlock Bitwarden and run `chezmoi apply` on each workstation.
5. Perform the [key-pair and SSH checks](BOOTSTRAP.md#lightweight-verification).
6. Remove the old GitHub Authentication Key and Signing Key only after every
   workstation has the replacement.

Keep private keys out of documentation, shell history, and repository files.
