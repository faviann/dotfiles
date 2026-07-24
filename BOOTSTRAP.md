# Bootstrap - New Machine Setup

Run these steps in order on any new workstation.

## 1. Install chezmoi and Bitwarden CLI

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin
sudo snap install bw
```

## 2. Unlock Bitwarden

```bash
bw login                                  # first time only
export BW_SESSION=$(bw unlock --raw)
```

Do not paste or commit secrets. Keep the session token in your shell only.

## 3. Bootstrap over HTTPS

The first checkout uses HTTPS so a new machine does not need an SSH key before
chezmoi can render one from Bitwarden.

```bash
chezmoi init --apply https://github.com/faviann/dotfiles.git
```

After apply, chezmoi writes `~/.ssh/id_ed25519`, `~/.ssh/id_ed25519.pub`, and
`~/.ssh/known_hosts`. Dotfiles pins GitHub's published Ed25519 SSH host key; it
does not scan the network during apply. A run-after script then switches the
chezmoi source repo origin to `git@github.com:faviann/dotfiles.git`.

## 4. Apply Home Manager on the Workstation LXC

The Ansible-managed `workstation` LXC installs Determinate Nix and a
`workstation-setup` helper. Run that helper after Bitwarden is unlocked:

```bash
workstation-setup
```

It runs `chezmoi init/update`, applies the `#workstation` Home Manager flake,
authenticates GitHub CLI from the `dotfiles/github-cli-token` Bitwarden item,
and validates the expected tools. Chezmoi installs AoE first. Home Manager then
installs the stable base tools, including Node/npm, `uv`, `gh`, and Hermes,
loads the AoE user units, and hands off to `update-agent-tools --yes` if any
managed agent command is missing. That handoff installs the standalone Codex,
Claude Code, and Pi CLIs plus the `codex-acp`, `claude-agent-acp`, and `pi-acp`
adapters. No package lookup or additional homelab/Ansible change is required.

AoE's host-level `acp.allow_agent_install` setting stays disabled; dotfiles is
the package owner. The bootstrap update is part of `workstation-setup`, not an
SSH-login installation or a background schedule.

Chezmoi also recovers agent skills on the workstation. If `~/repos/skills` is
absent, it clones `faviann/skills`; it never updates an existing checkout. The
repository's reconciler restores supported harness links while leaving
deprecated skills unlinked. Skill reconciliation runs during `chezmoi apply`,
not during login-time freshness checks.

Hermes runtime state lives in `~/.hermes`. On a rebuilt workstation that already
has Hermes state, move that directory into `/ephemeral/workstation/home/.hermes`
before enabling the bind mount.

## Bitwarden SSH Key Item

Create or maintain one Bitwarden item named:

```text
dotfiles/workstation-ssh-key
```

The item must contain:

- Notes: the private OpenSSH Ed25519 key for `~/.ssh/id_ed25519`
- Custom field `public_key`: the matching public key for `~/.ssh/id_ed25519.pub`

Keep the private key only in the item notes. Do not duplicate it into docs,
Ansible vars, shell history, or plaintext files.

## GitHub Registration

Register the same public key in GitHub twice:

- Settings -> SSH and GPG keys -> New SSH key -> Authentication Key
- Settings -> SSH and GPG keys -> New SSH key -> Signing Key

This gives the workstation one stable SSH identity for both Git authentication
and commit signing.

## Lightweight Verification

Check that the rendered public key matches the private key without printing the
private key:

```bash
diff -u \
  <(awk 'NF >= 2 { print $1 " " $2; exit }' ~/.ssh/id_ed25519.pub) \
  <(ssh-keygen -y -f ~/.ssh/id_ed25519 | awk 'NF >= 2 { print $1 " " $2; exit }')
```

No output means the key pair matches.

Check GitHub SSH auth:

```bash
ssh -T git@github.com
```

GitHub should identify the account and report that shell access is not provided.

## Optional GitHub CLI Auth

If you use `gh`, authenticate without generating or uploading another SSH key:

