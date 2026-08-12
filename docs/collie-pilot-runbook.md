# Collie loopback pilot runbook

This is the operator runbook and evidence shape for the Collie pilot on the
workstation. Collie is installed through herdr, owns its generated service, and
binds only to loopback. Dotfiles supplies Bun and the socket-activated
`collie-origin-forwarder` from port 8788 to `127.0.0.1:8787`; it does not own
Collie's plugin, configuration, state, service, or update lifecycle.

## Version record

The selected pilot target is Collie `0.28.0`. The upstream `v0.28.0` release
and its `herdr-plugin.toml` both identify version `0.28.0`. The workstation
record below comes from the installed plugin action rather than the upstream
release alone.

| Fact | Recorded value | Evidence |
| --- | --- | --- |
| Install source | `herdr plugin install AltanS/collie --ref v0.28.0 -y` | Herdr 0.8.0 command history/output |
| Pilot target | `0.28.0` | upstream `v0.28.0` release and plugin manifest |
| Installed Collie version | `0.28.0+2910f40` | `version` action and its Herdr command log |
| Installed version observed at | `2026-08-12T17:23:55Z` | UTC timestamp captured with the action |
| Resolved plugin revision | `2910f40278f3ca1646fc472dd3589da4a47776e4` | install preview/result for requested ref `v0.28.0` |

Capture the installed artifact's answer, not the latest upstream release:

```bash
date --utc --iso-8601=seconds
herdr plugin list --plugin herdr.collie --json
herdr plugin action invoke version --plugin herdr.collie
herdr plugin log list --plugin herdr.collie --limit 1
```

herdr wraps action output and stores the action's stdout in its command log, so
the final command is the version evidence to transcribe into the record.

## Install and configure

Install the plugin as the workstation user:

```bash
herdr plugin install AltanS/collie --ref v0.28.0 -y
```

Create or preserve the plugin-owned environment file, restrict it to the user,
and edit it in place:

```bash
collie_env="$(herdr plugin config-dir herdr.collie)/.env"
(umask 077; : >>"$collie_env")
chmod 600 "$collie_env"
"${EDITOR:-vi}" "$collie_env"
```

The mutable file must contain exactly these pilot values:

```dotenv
COLLIE_SKIP_SERVE=1
COLLIE_HOST=127.0.0.1
COLLIE_PORT=8787
COLLIE_PUBLIC_HOSTS=collie.admin.faviann.com
COLLIE_ALLOWED_ORIGINS=https://collie.admin.faviann.com
COLLIE_PUBLIC_URL=https://collie.admin.faviann.com
COLLIE_STATE_DIR=/home/faviann/.local/state/collie
```

Check the complete file before starting Collie, then verify its mode:

```bash
stat --format='%a %n' "$collie_env"
```

The expected mode is `600`. Invoke Collie's own control action only after the
file is correct:

```bash
herdr plugin action invoke start --plugin herdr.collie
```

That action creates, enables, and starts the app-owned `collie.service` user
unit. Do not copy the generated unit into Home Manager or make the forwarder
depend on it.

## Pilot evidence

Run these checks on the workstation after the start action. Preserve the raw
output with a UTC timestamp; do not convert an expected value into an observed
claim when a command was not run.

### Observed pilot record

The following results were captured during the 2026-08-12 pilot. They are a
compact record; retain the raw command output separately rather than placing
secrets or large JSON responses in this repository.

