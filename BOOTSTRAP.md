# Bootstrap - New Machine Setup

A desktop needs one command and your Bitwarden sign-in. The `workstation` LXC
has its own path: homelab-iac provisions it, and you finish it with
`workstation-setup`.

## Machine Profiles

`chezmoi init` derives the machine profile from the hostname, without a
prompt, and `.chezmoiignore` applies only that profile's targets:

| Hostname | Profile | Gets | Bitwarden items |
| --- | --- | --- | --- |
| `workstation` | `workstation` | Everything below except fish and the `desktop` Home Manager profile, plus `workstation-update`, `dev-session`, the pi configuration, and the Collie client CA | All nine items below: `dotfiles/workstation-ssh-key`, `dotfiles/proxmox-lxc-ssh-key`, `dotfiles/ansible-vault-pass`, `dotfiles/sub2api-gateway-token`, `dotfiles/sub2api-admin-key`, `dotfiles/artifact-server-api-key`, `dotfiles/opencode-api-key`, `dotfiles/collie-ca`, and `dotfiles/github-cli-token` |
| anything else | `desktop` | Bash config, global git ignore, git identity and signing, SSH key and config, the homelab-iac controller files, `github-token` rotation and the `gh` login, agent setup, `update-agent-tools`, fish, the `desktop` Home Manager profile, and the homelab WireGuard tunnel | `dotfiles/workstation-ssh-key`, `dotfiles/proxmox-lxc-ssh-key`, `dotfiles/ansible-vault-pass`, `dotfiles/sub2api-gateway-token`, `dotfiles/sub2api-admin-key`, `dotfiles/artifact-server-api-key`, `dotfiles/opencode-api-key`, and `dotfiles/github-cli-token`, plus the optional `dotfiles/wireguard/<hostname>` |

