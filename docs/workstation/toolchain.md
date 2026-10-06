# Workstation toolchain

The `workstation` Home Manager flake installs user tooling for the Debian LXC
workstation. Build it directly while developing dotfiles, or apply it through
the Ansible-installed `workstation-setup` command:

```bash
home-manager build --flake .#workstation
```

## Base tools

The .NET 10 LTS SDK, Node.js/npm, `uv`, `gh`, `jq`, `ripgrep`, `fd`, `fzf`,
Hermes, and Moraine. Hermes is installed from `github:NousResearch/hermes-agent`
as a normal non-NixOS package; provider credentials and runtime configuration
stay in `~/.hermes`.

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
- Oh My Pi (`@oh-my-pi/pi-coding-agent`)

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

Pi and Oh My Pi intentionally coexist while OMP is evaluated as a separate
harness. The `pi` command continues to use `~/.pi`; the distinct `omp` command
uses its own default `~/.omp` state. OMP does not replace Pi.

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
