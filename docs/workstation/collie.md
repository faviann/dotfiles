# Workstation Collie

Collie is installed and controlled through [Herdr](herdr.md). Its plugin
checkout, configuration, state, and generated `collie.service` remain app-owned
and outside `workstation-update`.

Dotfiles owns the Bun prerequisite, the boot-time `collie-bootstrap.service`
handoff, and the origin forwarder from `0.0.0.0:8788` to Collie's loopback
listener at `127.0.0.1:8787`. A Home Manager drop-in makes the app want the
forwarder socket without taking ownership of its generated unit. Collie
reconnects independently when Herdr returns.

See the [Collie operator runbook](../runbooks/collie.md) for configuration,
manual updates, origin isolation, Web Push, and
[rebuild recovery](../runbooks/collie.md#recovery-after-an-lxc-rebuild). The
bootstrap regenerates the service from a surviving plugin installation; it does
not provide VAPID or subscription-state persistence.
