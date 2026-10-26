# Desktop toolchain

The `desktop` Home Manager profile gives every Ubuntu laptop and desktop the
tools an agent needs to publish to artifact-server and check the render. It
shares [`home/artifact-tools.nix`](../home/artifact-tools.nix) with the
workstation profile, so both machines get the same pins.

## What it installs

- `artifactserver`, the artifact-server CLI, pinned to the release tarball in
  [`packages/artifact-server.nix`](../packages/artifact-server.nix).
- Node.js, which the render check runs on.
- Chromium and DejaVu fonts, with `fonts.fontconfig.enable`, so a headless
  screenshot shows readable text.
- The fontconfig tools, such as `fc-list` and `fc-match`, to check which fonts
  the profile provides.

## How it applies

The desktop chezmoi profile runs
[`run_onchange_after_switch-home-manager.sh.tmpl`](../.chezmoiscripts/run_onchange_after_switch-home-manager.sh.tmpl)
on `chezmoi apply`. It runs `home-manager switch --impure` against the chezmoi
source, with the Home Manager CLI the flake pins. Nix must be installed first,
as in [BOOTSTRAP.md](../BOOTSTRAP.md#1-install-chezmoi-and-bitwarden-cli).

`home/desktop.nix` reads the user name and home directory from `USER` and
`HOME`, so the profile does not depend on one account. Pure evaluation, as in
`nix flake check`, sees empty values and uses `faviann` and `/home/faviann`.
Keep the module free of other impure inputs, because the switch would not
catch them. The `desktop-activation` check evaluates it purely.

## Updating the CLI

A new artifact-server release needs a manual edit of the version and sha256 in
`packages/artifact-server.nix`, the way `packages/moraine.nix` does it. Apply
reruns the switch when the file changes.