```bash
gh auth login --git-protocol ssh --skip-ssh-key
```

## Rotation Runbook

1. Generate a replacement Ed25519 key on a trusted machine.
2. Update the Bitwarden item notes with the replacement private key.
3. Update the `public_key` custom field with the matching public key.
4. Add the replacement public key to GitHub as both an Authentication Key and a
   Signing Key.
5. Run `chezmoi apply` on each workstation after unlocking Bitwarden.
6. Verify with the `diff` command above and `ssh -T git@github.com`.
7. Remove the old Authentication Key and Signing Key from GitHub after every
   workstation has the replacement key.

## Day-to-Day Updates

```bash
workstation-update
```

`workstation-update` is the only routine maintenance command. It validates the
chezmoi source as a clean, canonical `main` checkout, fetches and fast-forwards
it to `origin/main`, previews and applies required dotfile changes, and then
updates AoE; the standalone Codex, Claude Code, and Pi CLIs; and the
`codex-acp`, `claude-agent-acp`, and `pi-acp` adapters as one unit. The Codex
runtime bundled inside `codex-acp` is separate from the standalone Codex CLI,
so both scopes are checked.

When a dotfile apply must render Bitwarden-backed templates, an interactive
update reuses a valid `BW_SESSION` or prompts once to unlock the vault for the
duration of the command. Unattended use cannot prompt; export a valid session
first with `export BW_SESSION="$(bw unlock --raw)"`.

The workflow refuses dirty, non-canonical, ahead, or diverged source state and
does not reset or discard local work. Dotfile apply is previewed before it runs,
and locally modified targets are not silently overwritten.

An interactive update asks once when running ACP sessions would be restarted
and reports only the number affected. Automation must pass `--yes` to authorize
that disruption; otherwise it refuses safely. Installation and pre-activation
verification finish before the AoE service or ACP workers restart. Bounded
service, ACP diagnostic, and worker-health checks must pass before success is
recorded.

Interactive SSH login only checks freshness: it never installs. Successful
dotfiles and agent-tool checks are cached independently for 24 hours, failed
source checks retry after one hour, and local blockers or incomplete
maintenance are evaluated every time. Current state is silent. Actionable state
prints one combined notice rather than release notes. Available updates and
retryable maintenance show one `Run: workstation-update` action; local blockers
say that they must be resolved before running the command. The check has a hard
15-second deadline and never prevents the shell from opening. The
dotfiles-managed Bash login profile and `workstation-login` helper own this
check; they do not source `.bashrc` or auto-launch tmux/AoE. There is no
background scheduling or per-component update command.

Failed updates do not roll back automatically. Use the reported phase and
component, inspect `systemctl --user status aoe-serve.service` and
`journalctl --user-unit aoe-serve.service` when activation is involved, correct
the underlying problem, and rerun `workstation-update`.

Direct `update-agent-tools` use is reserved for initial bootstrap and targeted
recovery. If a dotfiles/source failure prevents `workstation-update` from
reaching the agent-tool phase, use the direct updater only to repair the
agent-tool state, then return to `workstation-update`. For unattended routine
maintenance, `workstation-update --yes` authorizes replacement of running ACP
sessions; it does not bypass source or dotfile safety checks.

## Clone ServerManagementScripts

On the managed `workstation` LXC, run `workstation-setup` before this step so
Home Manager has installed `uv`. The vault passphrase is written by chezmoi
from Bitwarden before this step.

```bash
git clone git@github.com:faviann/ServerManagementScripts.git
cd ServerManagementScripts
./setup.sh
```

## Hostname Contract

The LXC workstation must be named `workstation` as set by the Ansible repo.
That hostname triggers `is_lxc = true` in `.chezmoi.toml.tmpl`, which skips fish
config on that machine.

When lifecycle playbooks run from the workstation itself, they exclude that host
by default. To manage it intentionally, run:

```bash
uv run --locked ansible-playbook site.yml -e proxmox_skip_self=false --limit workstation
```
