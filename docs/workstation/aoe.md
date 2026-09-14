# Workstation Agent of Empires

Agent of Empires (`aoe`) is managed here as a user-level workstation tool, not
in the Ansible repo.

- **Install**: `.chezmoiscripts/run_once_install-aoe.sh.tmpl` uses the upstream
  installer until there is a clean Nix package path.
- **Bootstrap handoff**: after chezmoi installs AoE and Home Manager provides
  Node/npm and loads the user units, Home Manager runs `update-agent-tools`
  when any managed command is missing. The existing `workstation-setup` handoff
  therefore installs the full toolchain without a separate package-discovery or
  Ansible step.
- **SSH login**: `dot_bash_profile.tmpl` loads the Nix and Home Manager
  environment and opens a plain shell. Maintenance, tmux, and AoE are explicit
  commands.
- **Shell choice**: the workstation is bash-based; `.chezmoiignore` excludes
  fish config on the host named `workstation`, not on LXC guests generally.
- **Dashboard**: `home/workstation.nix` declares the `aoe-serve.service`,
  `aoe-lan-proxy.service`, and `aoe-lan-proxy.socket` user units. The socket
  exposes `0.0.0.0:4001` and proxies to the localhost service.
- **Reboot survival**: Ansible enables lingering for the workstation user with
  `loginctl enable-linger <user>`.

AoE's `acp.allow_agent_install` host-package setting remains off. Dotfiles owns
package installation; the AoE dashboard does not.

Routine updates run through [`workstation-update`](maintenance.md).
