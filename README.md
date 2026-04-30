# dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io) + Bitwarden CLI.

See `BOOTSTRAP.md` for new machine setup.

## Workstation Agent of Empires

Agent of Empires (`aoe`) is managed here as a user-level workstation tool, not in the Ansible repo.

- Install: `.chezmoiscripts/run_once_install-aoe.sh.tmpl` uses the upstream installer because `aoe` is not currently available in the workstation's `mise registry`.
- SSH launch: `dot_bashrc.tmpl` auto-attaches interactive SSH logins to tmux session `main`, or creates it running `aoe`. The hook only runs for SSH TTY sessions, skips remote commands, skips nested tmux, and waits for the workstation setup marker.
- Shell choice: the workstation LXC is bash-based; `.chezmoiignore` excludes fish config on LXC hosts.
- Dashboard: `dot_config/systemd/user/aoe-serve.service` runs `aoe serve --host 127.0.0.1 --port 4000 --no-auth`; `dot_config/systemd/user/aoe-lan-proxy.socket` exposes `0.0.0.0:4001` and proxies to the localhost service. `.chezmoiscripts/run_after_enable-aoe-serve.sh.tmpl` reloads, enables, and reconciles both user units on each apply.
- Reboot survival: the workstation user must have lingering enabled once by root with `loginctl enable-linger <user>`.