| Criterion | Outcome and evidence |
| --- | --- |
| Bun runtime | The Home Manager baseline `/nix/store/i8a69r7yp0qp9x1f1j5gnqwibrfg6z3z-bun-baseline-1.3.13/bin/bun` reported `1.3.13` on the target Xeon workstation. |
| Pinned install | Herdr 0.8.0 previewed and installed plugin version `0.28.0` from requested ref `v0.28.0`, resolved to commit `2910f40278f3ca1646fc472dd3589da4a47776e4`, with the plugin enabled. |
| Installed version | At `2026-08-12T17:23:55Z`, the installed `version` action returned `0.28.0+2910f40`. |
| Collie health | Start/status logs reported a healthy local endpoint at `http://127.0.0.1:8787`, proxy URL `https://collie.admin.faviann.com`, and skipped ingress because `COLLIE_SKIP_SERVE=1`. |
| Generated service | `/home/faviann/.config/systemd/user/collie.service` was app-generated, enabled, and active with `NRestarts=0`. |
| Local isolation and ownership | The listener was exactly `127.0.0.1:8787`; the environment file was mode `600` and owned by `faviann:faviann`; the state directory was mode `700` and owned by `faviann:faviann`. |
| Workstation HTTP paths | Requests carrying `Host: collie.admin.faviann.com` returned HTTP `200` through both local Collie port `8787` and local forwarder port `8788`. |
| Homelab firewall | After deployment of the separately reviewed firewall change, the firewall unit was enabled and active, protected ports included `8788`, and the only allowed IPv4 address was portal `10.1.0.2`. |
| Remote positive probe | From the portal, `10.1.4.25:8788` returned curl rc `0` and HTTP `200`. |
| Remote negative probe | From distinct auth client `10.1.9.29`, the same endpoint timed out with curl rc `28` and HTTP `000`. |
| Herdr disconnect/reconnect | Against an isolated `collie-pilot` named-session socket, the snapshot changed from `reachable=false` to `reachable=true` after a new Herdr process returned. Collie stayed active at captured proof PID `2802133` with HTTP `200` and `NRestarts=0`; this PID is historical evidence, not a durable current value. |
| Final restored state | The disposable service and session state were removed, Collie was returned to the normal primary socket and remained active, the default snapshot was reachable, and the environment file remained mode `600`. It contained only the seven pilot values documented above, with no VAPID keys. |

### Plugin health and generated service

```bash
date --utc --iso-8601=seconds
herdr plugin list --plugin herdr.collie --json
herdr plugin action invoke status --plugin herdr.collie
herdr plugin log list --plugin herdr.collie --limit 1
systemctl --user is-enabled collie.service
systemctl --user is-active collie.service
systemctl --user show collie.service \
  --property=FragmentPath --property=MainPID --property=NRestarts
systemctl --user cat collie.service
```

The service evidence must show `enabled`, `active`, and an app-generated unit.
The action log supplies Collie's own HTTP health result.

### Loopback bridge

```bash
ss -H -ltn 'sport = :8787'
test "$(ss -H -ltn 'sport = :8787' | awk '{print $4}')" = \
  '127.0.0.1:8787'
curl --fail --show-error --silent --output /dev/null \
  --header 'Host: collie.admin.faviann.com' \
  --write-out 'HTTP %{http_code}\n' http://127.0.0.1:8787/
```

The listener check rejects wildcard and IPv6-any binds; the only accepted
listener for this pilot is `127.0.0.1:8787`.

### Origin forwarder reachability and isolation

On the workstation, verify the dotfiles-owned socket and exercise its path to
the loopback bridge:

```bash
systemctl --user is-enabled collie-origin-forwarder.socket
systemctl --user is-active collie-origin-forwarder.socket
systemctl --user status collie-origin-forwarder.socket --no-pager
ss -H -ltn 'sport = :8788'
curl --fail --show-error --silent --output /dev/null \
  --header 'Host: collie.admin.faviann.com' \
  --write-out 'HTTP %{http_code}\n' http://127.0.0.1:8788/
```

Replace `WORKSTATION_LAN_IP` below with the same workstation address for both
remote checks. From the portal host, port 8788 must be reachable:

```bash
curl --fail --show-error --silent --connect-timeout 5 --output /dev/null \
  --header 'Host: collie.admin.faviann.com' \
  --write-out 'HTTP %{http_code}\n' http://WORKSTATION_LAN_IP:8788/
```

From a different LAN client that is not the portal, the same command must fail
to connect:

```bash
curl --fail --show-error --silent --connect-timeout 5 --output /dev/null \
  --header 'Host: collie.admin.faviann.com' \
  --write-out 'HTTP %{http_code}\n' http://WORKSTATION_LAN_IP:8788/
```

