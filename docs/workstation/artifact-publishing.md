# Workstation artifact publishing

The shared `publish-artifact` skill turns a completed file or prepared
directory tree into a browser URL. It discovers its mapping at
`~/.config/faviann-skills/artifacts.json` and rereads it on every publication;
without that file it keeps its local-file handoff.

Home Manager is the sole owner of that user file on the workstation. It is
declared in `home/workstation.nix` and installed as a normal configuration
symlink, which the publisher's discovery accepts. The agreed mapping is:

| Field | Value |
| --- | --- |
| `directory` | `/ephemeral/workstation/artifacts` |
| `baseUrl` | `https://artifacts.public.faviann.com` |

Dotfiles owns nothing else here.
[homelab-iac#272](https://github.com/faviann/homelab-iac/issues/272) owns the
publishing root, its permissions, the static server, routing, storage and
retention. The endpoint is reachable from outside the LAN without VPN and
without credentials: the public tier has no forward-auth in front of it, so
anyone holding a publication's URL can read it. Publish only what you are
willing to hand to a stranger. Publications are retained until deliberate
cleanup and survive source removal and LXC rebuilds.

The two values are a shared agreement between the repositories with no
automatic synchronization: change them in both, together. The publisher's
optional `FAVIANN_SKILLS_ARTIFACT_CONFIG` per-session override remains
available, and is deliberately not set as a global session variable.

Applying this configuration before the infrastructure is deployed installs a
mapping the publisher will accept but whose URLs do not resolve. Deploy
homelab-iac#272 first, then apply dotfiles, then verify a publication
end to end.
