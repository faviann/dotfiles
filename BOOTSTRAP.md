# Bootstrap - New Machine Setup

Run these steps in order on any new machine.

## 1. Generate SSH key (once per machine)

```bash
ssh-keygen -t ed25519 -C "faviann@gmail.com" -f ~/.ssh/id_ed25519
```

Then add `~/.ssh/id_ed25519.pub` to GitHub:
- **Settings -> SSH and GPG keys -> New SSH key**
- Add once as **Authentication Key**
- Add again as **Signing Key**

## 2. Install chezmoi and Bitwarden CLI

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin
sudo snap install bw
```

## 3. Unlock Bitwarden

```bash
bw login                                  # first time only
export BW_SESSION=$(bw unlock --raw)
```

## 4. Apply dotfiles

Writes personal config including `~/.gitconfig`, `~/.ssh/`, and `~/.ansible/vault-pass`.

```bash
chezmoi init --apply git@github.com:faviann/dotfiles.git
```

## 5. Clone ServerManagementScripts (if needed on this machine)

The vault passphrase is already on disk from step 4.

```bash
git clone git@github.com:faviann/ServerManagementScripts.git
cd ServerManagementScripts
ansible-playbook bootstrap.yml
```

## Day-to-day: pull and re-apply

```bash
export BW_SESSION=$(bw unlock --raw)
chezmoi update
```

## Verify

```bash
cat ~/.gitconfig                        # git config applied
cat ~/.ssh/allowed_signers              # signing key line present
cat ~/.ansible/vault-pass | wc -c       # > 0 means vault passphrase written
test ! -f ~/.config/fish/config.fish || fish_greeting
```

## Hostname contract

The LXC workstation must be named `workstation` (set by the Ansible repo).
This triggers `is_lxc = true` in `.chezmoi.toml.tmpl`, which skips fish config
on that machine.

When lifecycle playbooks run from the workstation itself, they exclude that host
by default. To manage it intentionally, run:

```bash
ansible-playbook site.yml -e proxmox_lifecycle_target_hosts=lxcs --limit workstation
```