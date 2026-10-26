# Bootstrap - New Machine Setup

Run these steps in order on a new workstation or desktop.

## Machine Profiles

`chezmoi init` derives the machine profile from the hostname, without a
prompt, and `.chezmoiignore` applies only that profile's targets:

| Hostname | Profile | Gets | Bitwarden items |
| --- | --- | --- | --- |
| `workstation` | `workstation` | Everything below except fish and the `desktop` Home Manager profile, plus `workstation-update`, `dev-session`, and `update-agent-tools` | All six items below, plus `dotfiles/github-cli-token` for `workstation-setup` |
| anything else | `desktop` | Bash config, global git ignore, git identity and signing, SSH key and config, `github-token` rotation, agent setup, fish, and the `desktop` Home Manager profile | `dotfiles/workstation-ssh-key`, `dotfiles/sub2api-gateway-token`, `dotfiles/sub2api-admin-key`, `dotfiles/artifact-server-api-key`, plus `dotfiles/github-cli-token` for the one-time `gh` login |

The workstation also gets the Ansible controller key and vault password.
Desktops get agent configuration and the `desktop` Home Manager profile, which
installs the artifact-server publishing toolchain: the `artifactserver` CLI,
Node.js, Chromium, and the DejaVu fonts. Desktops still get no agent binaries.
Apply installs the profile, as in [step 3](#3-bootstrap-over-https); see the
[desktop toolchain](docs/desktop-toolchain.md).

## 1. Install chezmoi and Bitwarden CLI

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin
sudo snap install bw
```

On a desktop, also install the tools the dotfiles call:

```bash
sudo apt install git curl jq gh
```

A desktop also needs Nix for its Home Manager profile. Install Determinate Nix,
then open a new shell so `nix` is on `PATH`:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
  | sh -s -- install
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
`~/.ssh/known_hosts`, the
[Claude Code gateway](#bitwarden-claude-code-gateway-items) credentials in
`~/.config/claude/`, and the
[artifact-server API key](#bitwarden-artifact-server-api-key-item); the
workstation also gets the Ansible controller key pair
in `~/.ansible/ssh/`. Dotfiles pins GitHub's published Ed25519 SSH host key; it
does not scan the network during apply. A run-after script then switches the
chezmoi source repo origin to `git@github.com:faviann/dotfiles.git`.

On a desktop, the last apply script switches the `#desktop` Home Manager
profile from the chezmoi source. The first switch downloads Chromium and takes
several minutes. A failed switch fails apply after the other scripts have run.
Without `nix` on `PATH`, the error names step 1. Fix the cause and rerun
`chezmoi apply` to retry the switch. After a successful switch, apply reruns it
only when `flake.lock`, `flake.nix`, `home/`, or `packages/` change.

Apply also clones `faviann/skillset` over HTTPS, without credentials, for the
agent skills, so that repository must stay public.

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

Chezmoi also recovers agent skills on every profile. If `~/repos/skillset`
is absent, it clones `faviann/skillset` and initializes its pinned submodule
sources; it never updates an existing checkout or its sources. Skillset's
reconciler then links the skills selected in its `profiles/workstation.txt`
into the supported harnesses. When `~/.agents/.skillset/profile` is missing,
the hook passes `--profile workstation`, which makes the reconciler record
`workstation` there; skillset defines only that profile, so desktops use it
too. Skill reconciliation runs during `chezmoi apply`, never during shell
login.

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

Claude Code on every machine uses the JES AI gateway at
`https://ai-gateway.jungleservices.net`. Chezmoi sets `env.ANTHROPIC_BASE_URL`
in `~/.claude/settings.json` to match. On the workstation and desktops, chezmoi
renders two credentials that sub2api issued, each from the Notes of one
Bitwarden item.

- `dotfiles/sub2api-gateway-token`: the token Claude Code authenticates to the
  JES AI gateway with, rendered to `~/.config/claude/gateway-token`. The
  `apiKeyHelper` in `~/.claude/settings.json` reads it.
- `dotfiles/sub2api-admin-key`: the sub2api admin API key, rendered to
  `~/.config/claude/gateway-admin-key`. The status line uses it to read each
  Claude account's 5-hour and weekly usage from the sub2api admin API at
  `gateway.ai.faviann.com`, which is separate from the gateway Claude Code uses.

Create both items before the first apply. Chezmoi sets only its own keys in
`~/.claude/settings.json` and leaves the rest of the file to Claude Code.

## Bitwarden artifact-server API Key Item

Agents publish to artifact-server at `artifact-server.public.faviann.com` and
use its MCP server for comments and visibility. On the workstation and
desktops, chezmoi renders one API key from the Notes of one Bitwarden item:

```text
dotfiles/artifact-server-api-key
```

The key goes to `~/.agents/artifact-server/api-key`, and every consumer reads
that file when it connects:

- The `publish-artifact` skill reads its path from
  `~/.config/faviann-skills/artifact-server.json`.
- Claude Code and Codex run `artifact-server-mcp-headers`, which prints the
  `Authorization` header from the file.
- OpenCode and pi read the file from their MCP configuration.

Apply sets only the `artifact-server` server in `~/.claude.json` and the
`artifact_server` server in `~/.codex/config.toml`, and owns
`~/.config/opencode/opencode.json` and `~/.pi/agent/mcp.json`. Other servers
and other keys in those two files stay, as do keys of the artifact-server entry
such as Codex's `enabled`. The entry's competing auth keys are removed so the
helper is the only auth: Claude Code's `headers`, and Codex's
`bearer_token_env_var`, `http_headers`, and `env_http_headers`. When the
managed keys change, as on the first apply, apply rewrites
`~/.codex/config.toml` as sorted TOML and drops its comments.

`~/.claude.json` is not a chezmoi target, because the workstation bind-mounts
that one file and chezmoi cannot replace a mount point. The
`register-claude-mcp-server` apply script edits it in place with `jq` and keeps
its key order. When the entry is current, the script does not write the file.
Without `jq`, as on a new workstation's first apply before Home Manager, the
script skips the entry with a notice, and the next apply adds it.

A corrupt `~/.codex/config.toml` stops the whole apply with a `fromToml` error
that names the file. A corrupt `~/.claude.json` fails the apply script with an
error that names the file. Fix the file, then apply again. OpenCode refuses to
start while the key file is missing.

To rotate the key, put the new key in the item's Notes. Then, on each machine
with Bitwarden unlocked, run `bw sync` so the CLI sees the edit, and run
`workstation-update --refresh-secrets` on the workstation or `chezmoi apply` on
a desktop. The harnesses need no other change. Apply fails unless the Notes
hold one key of printable ASCII characters on one line.

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

## GitHub Token

On the workstation and desktops, HTTPS git and `gh` use one classic personal
access token. Its Bitwarden item is `dotfiles/github-cli-token`, with the token
in Notes, and its live copy is `gh`'s own login. Git reaches it through
`gh auth git-credential`. `workstation-setup` logs `gh` in with it; on a
desktop you log in once by hand, as in [step 3](#3-bootstrap-over-https).

Create the token with an expiration date and these scopes:

- `repo`, with all of its sub-scopes
- `workflow`
- `write:packages`, which includes `read:packages`
- `read:org`, under `admin:org`; `gh` refuses to log in without it

If the organization enforces SAML single sign-on, authorize the token for it
under **Configure SSO**.

A classic token reaches every repository the account can, in the personal
account and in every organization. Fine-grained tokens can be narrower, but
each covers a single resource owner, cannot open a pull request from a
personal fork into a private organization repository, and cannot use GitHub
Packages. One classic token keeps both owners, fork pull requests, and
packages on one credential.

### Rotation and expiry

To replace the token, create the new token on GitHub and run:

```bash
github-token rotate
```

The command reads the token from standard input, without echoing it on a
terminal. It needs an unlocked Bitwarden session. It checks the token with
GitHub, refuses a token without an expiration date, writes the token to the
item's Notes, syncs Bitwarden, and logs `gh` in with it. An invalid token
leaves Bitwarden unchanged.

At the end of every run, `workstation-update` runs
`github-token check-expiry`. This prints a warning when the token expires
within 7 days or GitHub rejects it. The warning never fails the update.

## Day-to-Day Updates

After bootstrap, use `workstation-update` for routine maintenance on the
workstation. See the canonical
[workstation maintenance guidance](docs/workstation/maintenance.md) for source
guards, Bitwarden sessions, and failure recovery. Desktops use
`chezmoi update`. A desktop set up before the `desktop` Home Manager profile
existed needs Nix, as in [step 1](#1-install-chezmoi-and-bitwarden-cli), before
its next `chezmoi update`.

## Clone ServerManagementScripts

On the managed `workstation` LXC, run `workstation-setup` before this step so
Home Manager has installed `uv`. The vault passphrase is written by chezmoi
from Bitwarden before this step.

```bash
git clone git@github.com:faviann/ServerManagementScripts.git
cd ServerManagementScripts
./setup.sh
```

## Lifecycle Playbooks on the Workstation

Lifecycle playbooks exclude the host they run on. To apply them to the
workstation from the workstation, run this from a homelab-iac checkout:

```bash
./run.sh --include-controller
```

It applies the workstation's non-interrupting changes in place. Host-config
reconciliation, the package upgrade, and the reboot wait for the bootstrap
node's nightly run, or for its recipe in homelab-iac `docs/bootstrap-node.md`.
See homelab-iac's
[Deploying](https://github.com/faviann/homelab-iac/blob/main/docs/workstation-persistent-state.md#deploying)
for details.
