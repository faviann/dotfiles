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
and validates the expected tools. Home Manager installs the stable base tools,
including Node/npm, `uv`, `gh`, and Hermes. The `update-agent-tools` helper
installs or refreshes Codex, Claude Code, and Pi.dev through npm.

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
export BW_SESSION=$(bw unlock --raw)
chezmoi update
```

`chezmoi update` pulls from the SSH origin after the first bootstrap and then
re-applies templates from Bitwarden.

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
