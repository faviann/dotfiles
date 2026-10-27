# Desktop toolchain

The `desktop` Home Manager profile gives every Ubuntu laptop and desktop the
agent toolchain, the Herdr user service, and the tools an agent needs to
publish to artifact-server and check the render. It shares
[`home/agent-tools.nix`](../home/agent-tools.nix) and
[`home/artifact-tools.nix`](../home/artifact-tools.nix) with the workstation
profile, so both machines get the same pins.

## What it installs

- `artifactserver`, the artifact-server CLI, pinned to the release tarball in
  [`packages/artifact-server.nix`](../packages/artifact-server.nix).
- Node.js, which the render check runs on.
- `uv`, which homelab-iac runs Ansible with. Every profile is a homelab-iac
  controller, so `home/agent-tools.nix` installs `uv` on both profiles.
- Chromium and DejaVu fonts, with `fonts.fontconfig.enable`, so a headless
  screenshot shows readable text.
- The fontconfig tools, such as `fc-list` and `fc-match`, to check which fonts
  the profile provides.
- The `herdr.service` user unit, the same one the workstation runs
  ([herdr](workstation/herdr.md)).

## Agent toolchain

The switch runs `update-agent-tools` when `bun`, `codex`, `claude`, or
`opencode` is missing. The updater installs Bun, Codex, Claude Code, OpenCode,
and the
[declared Claude Code plugins](workstation/toolchain.md#claude-code-plugins).
Desktops do not get pi. To update the toolchain later, run
`update-agent-tools`.

The switch checks only that the commands exist. If `update-agent-tools` fails
after it installs them, for example while it installs a plugin, a new
`chezmoi apply` does not run it again. Fix the cause and run
`update-agent-tools`.

## How it applies

The desktop chezmoi profile runs
[`run_onchange_after_switch-home-manager.sh.tmpl`](../.chezmoiscripts/run_onchange_after_switch-home-manager.sh.tmpl)
on `chezmoi apply`. It runs `home-manager switch --impure` against the chezmoi
source, with the Home Manager CLI the flake pins. Nix must be installed first;
the [bootstrap command](../BOOTSTRAP.md#desktop) installs it.

`home/desktop.nix` reads the user name and home directory from `USER` and
`HOME`, so the profile does not depend on one account. Pure evaluation, as in
`nix flake check`, sees empty values and uses `faviann` and `/home/faviann`.
Keep the module free of other impure inputs, because the switch would not
catch them. The `desktop-activation` check evaluates it purely.

## Updating the CLI

A new artifact-server release needs a manual edit of the version and sha256 in
`packages/artifact-server.nix`, the way `packages/moraine.nix` does it. Apply
reruns the switch when the file changes.
