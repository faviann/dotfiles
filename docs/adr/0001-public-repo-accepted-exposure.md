# Dotfiles is public, and its homelab surface is accepted exposure

This repository is being made public. The audit before the flip confirmed no
committed secret material — every secret is rendered at apply time from
Bitwarden — but the repository does disclose the workstation's operating
context: the git identity `faviann@gmail.com`, the `/home/faviann` path, the
Proxmox/LXC topology in `BOOTSTRAP.md` and `docs/`, and the internet-reachable
endpoints `collie.admin.faviann.com`, `lobu.admin.faviann.com`, and
`artifacts.public.faviann.com`, plus the LAN/VPN-only
`gateway.ai.faviann.com`. That disclosure is accepted rather than
redacted: `faviann/homelab-iac` is already public and already names the same
hosts and domain, so redacting here would buy inconsistency, not secrecy.

The two admin endpoints are protected by the admin forward-auth tier, and their
security rests on that tier rather than on hostname obscurity. The artifact
publisher is not: it sits on the public tier, which serves publications to
anyone holding the URL with no credentials at all. Naming that host therefore
discloses slightly more than naming an admin one, and it is still accepted —
the publisher exists to produce links that are handed to other people, so its
root is public by construction and nothing private is published into it. The
protection there is what gets written to `/ephemeral/workstation/artifacts`,
not who can reach it.

The `ai.faviann.com` tier, which serves the sub2api gateway that Claude Code
routes through, is reachable only from the LAN or VPN. Naming its host
discloses no more than homelab-iac does; its API needs a credential that
chezmoi renders from Bitwarden.

Git history and PR bodies also carry `10.1.x.x` homelab LAN addresses, such as
the portal at `10.1.0.2`, and the historical hostnames `aoe.local.faviann.com`
and `lobu.faviann.com`. These are accepted on the same grounds: homelab-iac
already publishes the same subnet (for example in
`inventory/host_vars/portal.yml`) and the `*.local.faviann.com` tier the `aoe`
host sat on, and `lobu.faviann.com` is a superseded name for the host
homelab-iac names as `lobu.admin.faviann.com`. Rewriting history is rejected
below.

## Consequences

Full git history is kept at the flip, because 106 of its commits reference
issue and PR numbers that remain live on GitHub, and squashing would sever
every one of those links.

A gitleaks scan before the flip, over all pushed history and every issue, PR
and comment, found no secrets.

Secret prevention going forward is GitHub's native secret scanning and push
protection, not a scanner wired into `nix flake check`. The realistic failure
mode is an accidental paste, which push protection catches at push time; a
check-time scanner would only catch it after the fact, at the cost of making
every local closeout run pull and run a scanner against a repository whose
secret discipline is structural.