Record the portal success and other-client failure together. The negative
result is isolation evidence only when both clients tested the same address and
port during the same pilot window. Public DNS, TLS, and Traefik routing are a
separate ownership boundary and are not established by these commands.

### Herdr disconnect and reconnect without a Collie restart

Never stop the active primary Herdr server for this check. Use a disposable
named session and point Collie only at that session's socket. One repeatable
shape for the isolated procedure used by this pilot is:

```bash
pilot_herdr="$(command -v herdr)"
systemd-run --user --unit=herdr-collie-pilot-a \
  --service-type=exec --collect -- \
  "$pilot_herdr" --session collie-pilot server
```

Temporarily add these two lines to Collie's plugin-owned `.env`, preserving the
seven pilot values, and restart Collie once so it adopts the isolated socket:

```dotenv
HERDR_SOCKET_PATH=/home/faviann/.config/herdr/sessions/collie-pilot/herdr.sock
COLLIE_MULTI_SESSION=0
```

```bash
herdr plugin action invoke restart --plugin herdr.collie
collie_pid_before="$(systemctl --user show collie.service \
  --property=MainPID --value)"
curl --fail --show-error --silent \
  --header 'Host: collie.admin.faviann.com' \
  http://127.0.0.1:8787/api/snapshot | jq .
```

Stop only the disposable transient service. Confirm that its session is
unreachable while Collie remains active and serves HTTP:

```bash
systemctl --user stop herdr-collie-pilot-a.service
systemctl --user is-active collie.service
curl --fail --show-error --silent \
  --header 'Host: collie.admin.faviann.com' \
  http://127.0.0.1:8787/api/snapshot | jq '.sessions[0].reachable'
curl --fail --show-error --silent --output /dev/null \
  --header 'Host: collie.admin.faviann.com' \
  --write-out 'HTTP %{http_code}\n' http://127.0.0.1:8787/
```

Start a new Herdr process for the same disposable session and verify that the
same Collie process reconnects without a Collie restart:

```bash
systemd-run --user --unit=herdr-collie-pilot-b \
  --service-type=exec --collect -- \
  "$pilot_herdr" --session collie-pilot server
curl --fail --show-error --silent \
  --header 'Host: collie.admin.faviann.com' \
  http://127.0.0.1:8787/api/snapshot | jq '.sessions[0].reachable'
collie_pid_after="$(systemctl --user show collie.service \
  --property=MainPID --value)"
test "$collie_pid_after" = "$collie_pid_before"
systemctl --user show collie.service \
  --property=MainPID --property=NRestarts
```

For cleanup, stop only the second disposable service, delete the stopped named
session, remove the two temporary environment lines with an editor, and restart
Collie once to restore the normal primary socket:

```bash
systemctl --user stop herdr-collie-pilot-b.service
herdr session delete collie-pilot
collie_env="$(herdr plugin config-dir herdr.collie)/.env"
"${EDITOR:-vi}" "$collie_env"
herdr plugin action invoke restart --plugin herdr.collie
curl --fail --show-error --silent \
  --header 'Host: collie.admin.faviann.com' \
  http://127.0.0.1:8787/api/snapshot | jq '.sessions[0].reachable'
stat --format='%a %U:%G %n' "$collie_env"
```

Confirm the environment file is again exactly the seven pilot values above.
During the pilot proof, reconnection occurred before this cleanup restart: the
captured Collie PID stayed `2802133` and `NRestarts` stayed `0`.

## Manual update

There is no timer or automatic update. Record the installed version before and
after running the one operator action:

```bash
herdr plugin action invoke update --plugin herdr.collie
```

The action updates the plugin checkout, rebuilds the UI, and restarts its own
bridge. Repeat the version, health, service, and loopback evidence afterward.

## Excluded from this pilot

Web Push and VAPID keys, automatic updates, public Traefik routing, and Home
Manager ownership of `collie.service` are excluded. Collie's generated service
and mutable `.env` remain application-owned. This repository owns only the
runtime prerequisite and the origin forwarder; homelab ingress policy and
configuration stay in their respective external ownership boundaries.
