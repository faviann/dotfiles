# dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io) + Bitwarden CLI.

See `BOOTSTRAP.md` for new machine setup.

## Repository validation

Discover exact behavioral selectors, then run one case or suite during
iteration:

```bash
bash scripts/run-tests --list
bash scripts/run-tests --case test_exact_case_name
bash scripts/run-tests --suite workstation-update.bash
```

Run focused shell analysis after changing Bash or shell templates:

```bash
nix run .#shellcheck
```

Use the complete flake validation as the sole full closeout gate:

```bash
nix flake check
```

It includes ShellCheck, the test-runner contract, and every behavioral suite,
so a standalone full `bash scripts/run-tests` immediately beforehand is
redundant.

## Supported AFK workflow

Sandcastle v0.12.0 is installed as a root development dependency and its
generated Codex, Docker, GitHub Issues simple loop lives in `.sandcastle/`.
Restore the exact dependency tree and build the generated image with:

```bash
npm ci
npx sandcastle docker build-image
```

Codex uses the workstation's existing ChatGPT subscription login. At launch,
the workflow makes a mode-restricted temporary copy of
`${CODEX_HOME:-~/.codex}/auth.json`, mounts only that staging directory
read-only, copies the login into the fresh container's writable Codex home, and
requires `codex login status` to pass before agent work begins. The live host
Codex directory is never mounted. `OPENAI_KEY` and `OPENAI_API_KEY` are removed;
there is no API-key fallback.

GitHub authentication is separate. Put only `GH_TOKEN` in the ignored
`.sandcastle/.env` and restrict the file to the current user:

```bash
install -m 600 .sandcastle/.env.example .sandcastle/.env
```

Then fill in `GH_TOKEN` with the workstation's GitHub credential. The token
needs Issues read/write and Metadata read access for this repository.

The stock `Sandcastle` label is the backlog. The generated loop chooses among
eligible open issues, performs up to three one-issue iterations, commits and
closes completed work, and locally merges its temporary branch into the current
`HEAD`. Run only one Sandcastle process for this repository at a time; this is
an operator rule, not an automated claim or process guard.

Start the foreground repository command in the predictable window owned by the
existing `main` tmux session:

```bash
tmux new-window -d -t main -n sandcastle-dotfiles \
  -c "$(pwd)" 'npm run sandcastle'
tmux set-window-option -t main:sandcastle-dotfiles remain-on-exit failed
```

Attach to `main` for live output. Timestamped logs under
`.sandcastle/logs/`, retained failed worktrees, patches, and normal Codex
session capture are the recovery evidence; tmux owns the live process but is
not the durable result store.

This supported AFK workflow deliberately stays close to Sandcastle upstream.
The research notes under `docs/research/` describe the earlier disposable
pilot harness and its proof-only controls; exact-one guards, explicit issue
targets, proof scans, no-close/no-merge policy, and per-run teardown are not
part of daily operation.

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

Bun is fetched from its upstream GitHub release rather than from nixpkgs,
which lags Bun badly enough that a harness can declare an engine floor newer
than the Bun the profile would supply. Keeping it in the same unit as the
harnesses is what makes the runtime and its dependents move together; the
updater refuses before changing anything if a harness declares a floor the
runtime cannot meet, or if it cannot read one.

The archive is checked against the digest the release API publishes alongside
the download URL. That detects a truncated or corrupted download, not a
compromised release: the digest and the archive come from the same source, and
no independently pinned hash survives outside it.

`codex-acp` also contains its own compatible Codex runtime. That bundled
runtime is distinct from the standalone Codex CLI: updating `@openai/codex`
does not update the runtime used by structured Codex sessions. The updater
checks both scopes and refreshes `codex-acp` to maintain its bundled runtime.

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

The workstation profile pins one Moraine v0.7.3 release bundle and installs its
matching CLI, ingest, monitor-compatibility alias, and MCP executables. There is
intentionally no separate monitor unit; the unified MCP/backend executable owns
the monitor HTTP listener as well as the MCP socket.

Home Manager owns `~/.moraine/config.toml` as a read-only Nix-managed file.
Persistent ingestion state, ClickHouse data, logs, sockets, and process state
remain under `~/.moraine`. Do not use `moraine setup` or another config-writing
command to mutate the managed file; change this module and apply a new Home
Manager generation instead. The enabled Codex sources backfill and watch active
sessions recursively and archived sessions in Codex's flat archive directory.
Moraine's default built-in redaction runs before local storage.

The single `moraine.service` user unit is the operator surface for the local
stack. Upstream `moraine up` owns managed ClickHouse readiness, database
migrations, ingest, and unified-backend startup. The foreground unit monitors
aggregate Moraine health and restarts the complete stack on failure. Default
Moraine topology keeps the HTTP listener on `127.0.0.1:8080` and its per-user
MCP Unix socket at mode 0600; there is no non-loopback listener.

