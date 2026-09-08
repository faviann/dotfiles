# Lobu workstation bootstrap and recovery

## Deployment prerequisite

This requires the persistent-home mapping for `~/.config/lobu` implemented by
[homelab-iac#271](https://github.com/faviann/homelab-iac/pull/271). Confirm that
configuration is deployed on the workstation before applying this Home Manager
change, installing or starting Lobu, or running `lobu login`. Implementation and
isolated repository tests do not deploy it.

Dotfiles owns CLI installation and `lobu.service`; homelab-iac owns persistence.
Dotfiles never creates, copies, or manages Lobu credential/configuration files.
If state already exists before the mapping is deployed, stop the daemon and
follow the companion project's migration procedure before mounting over it.
Do not copy credentials into Git, Nix expressions, or shared logs.

## First deployment, after persistence is ready

Apply the workstation configuration through the normal `workstation-setup`
flow. Home Manager installs `@lobu/cli@latest` under `~/.local` when the CLI is
missing, using its Node/npm runtime with engine compatibility enforced. It
preserves an existing executable and never authenticates during activation.

The enabled service skips startup while `~/.config/lobu/credentials.json` is
absent. In an interactive workstation terminal, run:

```bash
lobu login
systemctl --user start lobu.service
systemctl --user status lobu.service --no-pager
journalctl --user -u lobu.service -n 50 --no-pager
```

Complete the browser approval requested by login. The service targets the managed
`https://app.lobu.ai` installation; authenticate against that installation if you
have changed your CLI's active context. On first start, Lobu registers a headless
device using the hostname; later starts reuse its cached identity and worker
credential from `~/.config/lobu/devices/`. Agent-session identity detection is
disabled. The service uses the ordinary home directory, including its persisted
mapping, without managing that mapping itself.

No inbound route or listening socket is configured. The daemon polls outward.
Herdr routing and ChatGPT invocation experiments are separate work.

## Operation and recovery

```bash
systemctl --user restart lobu.service
systemctl --user stop lobu.service
systemctl --user start lobu.service
```

The first unexpected failure restarts after five seconds, and each consecutive
failure backs off further, up to five minutes. A single restart therefore looks
immediate, while a persistent fault settles into a slow retry instead of hammering
the control plane. A successful start resets the delay. An intentional stop stays
stopped until a start/restart or subsequent boot. Existing lingering enables boot
startup without an SSH login. The credentials-file condition is an initial-setup
gate, not a credential validity check: stale or invalid credentials fail every
start, so treat a climbing restart delay as a signal to re-authenticate rather
than to wait.

For expired login credentials, stop the service, run `lobu login --force` for the
managed installation, then start the service and inspect its status. If the log
names a context, pass `--context <name>` to login. A revoked worker credential is
different: upstream deliberately refuses to silently replace it. Preserve device
state and follow the installed release's explicit re-pair procedure; do not delete
the entire configuration directory as a generic fix. Confirm the device identity
and any server-side attachments after re-pairing.

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

- Confirm one supervised daemon and the expected device in Lobu's control plane.
- Stop it, wait longer than five seconds, and verify it remains inactive; start it.
- Confirm the backoff is in effect with
  `systemctl --user show lobu.service -p RestartSec -p RestartSteps -p RestartMaxDelayUSec`.
- With no device work running, kill only the service's main process using
  `systemctl --user kill --kill-whom=main --signal=SIGKILL lobu.service`.
  Confirm a replacement main PID and an increased `NRestarts` using
  `systemctl --user show lobu.service -p MainPID -p NRestarts`.
- At a planned reboot, verify startup through the lingering manager using boot
  journal timestamps and `loginctl show-user faviann -p Linger`.
- Coordinate LXC rebuild validation with homelab-iac: verify the persistent mount
  and the same device identity after recreation. Record only identity/status,
  never credential-file contents.
