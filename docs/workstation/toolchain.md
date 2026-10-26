# Workstation toolchain

The `workstation` Home Manager flake installs user tooling for the Debian LXC
workstation. Build it directly while developing dotfiles, or apply it through
the Ansible-installed `workstation-setup` command:

```bash
home-manager build --flake .#workstation
```

## Base tools

The .NET 10 LTS SDK, Node.js/npm, `uv`, `gh`, Azure CLI (`az`), `jq`,
`ripgrep`, `fd`, `fzf`, Hermes, Moraine, and Tailscale with the
`with-jes-gateway` wrapper ([tailscale](tailscale.md)). The workstation also
gets the publishing toolchain it shares with desktops: the `artifactserver`
CLI, Chromium, the DejaVu fonts, and the fontconfig tools
([desktop toolchain](../desktop-toolchain.md)). Hermes is installed from
`github:NousResearch/hermes-agent` as a normal non-NixOS package; provider
credentials and runtime configuration stay in `~/.hermes`.

Home Manager provides Node/npm and writes the npm prefix as
`/home/faviann/.local`; all npm-managed commands resolve from `~/.local/bin`.

## Agent toolchain

Dotfiles and the complete agent toolchain are maintained through one
operator-facing command:

```bash
workstation-update
```

The managed unit contains:

- the Bun runtime the harnesses execute under
- the standalone Codex CLI (`@openai/codex`)
- Claude Code (`@anthropic-ai/claude-code`)
- Pi (`@earendil-works/pi-coding-agent`)
- OpenCode (`opencode-ai`)

[Bun's upstream installer](https://bun.sh/install) supplies its latest runtime,
selects a CPU-compatible build (including baseline x64), and replaces the binary
by renaming it into `~/.local/bin`. npm owns package versions, dependency
resolution, integrity checks, and installation. There is no repository-owned
release discovery or version cache.

Before replacing executables, an npm dry run with
[`--engine-strict`](https://docs.npmjs.com/cli/v11/using-npm/config/#engine-strict)
checks package compatibility with Home Manager's Node runtime. This handles npm's
supported engine ranges, including transitive dependencies. npm does not enforce
Bun engines: the updater installs the latest Bun and runs Bun and the Bun-using
harnesses to confirm they start. If an upstream package needs a newer Node,
update the nixpkgs input; the failed preflight leaves installed tools unchanged.

## Claude Code plugins

`update-agent-tools` declares the Claude Code plugins every machine gets:

- `pstack@pstack-claude`
- `codex@openai-codex`
- `frontend-design@anthropic-plugin-directory`
- `skill-creator@anthropic-plugin-directory`

It also declares the two marketplaces these plugins come from beyond the
built-in `anthropic-plugin-directory`: `pstack-claude` from GitHub
`michael-denyer/pstack-claude`, and `openai-codex` from GitHub
`openai/codex-plugin-cc`. Each run adds a declared marketplace that
`claude plugin marketplace list` does not show. It then installs each declared
plugin that `claude plugin list` does not show and updates the others. A
failure names the marketplace or plugin. Plugins that you install by hand stay
installed and are not updated. Declaring a plugin in `~/.claude/settings.json`
does not install it, so chezmoi does not manage plugins there.

## Agent defaults

Agents on every machine run without approval prompts or a sandbox. Chezmoi sets
`permissions.defaultMode = "bypassPermissions"` and
`skipDangerousModePermissionPrompt = true` in `~/.claude/settings.json`. The
rest of `permissions`, such as `permissions.allow`, stays as Claude Code wrote
it.

Chezmoi pins these keys in `~/.codex/config.toml`:

- `approval_policy = "never"`
- `sandbox_mode = "danger-full-access"`
- `agents.max_concurrent_threads_per_session = 24`
- `personality = "pragmatic"`

Apply leaves the file byte for byte unchanged when every managed key is
current. Otherwise it rewrites the file as sorted TOML and drops its comments.

## .NET SDK policy

The .NET policy floats within major 10 while each published workstation
generation remains reproducible. A dedicated `dotnet-nixpkgs` flake input
isolates the SDK from the workstation's other Nix packages. The daily and
manually dispatchable `Update .NET 10 SDK` GitHub workflow invokes
`scripts/update-dotnet-sdk`, which advances only that input, rejects a major
change or downgrade, executes the SDK, builds the real Home Manager activation
package, and runs `nix flake check`. A validated version change is published
and merged through one automation PR; a failure leaves `main` on its last
known-good SDK.

For maintainer recovery or an on-demand refresh, run
`scripts/update-dotnet-sdk` from a clean canonical checkout.
