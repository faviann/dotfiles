# Workstation Tailscale

The workstation joins the work tailnet as the user's own account, not as a
tagged device or with an auth key. It gets the same access as the user's
desktop, DevOps SSH included. It uses the tailnet for two things:

- The JES AI gateway (`ai-gateway.jungleservices.net`). The tailnet routes the
  gateway's address through `jes-aigateway-router`.
- SSH to work-tailnet servers.

See [#170](https://github.com/faviann/dotfiles/issues/170) for the decision and
the verified test run.

- **Mode**: `tailscaled` runs in userspace networking as the login user, with no
  root and no TUN device. It doesn't change the container's routes or
  `/etc/resolv.conf`, so a work tailnet change can't affect the homelab fleet.
- **Supervision**: Home Manager owns `tailscaled.service` under
  `default.target`. Node state is in `~/.local/share/tailscale`. The control
  socket is `$XDG_RUNTIME_DIR/tailscale/tailscaled.sock`.
- **CLI**: the `tailscale` command on the workstation is a wrapper that passes
  the user socket. Use it in place of `tailscale --socket=...`.
- **Node preferences**: the node runs with `--shields-up`, `--accept-routes`
  and `--accept-dns=false`. The CLI wrapper adds them to every
  `tailscale login`, and the service applies them again with `tailscale set`
  each time it starts. If that `set` fails, the service fails to start.
- **Tailnet access**: only two paths reach the tailnet. The daemon serves an
  HTTP proxy on `127.0.0.1:1055`, and `tailscale nc` opens connections through
  the control socket. Both send tailnet addresses through the tailnet and dial
  everything else directly.

## Reach the AI gateway

Only commands started through `with-jes-gateway` use the HTTP proxy:

```bash
with-jes-gateway <command> [arguments...]
```

The wrapper sets `HTTPS_PROXY` for that command and its children only. Nothing
exports a proxy to every shell or to the systemd user manager.

## SSH to a tailnet host

Let `tailscaled` open the connection:

```bash
ssh -o ProxyCommand='tailscale nc %h %p' <host>
```

`<host>` is the server's MagicDNS name or tailnet IP. `tailscale nc` passes the
name to `tailscaled` over the control socket, and `tailscaled` resolves it. The
workstation's own resolver can't, because the node runs with
`--accept-dns=false`.

This repository adds no `~/.ssh/config` entries for tailnet hosts.

## Sign in

Before the first sign-in, deploy
[homelab-iac#599](https://github.com/faviann/homelab-iac/pull/599). It persists
`~/.local/share/tailscale` across LXC rebuilds. A sign-in before it's deployed
writes node state that the next rebuild discards.

Signing in is a human step. A login shell prints this notice while the node
is signed out:

```text
Work Tailscale is signed out: run `tailscale login`
```

Sign in:

```bash
tailscale login
```

Open the printed URL and sign in with your own work account. Don't add `--ssh`.
The wrapper adds the node preferences for you:

- `--accept-routes` accepts the router's route to the gateway.
- `--accept-dns=false` keeps the tailnet's DNS settings out of the node.
- `--shields-up` refuses incoming tailnet connections.

Sign in through the wrapper only. The unwrapped binary's `login` resets every
preference it isn't given, which turns shields-up off until the service next
restarts.

### Never remove `--shields-up`

Don't turn shields-up off, whether with `tailscale set` or with `tailscale up`.
Because the node signs in as the user, the work tailnet's playtest grant opens
`tcp:8000-8999` on it, as on every member device. In userspace mode, incoming
tailnet connections arrive as connections from localhost. They would get past
the origin firewall to Collie on port 8788. This machine also holds the vault
passphrase and the fleet SSH key.

The service turns shields-up back on when it starts, so a runtime change lasts
only until the next restart. Never remove `--shields-up` from
`tailscaleNodePrefs` in [`home/workstation.nix`](../../home/workstation.nix).
That list feeds both the `tailscale login` wrapper and the service's
`ExecStartPost=... tailscale set --shields-up ...` line.

## Verify

```bash
tailscale status
tailscale debug prefs | jq .ShieldsUp
with-jes-gateway curl -sS -o /dev/null -w '%{http_code}\n' \
  https://ai-gateway.jungleservices.net/v1/models
```

`ShieldsUp` must be `true`. A `401` without an API key means the request reached
the gateway. To confirm it went through the tailnet, run `tailscale status`
again and check that the `tx`/`rx` byte counts for `jes-aigateway-router` went
up.

## Limits

Commands run by a wrapped tool also inherit `HTTPS_PROXY`. When the daemon is
stopped or signed out, their HTTPS requests fail.
