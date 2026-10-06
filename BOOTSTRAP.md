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
and validates the expected tools. Home Manager installs the base tools, loads
the user units, and hands off to `update-agent-tools` if any managed agent
command is missing. This installs the
[complete agent toolchain](docs/workstation/toolchain.md) without another
package-discovery or Ansible step.

The bootstrap handoff is part of `workstation-setup`, not SSH login or a
background schedule.

Chezmoi also recovers agent skills on the workstation. If `~/repos/skillset`
is absent, it clones `faviann/skillset` and initializes its pinned submodule
sources; it never updates an existing checkout or its sources. Skillset's
reconciler then links the skills selected in its `skills.txt` into the
supported harnesses. Skill reconciliation runs during `chezmoi apply`, never
during shell login.

Hermes runtime state lives in `~/.hermes`. On a rebuilt workstation that already
has Hermes state, move that directory into `/ephemeral/workstation/home/.hermes`
before enabling the bind mount. For Collie's service-regeneration prerequisites
and retry command, see [recovery after an LXC rebuild](docs/runbooks/collie.md#recovery-after-an-lxc-rebuild).

## Bitwarden SSH Key Item

Create or maintain one Bitwarden item named:

```text
dotfiles/workstation-ssh-key
```

The item must contain:

- Notes: the private OpenSSH Ed25519 key for `~/.ssh/id_ed25519`
- Custom field `public_key`: the matching public key for `~/.ssh/id_ed25519.pub`

Keep the private key only in the item notes. Do not duplicate it into docs,
Ansible vars, shell history, or plaintext files. For later replacement, use the
[SSH key rotation procedure](docs/ssh-key-rotation.md).

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

## GitHub Tokens

On the workstation, HTTPS git and `gh` use two fine-grained personal access
tokens for the same GitHub account. Each token is a profile. The `main`
profile's resource owner is the personal account; its Bitwarden item is
`dotfiles/github-cli-token`, and its live copy is `gh`'s own login. The `work`
profile's resource owner is the employer organization; its Bitwarden item is
`dotfiles/github-token-work`, and its live copy is
`~/.config/github-tokens/work`.

`workstation-setup` logs `gh` in with the `main` token. Other hosts have no
`work` profile; if you use `gh` there, log in without generating or uploading
another SSH key:

```bash
gh auth login --git-protocol ssh --skip-ssh-key
```

Both items keep the token in Notes. The `work` item also needs a custom field
`owner` containing the organization's login, in GitHub's canonical casing:
git matches the owner case-sensitively, so remotes must use the same casing.
The organization name lives only in Bitwarden and in rendered files under
`$HOME`; this repository is public, so never commit it. Give the `work` token
read-only Contents, read and write Issues and Pull requests, and read-only
Actions and Commit statuses.

### Routing

Git's credential configuration is the only routing table. Chezmoi renders a
`[credential "https://github.com/<owner>"]` section into `~/.gitconfig` that
sends repositories under the `owner` to `github-token credential work`. Every
other `github.com` repository uses `gh auth git-credential`, the `main` login.

`~/.local/bin/gh` wraps the Nix `gh` and gives each call the token git's
configuration assigns to its target repository. Like `gh`, it takes the target
from `--repo`, the `OWNER/REPO` argument of `repo view` or `repo clone`, a
`github.com` pull request or issue URL argument, an `api repos/OWNER/REPO/...`
endpoint, or the checkout's base remote. It does
not change `gh auth` commands or calls that already have `GH_TOKEN` or
`GITHUB_TOKEN`. Git operations that `gh` itself runs during a `work`-routed
call also use the `work` token.

### Rotation and expiry

To replace a token, create the new token on GitHub and run:

```bash
github-token rotate work    # or: github-token rotate main
```

The command reads the token from standard input, without echoing it on a
terminal. It needs an unlocked Bitwarden session. It checks the token with
GitHub, writes it to the profile's Bitwarden Notes, and syncs Bitwarden. It
then reloads the live copy: `gh auth login` for `main`, and `chezmoi apply` of
the token file for `work`. An invalid token leaves Bitwarden unchanged.

At the end of every run, `workstation-update` runs
`github-token check-expiry`. This prints a warning for each token that expires
within 7 days or that GitHub rejects. The warnings never fail the update.

### Pull requests from a private fork

A fine-grained token cannot open a pull request from a personal fork into a
private organization repository. When `gh pr create` targets such a
repository with the `work` token, the wrapper does not call `gh`. Instead, it
prints a GitHub compare URL that carries the title and body, followed by
instructions for an agent. Then it exits with status 3, which `gh` itself
never uses. Open the URL and click **Create pull request**. Set draft state,
labels, reviewers, and assignees on that page or after the pull request
exists. Push the branch to `origin` first; the wrapper refuses to hand off a
branch that is not on the fork.

## Day-to-Day Updates

After bootstrap, use `workstation-update` for routine maintenance. See the
canonical [workstation maintenance guidance](docs/workstation/maintenance.md)
for source guards, Bitwarden sessions, and failure recovery.

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
That hostname triggers `is_workstation = true` in `.chezmoi.toml.tmpl`, which
skips fish config on that machine.

When lifecycle playbooks run from the workstation itself, they exclude that host
by default. To manage it intentionally, run:

```bash
uv run --locked ansible-playbook site.yml -e proxmox_skip_self=false --limit workstation
```