Apply fails until every Bitwarden item in the profile's row exists, except
`dotfiles/github-cli-token`, whose `gh` login only warns, and the optional
[WireGuard item](#bitwarden-wireguard-item). Create them before the
first apply. On an existing machine, create a new item before
the `chezmoi update` or `workstation-update` that starts to read it.

Every profile is a homelab-iac controller. It gets the Ansible controller key
pair and vault passphrase, `uv`, and a homelab-iac clone. The workstation also
gets the Collie client CA.

Desktops get agent configuration and the `desktop` Home Manager profile, which
installs the artifact-server publishing toolchain: the `artifactserver` CLI,
Node.js, Chromium, and the DejaVu fonts. The profile also runs the Herdr user
service, and its switch hands off to `update-agent-tools` to install the
[agent toolchain](docs/workstation/toolchain.md#agent-toolchain) without pi.
Apply installs the profile, as in [what apply sets up](#what-apply-sets-up);
see the [desktop toolchain](docs/desktop-toolchain.md).

Each secret has one Bitwarden item, and apply renders every copy from it. To
rotate a secret, change its item and run `bw sync`. Then run
`workstation-update --refresh-secrets` on the workstation or `chezmoi apply` on
a desktop. The SSH key and the GitHub token have their own procedures, linked
from their sections.

## Desktop

On a stock Ubuntu 24.04 desktop or laptop, run this as your own user:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/faviann/dotfiles/main/bootstrap.sh)
```

The command uses `wget` because a stock Ubuntu desktop has no `curl`. Do not
pipe the script into `bash`. `sudo` and Bitwarden prompt on the terminal, so
standard input must stay the terminal.

[`bootstrap.sh`](bootstrap.sh) runs these steps in order:

1. Install `git`, `curl`, `jq`, `gh`, and `unzip` with `apt-get`.
2. Install chezmoi in `~/.local/bin`, unless `chezmoi` is already on `PATH`.
3. Install the Bitwarden CLI in `~/.local/bin`, unless `bw` is already on
   `PATH`. The script uses Bitwarden's release binary, not the snap, so it also
   works in a container or in WSL.
4. Sign in to Bitwarden and unlock the vault. Apart from the `sudo` password,
   this is the one step that needs you: `bw` asks for your email, master
   password, and two-step login code.
   The session stays in the script's environment and ends with it.
5. Install Determinate Nix and load it into the script's environment, so apply
   finds `nix` without a new shell. On a machine without systemd, the script
   installs Nix without an init system and starts the Nix daemon itself.
6. Run `chezmoi init` for this repository, then `chezmoi apply`.

The script pins chezmoi, the Bitwarden CLI, and the Determinate Nix installer,
and checks each download against its SHA-256 sum. It stops with an error on the
`workstation` host, on a CPU other than x86_64, and when you run it as root.

Create the profile's [Bitwarden items](#machine-profiles) before you run the
command. If a step fails, fix the cause and run the same command again. It
skips each step that is already done. Apply runs on every run, and it changes
only what differs. After a container restart, run the command again to restart
the Nix daemon.

When the script finishes, it prints the remaining manual steps:

- Open a new terminal, so that your shell finds Nix and `~/.local/bin`.
- Run `codex login` to sign in to Codex on this machine.

To bootstrap from a branch, set `DOTFILES_REF` to the branch name and fetch the
script from the same branch:

```bash
DOTFILES_REF=<branch> bash <(wget -qO- https://raw.githubusercontent.com/faviann/dotfiles/<branch>/bootstrap.sh)
```

If the branch does not exist, the command prints nothing and exits without an
error, because `wget -qO-` hides the 404. Check the branch name.

`DOTFILES_REF` applies only to the first `chezmoi init`. When the chezmoi
source already exists, the script applies that checkout as it is. The script
stops when the existing source is not a complete clone of this repository, for
example another repository or a clone that was interrupted. Move the directory
aside, then run the command again.

## Workstation

The Ansible-managed `workstation` LXC comes with Determinate Nix and a
`workstation-setup` helper. `bootstrap.sh` refuses to run there. Run these
steps in order:

1. Install chezmoi and the Bitwarden CLI:

   ```bash
   sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin
   sudo snap install bw
   ```

2. Unlock Bitwarden. Keep the session token in your shell only, and do not
   paste or commit secrets:

   ```bash
   bw login                                  # first time only
   export BW_SESSION=$(bw unlock --raw)
   ```

3. Initialize and apply the dotfiles. The first checkout uses HTTPS, so the
   machine does not need an SSH key before chezmoi renders one from Bitwarden.
   Run apply as a separate command. Chezmoi reads its write mode at startup,
   before `init` generates the configuration, and the workstation needs the
   [in-place writes](docs/workstation/maintenance.md#in-place-writes) that the
   configuration sets:

   ```bash
   chezmoi init https://github.com/faviann/dotfiles.git
   chezmoi apply
   ```

4. Run the `workstation-setup` helper with Bitwarden still unlocked:

   ```bash
   workstation-setup
   ```

   It runs `chezmoi init/update`, applies the `#workstation` Home Manager
   flake, authenticates GitHub CLI from the `dotfiles/github-cli-token`
   Bitwarden item, and validates the expected tools. Home Manager installs the
   base tools, loads the user units, and hands off to `update-agent-tools` if
   any managed agent command is missing. This installs the
   [complete agent toolchain](docs/workstation/toolchain.md) without another
   package-discovery or Ansible step.

The bootstrap handoff is part of `workstation-setup`, not SSH login or a
background schedule.

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

## What apply sets up

After apply, chezmoi writes `~/.ssh/id_ed25519`, `~/.ssh/id_ed25519.pub`,
`~/.ssh/known_hosts`, the
[Claude Code gateway](#bitwarden-claude-code-gateway-items) credentials in
`~/.config/claude/`, the
[artifact-server API key](#bitwarden-artifact-server-api-key-item), the
[OpenCode API key](#bitwarden-opencode-api-key-item), the
[Ansible controller key pair](#bitwarden-ansible-controller-key-item) in
`~/.ansible/ssh/`, and the
[vault passphrase](#bitwarden-ansible-vault-passphrase-item) in
`~/.ansible/vault-pass`. The workstation also gets the
[Collie client CA](#bitwarden-collie-client-ca-item) in `~/.ansible/collie-ca/`.
Dotfiles pins GitHub's published Ed25519 SSH host key; it
does not scan the network during apply. A run-after script then switches the
chezmoi source repo origin to `git@github.com:faviann/dotfiles.git`.

On a desktop, the last apply script before the homelab tunnel switches the
`#desktop` Home Manager profile from the chezmoi source. The first switch
downloads Chromium and takes several minutes. A failed switch fails apply after
the other scripts have run, and the tunnel import waits for the next apply.
Without `nix` on `PATH`, the error names the bootstrap command. Fix the cause
and rerun the bootstrap command, or `chezmoi apply`, to retry the switch. After
a successful switch, apply reruns it only when `flake.lock`, `flake.nix`,
`home/`, or `packages/` change.

Apply also clones `faviann/skillset` for the agent skills and
`faviann/homelab-iac` into `~/repos/homelab-iac`. Both clones use HTTPS without
credentials, so both repositories must stay public. Once
`~/repos/homelab-iac` exists, apply never touches it, so update it yourself.
If the homelab-iac clone fails, apply prints a warning and the next apply
retries it.

On a desktop with a [WireGuard item](#bitwarden-wireguard-item), the last
apply script imports the homelab tunnel into NetworkManager.

Apply also logs `gh` in with the [GitHub token](#github-token). On a new
workstation, `gh` is not installed during the first apply, so
`workstation-setup` logs it in during
[step 4](#workstation).

Chezmoi also recovers agent skills on every profile. If `~/repos/skillset`
is absent, it clones `faviann/skillset` and initializes its pinned submodule
sources; it never updates an existing checkout or its sources. Skillset's
reconciler then links the skills selected in its `profiles/workstation.txt`
into the supported harnesses. When `~/.agents/.skillset/profile` is missing,
the hook passes `--profile workstation`, which makes the reconciler record
`workstation` there; skillset defines only that profile, so desktops use it
too. Skill reconciliation runs during `chezmoi apply`, never during shell
login.

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

## Bitwarden Ansible Vault Passphrase Item

homelab-iac decrypts its Ansible vault with `~/.ansible/vault-pass`. Chezmoi
renders the file from the Notes of one Bitwarden item:

```text
dotfiles/ansible-vault-pass
```

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
`~/.claude/settings.json` and leaves the rest of the file to Claude Code. When
the file already holds those values, apply leaves it as written. Claude Code
and Herdr write the file in their own key order, so their edits do not make
`chezmoi verify` fail.

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
- OpenCode, and pi on the workstation, read the file from their MCP
  configuration.

Apply sets only the `artifact-server` server in `~/.claude.json` and the
`artifact_server` server in `~/.codex/config.toml`, plus the Codex
[agent defaults](docs/workstation/toolchain.md#agent-defaults), and owns
`~/.config/opencode/opencode.json` and, on the workstation,
`~/.pi/agent/mcp.json`. Other servers
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
error that names the file. The failure stops the scripts that sort after it,
`switch-chezmoi-origin-to-ssh` and, on desktops, `switch-home-manager`. Fix the
file, then run `chezmoi apply` again to finish them. If the script's write fails
midway, for example on a full disk, it keeps the complete new content in a
temporary file and the error names it. Copy that file over `~/.claude.json`.
OpenCode refuses to start while the key file is missing.

To rotate the key, put the new key in the item's Notes. Then, on each machine
with Bitwarden unlocked, run `bw sync` so the CLI sees the edit, and run
`workstation-update --refresh-secrets` on the workstation or `chezmoi apply` on
a desktop. The harnesses need no other change. Apply fails unless the Notes
hold one key of printable ASCII characters on one line.

## Bitwarden OpenCode API Key Item

OpenCode authenticates to its `opencode` provider with an API key. On the
workstation and desktops, chezmoi renders the key from the Notes of one
Bitwarden item:

```text
dotfiles/opencode-api-key
```

Apply sets the `opencode` entry of `~/.local/share/opencode/auth.json` to the
key and keeps every other entry, such as the logins OpenCode stores for other
providers. A key that `opencode auth login` stores for the `opencode` provider
is replaced on the next apply. Apply fails unless the Notes hold one key of
printable ASCII characters on one line.

To rotate the key, put the new key in the item's Notes. Then, on each machine
with Bitwarden unlocked, run `bw sync`, and run
`workstation-update --refresh-secrets` on the workstation or `chezmoi apply` on
a desktop.

## Bitwarden Collie Client CA Item

Traefik lets the phone reach `collie-mobile.admin.faviann.com` only with a
client certificate that the Collie client CA signed. On the workstation,
chezmoi renders the CA from one Bitwarden item, so the CA survives an LXC
rebuild:

```text
dotfiles/collie-ca
```

The item must contain:

- Notes: the PEM private key for `~/.ansible/collie-ca/ca.key`
- Custom field `certificate`: the PEM certificate for
  `~/.ansible/collie-ca/ca.crt`, with or without its line breaks. Bitwarden's
  apps drop line breaks from custom fields, and apply restores them.

Apply sets the directory to mode `700` and both files to mode `600`. Apply
fails unless the Notes hold a PEM private key with its line breaks and the
field holds a PEM certificate, so a malformed item cannot replace the only copy
of the CA. Chezmoi does not manage `ca.srl` or the
`phone.*` files. To regenerate them, follow "Reissue the phone certificate" in
homelab-iac's `stacks/portal/traefik3/README.md`.

After you create the item, and before the first apply that renders it, check
the item against the files on the workstation:

```bash
chezmoi verify ~/.ansible/collie-ca
```

Exit status 0 means the item matches the files. The command prints no file
contents. Do not use `chezmoi diff` for this check: it does not descend into
the directory, so it prints nothing even when the item differs.

To rotate the CA, follow "Rotate the CA" in homelab-iac's
`stacks/portal/traefik3/README.md`. It writes a new `ca.key` and `ca.crt` in
`~/.ansible/collie-ca/`. Put the key in the item's Notes and the certificate in
its `certificate` field, and run `bw sync` before the next
`workstation-update`. Otherwise that apply restores the old CA without asking,
and the new key is lost.

## Bitwarden WireGuard Item

A desktop reaches the homelab through the Firewalla's WireGuard server. Each
machine has its own Firewalla WireGuard profile, in one Bitwarden secure note
named after the machine's hostname:

```text
dotfiles/wireguard/<hostname>
```

The item must contain:

- Notes: the whole profile as the Firewalla app exports it, with one
  `[Interface]` section and one `[Peer]` section

The item is optional. Create it only for a desktop that needs the tunnel, such
as a laptop. Without it, apply prints a notice and continues, and the machine
gets no tunnel. The workstation never reads the item. Deleting the item does
not remove a connection that apply already imported. To remove it, run
`sudo nmcli connection delete wg-homelab`.

Apply imports the profile into NetworkManager as the `wg-homelab` connection.
NetworkManager starts the connection at once, at boot, and on every network.
Before the import, apply changes the profile in two ways, so the homelab is
reachable whatever the profile routes:

- It adds `10.1.0.0/18` and `10.0.0.2` to the peer's `AllowedIPs`.
  NetworkManager routes each range through the tunnel. Other traffic follows
  the profile: the Firewalla's default `AllowedIPs = 0.0.0.0/0` sends all
  traffic through the tunnel.
- It replaces the profile's `DNS` with `10.1.0.1`, for `faviann.vms` and
  `proxmox.lan` names only. With systemd-resolved, as on stock Ubuntu, other
  names use the DNS server of the network that the machine is on, even on a
  full tunnel. On untrusted Wi-Fi, that network's resolver sees every other
  name the machine looks up, which the Firewalla profile's own `DNS` would have
  kept inside the tunnel.

On a full tunnel, a profile that cannot connect cuts the machine's internet as
soon as NetworkManager starts it. Apply imports the tunnel last, so the other
apply steps finish first. To get internet back, run
`sudo nmcli connection down wg-homelab`. NetworkManager starts the connection
again at the next boot, so fix the item and run `chezmoi apply`, or delete the
connection.

At home on the homelab LAN, the `10.1.0.0/18` route still sends homelab traffic
through the tunnel. Whether that works depends on the Firewalla accepting a
tunnel from inside its own LAN on its public endpoint, which is unproven. Run
the first apply with a new item at home. If the homelab is then unreachable,
`sudo nmcli connection down wg-homelab` restores it.

The import needs root, so apply runs `sudo nmcli`, and `sudo` can ask for your
password. Apply gives the profile to NetworkManager in a file that only you can
read, and deletes the file after the import. NetworkManager keeps the private
key in a root-only file.

Apply imports the profile again only when the item changes or the connection
it imported last no longer uses the `wg-homelab` interface. Renaming that
connection in the GUI does not trigger an import. Before an import, apply
deletes every connection on that interface, including one renamed in the GUI
or created by hand. If the Notes do
not hold one `[Interface]` and one `[Peer]` section, apply fails and keeps the
old connection. If NetworkManager rejects the new profile, apply fails after
it removes the old connection. Fix the item and run `chezmoi apply` again.

To rotate the key, create a new profile for the machine on the Firewalla, put
it in the item's Notes, and run `bw sync` and `chezmoi apply`.

To check the connection and the DNS routing, run:

```bash
nmcli -f connection.autoconnect,ipv4.dns,ipv4.dns-search connection show wg-homelab
resolvectl status wg-homelab
```

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
`gh auth git-credential`. On every profile, `chezmoi apply` logs `gh` in with
the token when Bitwarden is unlocked and `gh` does not already hold it. A
failed login prints a warning and does not fail the apply. On a new
workstation, `gh` is not installed during the first apply, so the login in
`workstation-setup` covers bootstrap.

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

The other machines log in with the new token on their next apply with
Bitwarden unlocked. On each one, run `bw sync`, then run
`workstation-update --refresh-secrets` on the workstation or `chezmoi apply` on
a desktop.

At the end of every run, `workstation-update` runs
`github-token check-expiry`. This prints a warning when the token expires
within 7 days or GitHub rejects it. The warning never fails the update.

## Day-to-Day Updates

After bootstrap, use `workstation-update` for routine maintenance on the
workstation. See the canonical
[workstation maintenance guidance](docs/workstation/maintenance.md) for source
guards, Bitwarden sessions, and failure recovery. Desktops use
`chezmoi update`, and `update-agent-tools` for the agent toolchain. A desktop
set up before the `desktop` Home Manager profile existed needs Nix before its
next `chezmoi update`. Run the [bootstrap command](#desktop) once to install it.

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
