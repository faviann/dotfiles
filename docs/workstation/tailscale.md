# Workstation Tailscale

The workstation joins the work tailnet to reach the JES AI gateway
(`ai-gateway.jungleservices.net`). The tailnet routes the gateway's address
through `jes-aigateway-router`. See
[#170](https://github.com/faviann/dotfiles/issues/170) for the decision and the
verified test run.

- **Mode**: `tailscaled` runs in userspace networking as the login user, with no
  root and no TUN device. It doesn't change the container's routes or
  `/etc/resolv.conf`, so a work tailnet change can't affect the homelab fleet.
- **Supervision**: Home Manager owns `tailscaled.service` under
  `default.target`. Node state is in `~/.local/share/tailscale`. The control
  socket is `$XDG_RUNTIME_DIR/tailscale/tailscaled.sock`.
- **CLI**: the `tailscale` command on the workstation is a wrapper that passes
  the user socket. Use it in place of `tailscale --socket=...`.
- **Gateway traffic**: the daemon serves an HTTP proxy on `127.0.0.1:1055`.
  Only commands started through `with-jes-gateway` use it:

  ```bash
  with-jes-gateway <command> [arguments...]
  ```

  The wrapper sets `HTTPS_PROXY` for that command and its children only.
  Nothing exports a proxy to every shell or to the systemd user manager. The
  proxy sends tailnet addresses through the tailnet and dials everything else
  directly.

## Sign in

Signing in with the work account is a human step. Do it once per node state:

```bash
systemctl --user status tailscaled
tailscale up --accept-routes --accept-dns=false --shields-up
```

Open the printed URL and sign in with the work account. Don't add `--ssh`.

- `--accept-routes` accepts the router's route to the gateway.
- `--accept-dns=false` keeps the tailnet's DNS settings out of the node.
- `--shields-up` refuses incoming tailnet connections. Userspace mode can still
  forward them to local services, and this machine holds the vault passphrase
  and the fleet SSH key.

The node keeps these settings in its state, so restarts don't need them again.

## Verify

```bash
tailscale status
with-jes-gateway curl -sS -o /dev/null -w '%{http_code}\n' \
  https://ai-gateway.jungleservices.net/v1/models
```

A `401` without an API key means the request reached the gateway. To confirm it
went through the tailnet, run `tailscale status` again and check that the
`tx`/`rx` byte counts for `jes-aigateway-router` went up.

## Limits

- Node state isn't persisted across LXC rebuilds. After a rebuild, sign in
  again and remove the old node from the work admin console.
- Commands run by a wrapped tool also inherit `HTTPS_PROXY`. When the daemon
  is stopped or signed out, their HTTPS requests fail.
