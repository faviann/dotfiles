# Herdr supervision and cutover

Home Manager owns `herdr.service`, enabled under `default.target`. The service
runs `/home/faviann/.local/bin/herdr server` in the foreground, with a five-second
restart delay on failure. Existing user lingering supplies boot activation.
Collie owns its own enabled service and retries its connection independently.

## One-time migration

Before applying the enabled unit on a machine still running a detached server:

1. Confirm with the operator that no important pane processes are running. Use a
   terminal outside herdr; server shutdown ends all pane processes.
2. Back up `~/.config/herdr/session.json` privately. Record the pane list with
   `herdr pane list`, the detached server PID, and Collie's service PID.
3. Run `herdr server stop`. Wait for that specific process to exit and check that
   the session snapshot was saved. Keep a copy of the shutdown snapshot.
4. Apply the Home Manager configuration. It enables and starts `herdr.service`.
   Verify `systemctl --user is-enabled herdr.service` and
   `systemctl --user status herdr.service`. There should be exactly one default
   server and no increasing `NRestarts` counter.
5. Compare restored pane identities, workspaces, tabs, and directories with the
   saved list. Terminal processes are newly created. Check Collie reconnection
   without restarting its service.

Do not repeat the detached-server stop on routine configuration updates. For
normal operations use `systemctl --user stop/start/restart herdr.service`.
Avoid launching a herdr client while intentionally stopped; it can auto-start
an unmanaged server. If that happens, stop the detached server gracefully before
starting the service. To roll back supervision, stop and disable the service,
revert the target enablement in Home Manager, then launch herdr manually.

## Recovery checks

With all panes disposable, record `MainPID` and `NRestarts` for both services.

- Restart: `systemctl --user restart herdr.service`. Compare pane identities and
  directories before/after, and verify terminal IDs changed. This proves
  reconstructive restore, not live-process preservation.
- Intentional stop: `systemctl --user stop herdr.service`. Wait longer than five
  seconds. Require inactive state and PID 0; Collie should remain active and
  report its default session unreachable. Start herdr and require reconnection.
- Unexpected failure: `systemctl --user kill --kill-whom=main --signal=SIGKILL
  herdr.service`. After the restart delay require a new herdr PID, one additional
  restart, and a reachable default session in Collie. SIGKILL cannot save a new
  snapshot, so recovery uses the last persisted snapshot.
- Reboot: record `/proc/sys/kernel/random/boot_id` and the current pane list,
  then reboot the workstation during an agreed interruption window. Before any
  interactive workstation login, use the existing management connection to
  inspect the lingering user manager: both services must already be active.
  Confirm a changed boot ID, automatic startup in the journal, restored pane
  identities/directories, and Collie reconnection. A normal SSH login followed
  by an active-state check alone does not prove startup without login.

Local Collie connection evidence can be checked without exposing pane content:

```bash
curl --fail --silent --show-error \
  --header 'Host: collie.admin.faviann.com' \
  http://127.0.0.1:8787/api/snapshot |
  jq '{bridge, sessions: [.sessions[] | {name, reachable}]}'
systemctl --user show herdr.service collie.service \
  -p MainPID -p NRestarts -p ActiveState -p UnitFileState
journalctl --user -u herdr.service -u collie.service --since=-10m --no-pager
loginctl show-user faviann -p Linger
```

For manual herdr updates, finish pane work, stop the service from a terminal
outside herdr, run `herdr update`, and start the service again. Updates remain
outside `workstation-update`. Collie's generated service stays app-owned.

## Issue #74 evidence — 2026-09-07

The operator confirmed that no important herdr pane work was running. This
Codex session's process ancestry led through SSH, independently of herdr.
Private snapshots and pane inventories are under
`~/.local/state/herdr-cutover-74/` (directory mode 0700).

- Detached PID `2105747` exited after `herdr server stop`; `session.json` was
  written at `22:27:37 UTC` and copied before activation.
- Home Manager activation started the enabled service as PID `2321138`, with
  `NRestarts=0` and no duplicate server.
- All 13 pane identities, tabs, workspaces, and directories survived initial
  activation and normal restart. Restart changed every terminal ID and produced
  server PID `2324566`, with `NRestarts=0`.
- Collie remained at PID `2175172`, `NRestarts=0`, and reported the default
  session reachable after both operations.
- Intentional stop remained inactive with PID 0 after seven seconds. Collie
  stayed active and reported the default session unreachable.
- Killing only the supervised main process with SIGKILL recovered as PID
  `2329401`, `NRestarts=1`. Collie reconnected with its original PID and zero
  restarts.
- The focused herdr and updater suites, `nix run .#shellcheck`, and
  `nix flake check` passed. Final recovery preserved all 13 pane identities and
  locations.
- Reboot changed the boot ID from `5c1b94ff-5554-471f-becf-7e134245fedf`
  to `3035dd5c-a6e1-407f-88f1-9020c390f31c`. Both services started at
  `22:36:03 UTC`, before the first SSH login at `22:36:08 UTC`, as confirmed by
  the user-service and SSH boot journals. Herdr PID `371` and Collie PID `397`
  were active and enabled, each with `NRestarts=0`.
- Collie's default session was reachable and its bridge connected without
  service intervention. All 13 pane identities, tabs, and workspaces returned.
  Twelve working directories matched. Pane `w9:p5` previously used
  `/tmp/work-on-264-clean-fc32490`, which no longer existed after reboot; herdr
  reconstructed that pane in `/home/faviann`. Reconstructive restore does not
  preserve temporary filesystem contents.

The authorized reboot was observed by the temporary
`herdr-cutover-74-proof.service`, enabled under the user target without starting
or ordering herdr or Collie. Its strict directory-equality assertion kept
retrying because of the missing temporary directory. Manual comparison recorded
that exception in `boot-review.json`, alongside `panes.pre-reboot.json` and
`panes.post-reboot.json` in the private evidence directory. The observer was
stopped, disabled, and removed after inspection; the user manager was reloaded.
The normal herdr and Collie services remained running throughout inspection.
