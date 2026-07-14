# dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io) + Bitwarden CLI.

See `BOOTSTRAP.md` for new machine setup.

## Workstation Home Manager

The `workstation` Home Manager flake installs user tooling for the Debian LXC
workstation: Node.js/npm, `uv`, `gh`, `jq`, `ripgrep`, `fd`, `fzf`, and
Hermes. Hermes is installed from `github:NousResearch/hermes-agent` as a
normal non-NixOS package; provider credentials and runtime configuration stay
in `~/.hermes`.

The complete AoE agent toolchain is intentionally maintained through one
explicit latest-stable layer instead of pinned Nix packages:

```bash
update-agent-tools
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
- SSH launch: `dot_bashrc.tmpl` auto-attaches interactive SSH logins to tmux session `main`, or creates it running `aoe`. The hook only runs for SSH TTY sessions, skips remote commands, skips nested tmux, and waits for the workstation setup marker.
- Shell choice: the workstation LXC is bash-based; `.chezmoiignore` excludes fish config on LXC hosts.
- Dashboard: `home/workstation.nix` declares the `aoe-serve.service`, `aoe-lan-proxy.service`, and `aoe-lan-proxy.socket` user units. The socket exposes `0.0.0.0:4001` and proxies to the localhost service.
- Reboot survival: Ansible enables lingering for the workstation user with `loginctl enable-linger <user>`.

AoE's `acp.allow_agent_install` host-package setting remains off. Dotfiles owns
package installation; the AoE dashboard does not.

### Toolchain maintenance

`update-agent-tools` is the only maintenance command. It refreshes AoE, all
three standalone CLIs, and all three ACP adapters as one unit; there are no
per-component update commands. It uses latest stable releases and does not
retrieve or display release notes.

If ACP sessions are running, an interactive update reports only their count and
asks once before changing anything. Declining leaves the toolchain and running
processes alone. Non-interactive use refuses to disrupt running sessions unless
`update-agent-tools --yes` is used.

All installs, command and package-version checks, and `aoe acp doctor` must
succeed before activation begins. The updater then restarts the AoE user
service, replaces the ACP workers that were running at the start, and performs
bounded service, ACP diagnostic, and worker-health checks. It records success
only after those activation checks pass.

There is no automatic rollback. On failure, use the reported phase and
component, `systemctl --user status aoe-serve.service`, and
`journalctl --user-unit aoe-serve.service` to correct the problem, then rerun
`update-agent-tools`. Installation failures happen before process restarts;
activation failures remain recorded until a successful rerun.

### Login freshness notices

Eligible interactive SSH logins run a synchronous, non-mutating freshness
check immediately before AoE opens. A successful check is reused for 24 hours;
a failed check is retried after one hour. Healthy state is silent. When updates
exist, the notice contains only affected component names and current-to-latest
versions. A failed check retains the last known result and prints the last
successful check plus the exact next retry time.

Login never installs updates. There is no background timer or scheduler, and
local shells, nested tmux sessions, remote commands, and non-interactive shells
do not run the login check.
