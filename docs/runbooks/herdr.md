# Herdr operations and recovery

Home Manager owns `herdr.service`, enabled under `default.target`. It runs
`/home/faviann/.local/bin/herdr server` in the foreground, with
`Restart=on-failure` and a five-second delay. Existing user lingering supplies
boot activation. Collie's app-owned service has an independent lifecycle and
reconnects when Herdr returns; restarting Herdr does not require restarting
Collie.

## Service control and manual updates

Use systemd for the supervised default server:

```bash
systemctl --user status herdr.service collie.service --no-pager
systemctl --user stop herdr.service
systemctl --user start herdr.service
systemctl --user restart herdr.service
```

An intentional stop remains stopped until explicitly started or the next boot.
Stop and restart end pane processes. Finish important pane work and use a
terminal outside Herdr before either operation. Avoid launching the interactive
Herdr client while the service is stopped: it can start an unmanaged detached
server.

Herdr updates remain outside `workstation-update`. From a terminal outside
Herdr, after finishing pane work:

```bash
systemctl --user stop herdr.service
herdr update
systemctl --user start herdr.service
```

## Restore behavior

Restore is reconstructive, not live-process preservation. Herdr reads
`~/.config/herdr/session.json` to recreate pane identities, tabs, workspaces,
and directories with new terminal processes. Back up that snapshot privately
before recovery that could replace it. A graceful shutdown saves a snapshot;
an abrupt failure such as SIGKILL cannot save a new one and recovery uses the
last persisted snapshot.

Session restore does not preserve filesystem contents. A working directory
under `/tmp` may disappear after reboot; a restored pane whose directory no
longer exists may fall back to the home directory. Compare restored locations,
not just pane identities, before resuming work.

## Recovery checks

```bash
systemctl --user show herdr.service collie.service \
  -p MainPID -p NRestarts -p ActiveState -p UnitFileState
journalctl --user -u herdr.service -u collie.service --since=-10m --no-pager
loginctl show-user faviann -p Linger
curl --fail --silent --show-error \
  --header 'Host: collie.admin.faviann.com' \
  http://127.0.0.1:8787/api/snapshot |
  jq '{bridge, sessions: [.sessions[] | {name, reachable}]}'
```

Require one supervised default server without a continually increasing restart
count. Collie should remain active while Herdr is intentionally stopped, report
the session unreachable, and reconnect after Herdr starts. The filtered snapshot
shows connection state without exposing pane content.

If a detached default server is blocking service startup, first finish any
important pane work and privately back up the snapshot. From outside Herdr,
stop the managed unit if necessary, use `herdr server stop` to stop the detached
server gracefully, wait for it to exit, then start `herdr.service`. Check the
restored panes and Collie connection. Do not repeat detached-server recovery on
routine Home Manager updates.

For boot problems, inspect lingering and the user-service boot journal. An
active service checked only after SSH login does not establish startup without
login. For a missing Collie unit after a rebuild, use the
[Collie rebuild recovery procedure](collie.md#recovery-after-an-lxc-rebuild)
rather than copying its generated unit into Home Manager.
