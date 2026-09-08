# dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io) + Bitwarden CLI.

See `BOOTSTRAP.md` for new machine setup.

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
home-manager build --flake /home/aperture/repos/dotfiles#workstation
```

## Workstation Moraine

The workstation profile source-builds Moraine at commit `91cd7a13ba29`, the
mainline merge of upstream PR #658 after v0.7.3, with the upstream Rust 1.96.0
toolchain and locked Cargo closure. It installs matching CLI, ingest,
monitor-compatibility alias, and MCP executables, while reusing the unchanged,
hash-pinned v0.7.3 monitor assets. There is intentionally no separate monitor
unit; the unified MCP/backend executable owns the monitor HTTP listener, native
loopback `/mcp` endpoint, and private MCP socket.

The package temporarily gives Moraine's interactive query profile 8 GiB, its
ClickHouse user a 16 GiB aggregate limit, and managed ClickHouse a 48 GiB
process limit on this 64 GiB host. This keeps session discovery usable while
upstream issue #599's bounded summary query remains unresolved. Background
queries retain upstream's 256 MiB ceiling. Remove
`packages/moraine-managed-memory-headroom.patch` when a bounded upstream
discovery path is pinned.

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
- Shell choice: the workstation LXC is bash-based; `.chezmoiignore` excludes fish config on LXC hosts.
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

Login loads the shell environment and performs no network checks or updates.
The former login freshness helper, release comparison caches, applied-commit
marker, and background-check interface have been removed. Package managers
resolve releases during explicit maintenance, chezmoi tracks target state, and
`workstation-setup` checks configuration freshness. Existing cache files under
`~/.local/state/workstation-update` and `~/.local/state/update-agent-tools` are
unused; only the maintenance lock files remain active. Old installed
`workstation-login` copies are no longer invoked and may be removed.

This trades advance update notices and no-op detection for a smaller ownership
boundary. An explicit maintenance run may reinstall current agent versions and
restart their services, so choose an appropriate maintenance window. There is
no workstation-side update scheduler. The login profile continues to load the
required environment without sourcing unrelated `.bashrc` configuration.

## Workstation herdr

[herdr](https://herdr.dev) is a terminal agent multiplexer, installed for
evaluation alongside AoE. It is not an AoE replacement: AoE serves conversations
over HTTP, while herdr is a TUI.

- Install: `.chezmoiscripts/run_once_install-herdr.sh.tmpl` uses the upstream
  installer until there is a clean Nix package path. herdr is packaged in
  nixpkgs, but not in the pinned nixpkgs revision.
- Updates: herdr is deliberately outside the `workstation-update` managed unit.
  It self-updates through `herdr update`, run by hand. That command refuses to
  run from inside a herdr pane; detach from the session first.
- Configuration: `~/.config/herdr/config.toml` is optional and unmanaged. herdr
  writes to it itself, so chezmoi does not own it.
- Supervision: Home Manager enables the foreground `herdr.service` under
  `default.target`. Existing user lingering starts it at boot without login.
  Failures restart after five seconds; an intentional stop remains stopped.
  Server shutdown ends pane processes. Restore is reconstructive: herdr reads
  `~/.config/herdr/session.json` to rebuild its session, not resume live processes.

```bash
systemctl --user status herdr.service collie.service --no-pager
journalctl --user -u herdr.service -u collie.service --since=-10m --no-pager
systemctl --user stop herdr.service     # remains stopped until start or next boot
systemctl --user start herdr.service
systemctl --user restart herdr.service  # ends panes and reconstructs the session
```

Before a manual update, finish important pane work and use a terminal outside
herdr. Run `systemctl --user stop herdr.service`, then `herdr update`, then
`systemctl --user start herdr.service`. Avoid launching the interactive herdr
client while the service is stopped: it can create an unmanaged detached server.
Collie keeps its own service and reconnects when herdr returns. Home Manager
also runs `collie-bootstrap.service` at boot to regenerate that service from the
persisted plugin installation after an LXC rebuild. See the
[rebuild recovery procedure](docs/collie-pilot-runbook.md#recovery-after-an-lxc-rebuild).

For the one-time migration and recovery evidence, see the
[herdr supervision runbook](docs/herdr-supervision-runbook.md).

The manual, loopback-only Collie evaluation that uses herdr is documented in
the [Collie pilot runbook](docs/collie-pilot-runbook.md). Collie's plugin,
configuration, state, and generated service remain outside dotfiles ownership.
