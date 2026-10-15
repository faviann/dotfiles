# Workstation artifact publishing

The shared `publish-artifact` skill turns a completed file or prepared
directory tree into a browser URL. It discovers its mapping at
`~/.config/faviann-skills/artifacts.json` and rereads it on every publication;
without that file it keeps its local-file handoff.

Home Manager is the sole owner of that user file on the workstation. The
`artifactPublisherConfig` activation step in `home/workstation.nix` writes it
on every switch as a regular file, mode 600, from the declared mapping plus a
locally generated `gallery` token. It is not a configuration symlink, because
the token must stay out of git and out of the world-readable Nix store. The
agreed mapping is:

| Field | Value |
| --- | --- |
| `directory` | `/ephemeral/workstation/artifacts` |
| `baseUrl` | `https://artifacts.public.faviann.com` |

Beyond this file and its gallery token, dotfiles owns nothing here.
[homelab-iac#272](https://github.com/faviann/homelab-iac/issues/272) owns the
publishing root, its permissions, the static server, routing, storage and
retention. The endpoint is reachable from outside the LAN without VPN and
without credentials: the public tier has no forward-auth in front of it, so
anyone holding a publication's URL can read it. Publish only what you are
willing to hand to a stranger. Publications are retained until deliberate
cleanup and survive source removal and LXC rebuilds.

## Gallery

With `gallery` set, every publication rebuilds a page at
`https://artifacts.public.faviann.com/<gallery>/` that links every published
artifact. Like the artifacts, the page has no authentication: the token is the
only thing that keeps the list private. Treat the gallery URL as a secret and
never commit it or paste it anywhere public.

The token is 32 random hex characters in
`${XDG_STATE_HOME:-~/.local/state}/faviann-skills/artifact-gallery`, mode 600.
Activation creates it when it is missing and otherwise reuses it, so the URL
stays stable across switches. Activation never prints it. To read it:

```bash
jq -r .gallery ~/.config/faviann-skills/artifacts.json
```

To rotate the token:

1. Delete the state file and re-run activation. Call `home-manager switch`
   directly: `workstation-update` skips activation when the generation is
   unchanged.

   ```bash
   old="$(cat ~/.local/state/faviann-skills/artifact-gallery)"
   rm ~/.local/state/faviann-skills/artifact-gallery
   home-manager switch --flake ~/.local/share/chezmoi#workstation
   ```

2. Delete the old gallery directory. The old URL serves its last listing until
   you do.

   ```bash
   rm -r "/ephemeral/workstation/artifacts/$old"
   ```

3. Publish an artifact to build the gallery at the new URL.

## Ownership

The two values are a shared agreement between the repositories with no
automatic synchronization: change them in both, together. The publisher's
optional `FAVIANN_SKILLS_ARTIFACT_CONFIG` per-session override remains
available, and is deliberately not set as a global session variable.

Applying this configuration before the infrastructure is deployed installs a
mapping the publisher will accept but whose URLs do not resolve. Deploy
homelab-iac#272 first, then apply dotfiles, then verify a publication
end to end.
