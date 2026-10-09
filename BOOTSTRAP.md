# Bootstrap - New Machine Setup

Run these steps in order on a new workstation or desktop. The bootstrap node
has its [own path](#bootstrap-node).

## Machine Profiles

`chezmoi init` derives the machine profile from the hostname, without a
prompt, and `.chezmoiignore` applies only that profile's targets:

| Hostname | Profile | Gets | Bitwarden items |
| --- | --- | --- | --- |
| `workstation` | `workstation` | Everything below, plus `workstation-update`, `dev-session`, and `update-agent-tools` | All six items below, plus `dotfiles/github-cli-token` for `workstation-setup` |
| `bootstrap` | `bootstrap` | Bash config, global git ignore, Ansible controller key and vault password | `dotfiles/proxmox-lxc-ssh-key`, `dotfiles/ansible-vault-pass` |
| anything else | `desktop` | Bash config, global git ignore, git identity and signing, SSH key and config, GitHub token routing and `gh` wrapper, agent setup, fish | `dotfiles/workstation-ssh-key`, `dotfiles/github-token-work`, `dotfiles/sub2api-gateway-token`, `dotfiles/sub2api-admin-key`, plus `dotfiles/github-cli-token` for the one-time `gh` login |

The workstation also gets the Ansible controller key and vault password. Only
the workstation and the desktop get a personal GitHub identity; the bootstrap
node pulls public repositories over HTTPS and keeps an HTTPS chezmoi origin.
Desktops get agent configuration but no agent binaries or Home Manager yet.

## 1. Install chezmoi and Bitwarden CLI

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin
sudo snap install bw
```

On a desktop, also install the tools the dotfiles call:

```bash
sudo apt install git curl jq gh
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

After apply, chezmoi writes `~/.ssh/id_ed25519`, `~/.ssh/id_ed25519.pub`,
`~/.ssh/known_hosts`, and the
[Claude Code gateway](#bitwarden-claude-code-gateway-items) credentials in
`~/.config/claude/`; the workstation also gets the Ansible controller key pair
in `~/.ansible/ssh/`. Dotfiles pins GitHub's published Ed25519 SSH host key; it
does not scan the network during apply. A run-after script then switches the
chezmoi source repo origin to `git@github.com:faviann/dotfiles.git`.

Apply also clones `faviann/skillset` over HTTPS, without credentials, for the
agent skills, so that repository must stay public. Until this repository is
public too, the HTTPS `chezmoi init` above needs GitHub credentials.

On a desktop, log `gh` in once with the `main` token:

```bash
bw get notes dotfiles/github-cli-token \
  | gh auth login --hostname github.com --with-token
```

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

Setup does not log in Azure CLI. There is no service principal, so agents act as
your own account. Log in once; the session in `~/.azure` persists until it goes
unused for about 90 days:

```bash
az login --use-device-code --tenant <tenant-id-or-domain>
```

Pass `--tenant`: the device-login page's "Sign in to an organization" option
404s on `/common/oauth2/undefined`.

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

## Bitwarden Ansible Controller Key Item

homelab-iac authenticates to managed hosts with `~/.ansible/ssh/proxmox_lxc`.
Every LXC in the fleet trusts this key, so a regenerated key would lock the
controller out. Keep it in one Bitwarden item named:

```text
dotfiles/proxmox-lxc-ssh-key
```

The item must contain:

- Notes: the private OpenSSH key for `~/.ansible/ssh/proxmox_lxc`
- Custom field `public_key`: the matching public key for
  `~/.ansible/ssh/proxmox_lxc.pub`

Check the rendered pair the same way as the workstation key, with
`~/.ansible/ssh/proxmox_lxc` in place of `~/.ssh/id_ed25519`.

## Bitwarden Claude Code Gateway Items

Claude Code reaches Anthropic through the sub2api gateway at
`gateway.ai.faviann.com`. On the workstation and desktops, chezmoi renders two
credentials that sub2api issued, each from the Notes of one Bitwarden item:

- `dotfiles/sub2api-gateway-token`: the gateway API key Claude Code
  authenticates with, rendered to `~/.config/claude/gateway-token`. The
  `apiKeyHelper` in `~/.claude/settings.json` reads it.
- `dotfiles/sub2api-admin-key`: the sub2api admin API key, rendered to
  `~/.config/claude/gateway-admin-key`. The status line uses it to read each
  Claude account's 5-hour and weekly usage.

Create both items before the first apply. Chezmoi sets only its own keys in
`~/.claude/settings.json` and leaves the rest of the file to Claude Code.

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

On the workstation and desktops, HTTPS git and `gh` use two fine-grained personal access
tokens for the same GitHub account. Each token is a profile. The `main`
profile's resource owner is the personal account; its Bitwarden item is
`dotfiles/github-cli-token`, and its live copy is `gh`'s own login. The `work`
profile's resource owner is the employer organization; its Bitwarden item is
`dotfiles/github-token-work`, and its live copy is
`~/.config/github-tokens/work`.

`workstation-setup` logs `gh` in with the `main` token; on a desktop you log
in once by hand, as in [step 3](#3-bootstrap-over-https). The bootstrap node
has no GitHub tokens.

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

After bootstrap, use `workstation-update` for routine maintenance on the
workstation. See the canonical
[workstation maintenance guidance](docs/workstation/maintenance.md) for source
guards, Bitwarden sessions, and failure recovery. Desktops and the bootstrap
node use `chezmoi update`.

## Clone ServerManagementScripts

On the managed `workstation` LXC, run `workstation-setup` before this step so
Home Manager has installed `uv`. The vault passphrase is written by chezmoi
from Bitwarden before this step.

```bash
git clone git@github.com:faviann/ServerManagementScripts.git
cd ServerManagementScripts
./setup.sh
```

## Bootstrap Node

The `bootstrap` LXC is a root-only control node that deploys the workstation.
It gets only the Ansible controller key and vault password, with no personal
GitHub identity. homelab-iac#534 sets the node up with chezmoi and the
Bitwarden CLI. Until this repository is public (#136), the HTTPS
`chezmoi init` below needs GitHub credentials. As root, with `$HOME=/root`:

```bash
bw login                                  # first time only
export BW_SESSION=$(bw unlock --raw)
chezmoi init --apply https://github.com/faviann/dotfiles.git
bw lock
```

Its chezmoi origin stays HTTPS, so `chezmoi update` works without an SSH key.

## Lifecycle Playbooks on the Workstation

When lifecycle playbooks run from the workstation itself, they exclude that host
by default. To manage it intentionally, run:

```bash
uv run --locked ansible-playbook site.yml -e proxmox_skip_self=false --limit workstation
```
