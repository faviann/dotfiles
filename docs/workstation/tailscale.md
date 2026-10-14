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

Signing in is a human step. Do it once per node state:

```bash
systemctl --user status tailscaled
tailscale up --accept-routes --accept-dns=false --shields-up
```

Open the printed URL and sign in with your own work account. Don't add `--ssh`.

- `--accept-routes` accepts the router's route to the gateway.
- `--accept-dns=false` keeps the tailnet's DNS settings out of the node.
- `--shields-up` refuses incoming tailnet connections.

The node keeps these settings in its state, so restarts don't need them again.

### Never remove `--shields-up`

Don't turn shields-up off, whether with `tailscale set` or with `tailscale up`.
Because the node signs in as the user, the work tailnet's playtest grant opens
`tcp:8000-8999` on it, as on every member device. In userspace mode, incoming
tailnet connections arrive as connections from localhost. They would get past
the origin firewall to Collie on port 8788. This machine also holds the vault
passphrase and the fleet SSH key.

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
