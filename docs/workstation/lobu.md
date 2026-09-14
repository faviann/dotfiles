# Workstation Lobu

[Lobu](https://lobu.admin.faviann.com) registers the workstation as a headless
device and polls the self-hosted control plane outward over HTTPS. The service
selects the stable `homelab` context independently of the globally active CLI
context and verifies its self-hosted origin before startup. No inbound route,
listener, or reverse-proxy configuration is involved.

- **Install**: Home Manager activation runs `scripts/lobu-bootstrap`, which
  installs `@lobu/cli` under `~/.local` when the CLI is missing. It preserves an
  existing executable and never authenticates.
- **Updates**: manual, outside `update-agent-tools`, and not version-pinned.
- **Credentials**: `lobu login` is interactive and human-owned. No token, device
  identifier, or generated credential is committed to this repository.
- **Interactive default**: shell sessions and the systemd user manager both
  export `LOBU_CONTEXT=homelab`, so an ad-hoc `lobu daemon` started from a
  terminal, Codex, or Herdr targets the self-hosted control plane instead of the
  globally selected CLI context. The hosted `lobu` context stays available and
  selectable, and an explicit `LOBU_CONTEXT` or `--context` still wins.
- **Supervision**: Home Manager owns `lobu.service` under `default.target`, with
  user lingering for boot startup. Failures restart after thirty seconds, a flat
  interval chosen so a permanent authentication fault retries against the
  control plane slowly without ever degrading recovery from an isolated one.
  Intentional stops remain stopped. Startup is gated on the presence of
  `~/.config/lobu/credentials.json`, so the unit stays inactive until login.

## Infrastructure prerequisites

Durable state under `~/.config/lobu` is owned by homelab-iac's persistent-home
mapping, not by dotfiles. That mapping
([homelab-iac#271](https://github.com/faviann/homelab-iac/pull/271)) must be
deployed before applying this configuration or running `lobu login`. The
self-hosted origin from
[homelab-iac#275](https://github.com/faviann/homelab-iac/issues/275) must also
be deployed and validated first.

Use the [Lobu bootstrap and recovery runbook](../runbooks/lobu.md) for rollout
order, first deployment, service control, re-authentication, manual upgrades,
and deferred live validation.
