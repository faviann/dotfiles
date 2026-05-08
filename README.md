# dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io) + Bitwarden CLI.

See `BOOTSTRAP.md` for new machine setup.

## Workstation Home Manager

The `workstation` Home Manager flake installs user tooling for the Debian LXC
workstation: Node.js, `uv`, `gh`, `jq`, `ripgrep`, `fd`, `fzf`, Codex, Claude
Code, and Hermes. Hermes is installed from `github:NousResearch/hermes-agent`
as a normal non-NixOS package; provider credentials and runtime configuration
stay in `~/.hermes`.

Apply it through the Ansible-installed `workstation-setup` command, or build it
directly while developing dotfiles:

```bash
home-manager build --flake /home/aperture/repos/dotfiles#workstation
```

## Workstation Agent of Empires

Agent of Empires (`aoe`) is managed here as a user-level workstation tool, not in the Ansible repo.

- Install: `.chezmoiscripts/run_once_install-aoe.sh.tmpl` uses the upstream installer until there is a clean Nix package path.
- SSH launch: `dot_bashrc.tmpl` auto-attaches interactive SSH logins to tmux session `main`, or creates it running `aoe`. The hook only runs for SSH TTY sessions, skips remote commands, skips nested tmux, and waits for the workstation setup marker.
- Shell choice: the workstation LXC is bash-based; `.chezmoiignore` excludes fish config on LXC hosts.
- Dashboard: `home/workstation.nix` declares the `aoe-serve.service`, `aoe-lan-proxy.service`, and `aoe-lan-proxy.socket` user units. The socket exposes `0.0.0.0:4001` and proxies to the localhost service.
- Reboot survival: Ansible enables lingering for the workstation user with `loginctl enable-linger <user>`.