Home Manager also owns Codex's direct stdio registration for the pinned
`moraine run mcp` command. The launcher prefers the Moraine central server
defined in `CONTEXT.md` when healthy and falls back to its embedded server.

## Workstation Agent of Empires

Agent of Empires (`aoe`) is managed here as a user-level workstation tool, not in the Ansible repo.

- Install: `.chezmoiscripts/run_once_install-aoe.sh.tmpl` uses the upstream installer until there is a clean Nix package path.
- Bootstrap handoff: after chezmoi installs AoE and Home Manager provides
  Node/npm and loads the user units, Home Manager runs
  `update-agent-tools --yes` when any managed command is missing. The existing
  `workstation-setup` handoff therefore installs the full toolchain without a
  separate package-discovery or Ansible step.
- SSH login: `dot_bash_profile.tmpl` invokes the dedicated
  `workstation-login` helper for eligible interactive SSH login shells. The
  helper checks workstation freshness and then returns to a plain shell; tmux
  and AoE remain available as explicit commands.
- Shell choice: the workstation LXC is bash-based; `.chezmoiignore` excludes fish config on LXC hosts.
- Dashboard: `home/workstation.nix` declares the `aoe-serve.service`, `aoe-lan-proxy.service`, and `aoe-lan-proxy.socket` user units. The socket exposes `0.0.0.0:4001` and proxies to the localhost service.
- Reboot survival: Ansible enables lingering for the workstation user with `loginctl enable-linger <user>`.

AoE's `acp.allow_agent_install` host-package setting remains off. Dotfiles owns
package installation; the AoE dashboard does not.

### Workstation maintenance

`workstation-update` is the only routine maintenance command. It validates the
chezmoi source as a clean, canonical `main` checkout, fetches and fast-forwards
it to `origin/main`, previews and applies dotfile changes when required, then
delegates workstation configuration to `workstation-setup` whenever dotfiles
work occurred, and finally refreshes AoE, all five standalone CLIs, and all
three ACP adapters as one unit. `workstation-setup` owns workstation
configuration freshness, comparing and activating the Home Manager build; it is
installed by Ansible rather than by chezmoi. Agent tools use latest stable
releases and do not retrieve or display release notes.

`workstation-update` never rewrites `flake.lock`. .NET release discovery and
publication happen upstream through the dedicated GitHub workflow; the normal
SSH notice and `workstation-update` then deliver that validated commit through
the same dotfiles and `workstation-setup` path as any other workstation change.
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

All installs, command and package-version checks, and `aoe acp doctor` must
succeed before activation begins. The updater then restarts the AoE user
service, replaces the ACP workers that were running at the start, and performs
bounded service, ACP diagnostic, and worker-health checks. It records success
only after those activation checks pass.

There is no automatic rollback. On failure, use the reported phase and
component, `systemctl --user status aoe-serve.service`, and
`journalctl --user-unit aoe-serve.service` to correct the problem, then rerun
`workstation-update`. Installation failures happen before process restarts;
activation failures remain recorded until a successful rerun.

The lower-level `update-agent-tools` command remains available for targeted
recovery when a dotfiles/source or workstation-configuration failure prevents
`workstation-update` from reaching its agent-tool phase. Use it only to repair
that agent-tool state, then return to `workstation-update` for routine
maintenance. Home Manager also uses `update-agent-tools --yes` during initial
bootstrap when managed commands are missing.

### Login freshness notices

Eligible interactive SSH logins run a synchronous, non-mutating freshness
check from the dotfiles-managed Bash login profile. Dotfiles and agent-tool
sources cache successful checks for 24 hours and retry failed source checks
after one hour; their cache ages are independent. Local blockers and incomplete
maintenance are evaluated on every eligible login. Healthy or not-yet-due state
is silent. Available updates and retryable maintenance produce one combined
notice with exactly one `Run: workstation-update` action. A local blocker
instead says that maintenance is blocked and must be resolved before the
command is run. A hard 15-second deadline bounds the check, and failure or
timeout never prevents the shell from opening.

Login never installs updates. There is no workstation-side background timer or
scheduler, and local shells, remote commands, and non-interactive shells do not
run the login check. Workstations without the completed setup marker also skip
it. Each eligible SSH login warns when maintenance is actionable; healthy state
remains silent. The login profile deliberately does not source `.bashrc`, so
unrelated interactive-shell configuration is not pulled into the login
boundary.

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
- No services: herdr listens on a Unix socket only. It has no dashboard and no
  LAN port, so it declares no user units.

The manual, loopback-only Collie evaluation that uses herdr is documented in
the [Collie pilot runbook](docs/collie-pilot-runbook.md). Collie's plugin,
configuration, state, and generated service remain outside dotfiles ownership.
