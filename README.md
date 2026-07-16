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
workstation: Node.js/npm, `uv`, `gh`, `jq`, `ripgrep`, `fd`, `fzf`, and
Hermes. Hermes is installed from `github:NousResearch/hermes-agent` as a
normal non-NixOS package; provider credentials and runtime configuration stay
in `~/.hermes`.

Dotfiles and the complete AoE agent toolchain are maintained through one
operator-facing command:

```bash
workstation-update
```

The managed unit contains:

- Agent of Empires (`aoe`)
- the standalone Codex CLI (`@openai/codex`)
- Claude Code (`@anthropic-ai/claude-code`)
- Pi (`@earendil-works/pi-coding-agent`)
- the `codex-acp` adapter (`@agentclientprotocol/codex-acp`)
- the `claude-agent-acp` adapter
  (`@agentclientprotocol/claude-agent-acp`)
- the `pi-acp` adapter

`codex-acp` also contains its own compatible Codex runtime. That bundled
runtime is distinct from the standalone Codex CLI: updating `@openai/codex`
does not update the runtime used by structured Codex sessions. The updater
checks both scopes and refreshes `codex-acp` to maintain its bundled runtime.

Home Manager provides Node/npm and writes the npm prefix as
`/home/faviann/.local`; all npm-managed commands resolve from `~/.local/bin`.

Apply it through the Ansible-installed `workstation-setup` command, or build it
directly while developing dotfiles:

```bash
home-manager build --flake /home/aperture/repos/dotfiles#workstation
```

## Workstation Agent of Empires

Agent of Empires (`aoe`) is managed here as a user-level workstation tool, not in the Ansible repo.

- Install: `.chezmoiscripts/run_once_install-aoe.sh.tmpl` uses the upstream installer until there is a clean Nix package path.
- Bootstrap handoff: after chezmoi installs AoE and Home Manager provides
  Node/npm and loads the user units, Home Manager runs
  `update-agent-tools --yes` when any managed command is missing. The existing
  `workstation-setup` handoff therefore installs the full toolchain without a
  separate package-discovery or Ansible step.
- SSH launch: `dot_bashrc.tmpl` checks workstation freshness, then
  auto-attaches eligible interactive SSH logins to tmux session `main`, or
  creates it running `aoe`. The hook skips local and non-interactive shells,
  remote commands, nested tmux, and incomplete workstation setup. A missing or
  failed freshness command never prevents the existing tmux/AoE launch.
- Shell choice: the workstation LXC is bash-based; `.chezmoiignore` excludes fish config on LXC hosts.
- Dashboard: `home/workstation.nix` declares the `aoe-serve.service`, `aoe-lan-proxy.service`, and `aoe-lan-proxy.socket` user units. The socket exposes `0.0.0.0:4001` and proxies to the localhost service.
- Reboot survival: Ansible enables lingering for the workstation user with `loginctl enable-linger <user>`.

AoE's `acp.allow_agent_install` host-package setting remains off. Dotfiles owns
package installation; the AoE dashboard does not.

### Workstation maintenance

`workstation-update` is the only routine maintenance command. It validates the
chezmoi source as a clean, canonical `main` checkout, fetches and fast-forwards
it to `origin/main`, previews and applies dotfile changes when required, and
then refreshes AoE, all three standalone CLIs, and all three ACP adapters as
one unit. Agent tools use latest stable releases and do not retrieve or display
release notes.

The command refuses unsafe source states such as local content, a non-canonical
origin, the wrong branch or upstream, and ahead or diverged history. It does
not reset or discard local work. If ACP sessions are running, an interactive
update reports only their count and asks once before changing agent-tool state
or running processes. Declining leaves the toolchain and running processes
alone. For unattended use, `workstation-update --yes` authorizes those
agent-session restarts; it does not authorize overwriting local dotfile changes
or bypass any source guard.

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
recovery when a dotfiles/source failure prevents `workstation-update` from
reaching its agent-tool phase. Use it only to repair that agent-tool state, then
return to `workstation-update` for routine maintenance. Home Manager also uses
`update-agent-tools --yes` during initial bootstrap when managed commands are
missing.

### Login freshness notices

Eligible interactive SSH logins run a synchronous, non-mutating freshness
check immediately before tmux attaches or creates the AoE session. Dotfiles and
agent-tool sources cache successful checks for 24 hours and retry failed source
checks after one hour; their cache ages are independent. Local blockers and
incomplete maintenance are evaluated on every eligible login. Healthy or
not-yet-due state is silent. Actionable state produces one combined notice with
exactly one `Run: workstation-update` action. A hard 15-second deadline bounds
the check, and failure or timeout never prevents tmux/AoE launch.

Login never installs updates. There is no background timer or scheduler, and
local shells, nested tmux sessions, remote commands, and non-interactive shells
do not run the login check. Workstations without the completed setup marker also
skip it.

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
