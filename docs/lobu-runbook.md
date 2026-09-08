# Lobu workstation bootstrap and recovery

## Deployment prerequisites

This requires the persistent-home mapping for `~/.config/lobu` implemented by
[homelab-iac#271](https://github.com/faviann/homelab-iac/pull/271). Confirm that
configuration is deployed on the workstation first.

It also requires the self-hosted Lobu control plane from
[homelab-iac#275](https://github.com/faviann/homelab-iac/issues/275). Do not apply
this Home Manager change, install or start Lobu, create its context, or run
`lobu login` until `https://lobu.faviann.com` has been deployed and validated.
Implementation and isolated repository tests do not deploy either prerequisite.

Dotfiles owns CLI installation and `lobu.service`; homelab-iac owns persistence.
Dotfiles never creates, copies, or manages Lobu credential/configuration files.
If state already exists before the mapping is deployed, stop the daemon and
follow the companion project's migration procedure before mounting over it.
Do not copy credentials into Git, Nix expressions, or shared logs.

## First deployment, after both prerequisites are ready

Apply the workstation configuration through the normal `workstation-setup` flow.
Home Manager installs `@lobu/cli@latest` under `~/.local` when the CLI is missing,
using its Node/npm runtime with engine compatibility enforced. It preserves an
existing executable and never authenticates during activation.

The enabled service skips startup while credentials are absent. It also has a
read-only precondition that requires the stable `homelab` context to resolve to
the self-hosted origin, so applying the generation cannot create that context or
start the daemon against an incomplete or incorrect installation. `homelab` does
not have to be the CLI's active context. In an interactive workstation terminal,
run:

```bash
lobu context add homelab --url https://lobu.faviann.com
lobu login --context homelab
systemctl --user start lobu.service
systemctl --user status lobu.service --no-pager
journalctl --user -u lobu.service -n 50 --no-pager
```

Complete the browser approval requested by login. The service always passes
`LOBU_CONTEXT=homelab` to the daemon and verifies that context's origin before
startup, so it cannot follow the globally active context or fall back to Lobu
Cloud. On first start, Lobu registers a headless device using the hostname. Later
starts reuse the `homelab` context's cached identity and worker credential from
`~/.config/lobu/devices/`. Keep both the persisted configuration root and the
context name unchanged across restarts and LXC rebuilds. Changing the active CLI
context does not affect the supervised daemon. Agent-session identity detection
is disabled. The service uses the ordinary home directory, including its
persisted mapping, without managing that mapping itself.

No inbound route or listening socket is configured. The daemon polls outward.
Herdr routing and ChatGPT invocation experiments are separate work.

## Operation and recovery

```bash
systemctl --user restart lobu.service
systemctl --user stop lobu.service
systemctl --user start lobu.service
```

Unexpected failures restart after thirty seconds, every time. The interval is
deliberately flat, so recovery from an isolated failure takes the same thirty
seconds whether the service started yesterday or has been running for months.
An intentional stop stays stopped until a start/restart or subsequent boot.
Existing lingering enables boot startup without an SSH login.

The credentials-file condition is an initial-setup gate, not a credential
validity check. Stale or invalid credentials fail every start, and systemd's
start rate limiter does not trip at this interval, so the daemon retries
indefinitely at one attempt per thirty seconds. That is a low enough rate to
leave running, but it does not self-heal: a repeating start failure in the
journal means re-authenticate, not wait.

For expired login credentials, stop the service, run
`lobu login --force --context homelab`, then start the service and inspect its
status. A revoked worker credential is different: upstream deliberately refuses
to silently replace it. Preserve device state and follow the installed release's
explicit re-pair procedure; do not delete the entire configuration directory as a
generic fix. Confirm the device identity and any server-side attachments after
re-pairing.

See the [upstream daemon implementation](https://github.com/lobu-ai/lobu/blob/main/packages/cli/src/commands/daemon.ts)
for authentication and worker identity behavior.

## Manual upgrades

Lobu is outside `update-agent-tools` and is not version-pinned. Finish any active
device work before upgrading. Record `lobu --version`, then run:

```bash
systemctl --user stop lobu.service
npm install --global --prefix "$HOME/.local" --engine-strict @lobu/cli@latest
lobu --version
systemctl --user start lobu.service
systemctl --user status lobu.service --no-pager
```

If installation fails, keep the service stopped until the CLI is repaired. To
return to the recorded version, install `@lobu/cli@<previous-version>` with the
same command. Package rollback does not imply credential/state rollback.

## Live acceptance checks (deferred until deployment)

- Confirm one supervised daemon and the expected device in the self-hosted Lobu
  control plane.
- Stop it, wait longer than thirty seconds, and verify it remains inactive; start it.
- With no device work running, kill only the service's main process using
  `systemctl --user kill --kill-whom=main --signal=SIGKILL lobu.service`.
  Confirm a replacement main PID and an increased `NRestarts` using
  `systemctl --user show lobu.service -p MainPID -p NRestarts`.
- At a planned reboot, verify startup through the lingering manager using boot
  journal timestamps and `loginctl show-user faviann -p Linger`.
- Coordinate LXC rebuild validation with homelab-iac: verify the persistent mount
  and the same device identity after recreation. Record only identity/status,
  never credential-file contents.
