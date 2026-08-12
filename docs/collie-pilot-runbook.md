# Collie loopback pilot runbook

This is the operator runbook and evidence shape for the Collie pilot on the
workstation. Collie is installed through herdr, owns its generated service, and
binds only to loopback. Dotfiles supplies Bun and the socket-activated
`collie-origin-forwarder` from port 8788 to `127.0.0.1:8787`; it does not own
Collie's plugin, configuration, state, service, or update lifecycle.

## Version record

The selected pilot target is Collie `0.28.0`. The upstream `v0.28.0` release
and its `herdr-plugin.toml` both identify version `0.28.0`. That target is not
proof of the version installed on the workstation: fill the installed fact
below only from the installed plugin action.

| Fact | Recorded value | Evidence |
| --- | --- | --- |
| Install source | `herdr plugin install --ref v0.28.0 AltanS/collie` | operator command history/output |
| Pilot target | `0.28.0` | upstream `v0.28.0` release and plugin manifest |
| Installed Collie version | _not yet observed_ | `version` action and its herdr command log |
| Installed version observed at | _not yet observed_ | UTC timestamp captured with the output |

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
herdr plugin install --ref v0.28.0 AltanS/collie
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
  --write-out='HTTP %{http_code}\n' http://127.0.0.1:8787/
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
  --write-out='HTTP %{http_code}\n' http://127.0.0.1:8788/
```

Replace `WORKSTATION_LAN_IP` below with the same workstation address for both
remote checks. From the portal host, port 8788 must be reachable:

```bash
curl --fail --show-error --silent --connect-timeout 5 --output /dev/null \
  --header 'Host: collie.admin.faviann.com' \
  --write-out='HTTP %{http_code}\n' http://WORKSTATION_LAN_IP:8788/
```

From a different LAN client that is not the portal, the same command must fail
to connect:

```bash
curl --fail --show-error --silent --connect-timeout 5 --output /dev/null \
  --header 'Host: collie.admin.faviann.com' \
  --write-out='HTTP %{http_code}\n' http://WORKSTATION_LAN_IP:8788/
```

Record the portal success and other-client failure together. The negative
result is isolation evidence only when both clients tested the same address and
port during the same pilot window. Public DNS, TLS, and Traefik routing are a
separate ownership boundary and are not established by these commands.

### Herdr disconnect and reconnect without a Collie restart

This check intentionally interrupts Herdr, so run it only in a scheduled pilot
window. In terminal A, record Collie's process identity, stop the Herdr server,
and show that Collie's service and HTTP bridge remain running:

```bash
collie_pid_before="$(systemctl --user show collie.service \
  --property=MainPID --value)"
herdr server stop
herdr status server --json
systemctl --user is-active collie.service
curl --silent --show-error --write-out='\nHTTP %{http_code}\n' \
  http://127.0.0.1:8787/api/snapshot
```

The Herdr status is the disconnection evidence; the active unit and HTTP
response show that Collie itself did not stop. In terminal B, launch or attach
to the normal persistent session:

```bash
herdr
```

Back in terminal A, verify reconnection and prove the Collie process was not
restarted:

```bash
herdr status server --json
curl --fail --show-error --silent \
  http://127.0.0.1:8787/api/snapshot | jq .
collie_pid_after="$(systemctl --user show collie.service \
  --property=MainPID --value)"
test "$collie_pid_after" = "$collie_pid_before"
systemctl --user show collie.service \
  --property=MainPID --property=NRestarts
```

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
