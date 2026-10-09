# dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io) + Bitwarden CLI,
plus the `workstation` Home Manager flake that provisions the Debian LXC
workstation and its agent toolchain.

This is a personal repository: no support, no stability guarantees. It is not
directly reusable, because chezmoi renders secrets from the maintainer's
Bitwarden vault at apply time. It serves three machine profiles:
`workstation`, `bootstrap`, and `desktop`.

Setting up a new machine? Start with **[BOOTSTRAP.md](BOOTSTRAP.md)**.

## Common commands

| Command | Purpose |
| --- | --- |
| `workstation-update` | Routine maintenance: source update, chezmoi apply, Home Manager, agent tools. See [maintenance](docs/workstation/maintenance.md). |
| `workstation-setup` | Ansible-installed bootstrap/activation helper. |
| `update-agent-tools` | Targeted agent-toolchain repair only. |
| `dev-session ensure <project> <issue>` | Provision a coding worker for one GitHub issue. See [dev sessions](docs/workstation/dev-sessions.md). |
| `home-manager build --flake .#workstation` | Build the workstation profile while developing. |
| `nix flake check` | Full validation gate (ShellCheck + every Bats suite). |

## Repository layout

| Path | Contents |
| --- | --- |
| `dot_*`, `private_dot_*`, `dot_config/` | chezmoi source for home-directory targets |
| `.chezmoiscripts/` | chezmoi lifecycle scripts |
| `.chezmoiignore`, `.chezmoi.toml.tmpl` | chezmoi target inventory and data |
| `flake.nix`, `home/` | Home Manager flake and the `workstation` profile |
| `packages/` | Nix package definitions and patches |
| `scripts/` | Maintainer scripts (e.g. `update-dotnet-sdk`, `lobu-bootstrap`) |
| `tests/` | Bats behavioral suites |
| `docs/` | Documentation (see below) |

Everything under `docs/`, `tests/`, `scripts/`, `home/`, `.github/`, and the
flake files is repository-only and never applied to a home directory.

## Documentation

**Setup and conventions**

- [Bootstrap — new machine setup](BOOTSTRAP.md)
- [Repository conventions](docs/repository-conventions.md) — chezmoi inventory
  rules and how to run the tests
- [SSH key rotation](docs/ssh-key-rotation.md)
- [Domain glossary](CONTEXT.md) and [agent practices](AGENTS.md)

**Workstation components**

| Component | Document |
| --- | --- |
| Home Manager profile, agent toolchain, .NET policy | [toolchain](docs/workstation/toolchain.md) |
| `workstation-update`, recovery, login ownership | [maintenance](docs/workstation/maintenance.md) |
| herdr | [herdr](docs/workstation/herdr.md) |
| `dev-session` issue workers | [dev sessions](docs/workstation/dev-sessions.md) |
| Moraine | [moraine](docs/workstation/moraine.md) |
| Collie | [collie](docs/workstation/collie.md) |
| Lobu | [lobu](docs/workstation/lobu.md) |
| `publish-artifact` mapping | [artifact publishing](docs/workstation/artifact-publishing.md) |

**Operator runbooks**

- [Herdr operations and recovery](docs/runbooks/herdr.md)
- [Lobu bootstrap and recovery](docs/runbooks/lobu.md)
- [Collie operator runbook](docs/runbooks/collie.md)
