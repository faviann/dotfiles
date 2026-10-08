# Workstation herdr

[herdr](https://herdr.dev) is a terminal agent multiplexer.

- **Install**: `.chezmoiscripts/run_once_install-herdr.sh.tmpl` uses the
  upstream installer until there is a clean Nix package path. herdr is packaged
  in nixpkgs, but not in the pinned nixpkgs revision.
- **Updates**: manual `herdr update`, outside `workstation-update` and from a
  terminal outside Herdr with the service stopped.
- **Configuration**: `~/.config/herdr/config.toml` is optional and app-owned.
- **Integrations**: every `chezmoi apply` runs
  `.chezmoiscripts/run_after_install-herdr-integrations.sh.tmpl`, which
  installs the Claude Code, Codex, Pi, OMP, and OpenCode integrations that
  `herdr integration status` does not report as current. Herdr resumes an
  agent pane after a server restart only through its integration. A running
  agent loads a new integration only after it restarts. After `herdr update`,
  apply dotfiles to refresh outdated integrations.
- **Supervision**: Home Manager owns the foreground `herdr.service` under
  `default.target`, with user lingering for boot startup and a five-second
  failure-restart delay. Intentional stops remain stopped. Shutdown ends pane
  processes; restore from `~/.config/herdr/session.json` is reconstructive.

Use the [Herdr operations and recovery runbook](../runbooks/herdr.md) for
service control, safe updates, detached-server recovery, and restore limits.
