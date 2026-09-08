# Collie operator runbook

This runbook targets the documented Collie `1.5.6` installation (`v1.5.6`)
managed through Herdr. Run commands as the workstation user. Check the installed
artifact rather than assuming it matches the latest upstream release:

```bash
herdr plugin action invoke version --plugin herdr.collie
herdr plugin log list --plugin herdr.collie --limit 1
```

Herdr stores action stdout in its command log. Collie owns its plugin checkout,
mutable configuration, state, generated `collie.service`, and update lifecycle.
Dotfiles supplies Bun through `update-agent-tools` in `~/.local/bin`, the
`collie-bootstrap.service` recovery handoff, and the origin-forwarder integration.
Home Manager's `collie.service.d/10-origin-forwarder.conf` adds only
`Wants=collie-origin-forwarder.socket`; it does not duplicate Collie's generated
unit. The forwarder has no dependency on `collie.service` or Herdr.

## Install and configure

```bash
herdr plugin install AltanS/collie --ref v1.5.6 -y
collie_env="$(herdr plugin config-dir herdr.collie)/.env"
(umask 077; : >>"$collie_env")
chmod 600 "$collie_env"
"${EDITOR:-vi}" "$collie_env"
```

Preserve existing settings and VAPID entries when editing. The required base
configuration is:

```dotenv
COLLIE_SKIP_SERVE=1
COLLIE_HOST=127.0.0.1
COLLIE_PORT=8787
COLLIE_PUBLIC_HOSTS=collie.admin.faviann.com
COLLIE_ALLOWED_ORIGINS=https://collie.admin.faviann.com
COLLIE_PUBLIC_URL=https://collie.admin.faviann.com
COLLIE_STATE_DIR=/home/faviann/.local/state/collie
COLLIE_MUX=herdr
```

`COLLIE_MUX=herdr` is required for Collie 1.x here because both Herdr and tmux
run on the workstation. Without an explicit multiplexer, start/restart can fail
while the previous bridge remains up. Check the complete file privately before
starting; it must be owned by the workstation user with mode `600`, and the
state directory must be user-owned with mode `700`.

```bash
stat --format='%a %U:%G %n' "$collie_env"
herdr plugin action invoke start --plugin herdr.collie
```

The start action generates, enables, and starts the app-owned `collie.service`.
A plugin reinstall alone does not restart the running bridge. Use Collie's
`restart` and `status` actions for subsequent control, for example:

```bash
herdr plugin action invoke restart --plugin herdr.collie
herdr plugin action invoke status --plugin herdr.collie
```

## Health and origin isolation

```bash
systemctl --user is-enabled collie.service collie-origin-forwarder.socket
systemctl --user is-active collie.service collie-origin-forwarder.socket
systemctl --user show collie.service -p FragmentPath -p MainPID -p NRestarts
journalctl --user -u collie.service --since=-10m --no-pager
ss -H -ltn 'sport = :8787'
test "$(ss -H -ltn 'sport = :8787' | awk '{print $4}')" = '127.0.0.1:8787'
for port in 8787 8788; do
  curl --fail --show-error --silent --output /dev/null \
    --header 'Host: collie.admin.faviann.com' \
    --write-out 'HTTP %{http_code}\n' "http://127.0.0.1:$port/"
done
```

The bridge must bind only `127.0.0.1:8787`, not a wildcard or IPv6-any address.
The dotfiles-owned socket listens on `0.0.0.0:8788` and forwards to that bridge.
Homelab firewall policy must restrict 8788 to the portal; the forwarder itself
is not an access-control boundary. Public DNS, TLS, and Traefik are externally
owned, not configured here.

After ingress or recovery work, run the following against the same workstation
address from the portal and from a different LAN client. Require portal success
and other-client connection failure; local HTTP success alone proves neither
remote isolation nor public routing:

```bash
curl --fail --show-error --silent --connect-timeout 5 --output /dev/null \
  --header 'Host: collie.admin.faviann.com' \
  --write-out 'HTTP %{http_code}\n' http://WORKSTATION_LAN_IP:8788/
```

Collie remains running and reconnects across Herdr restarts. Use the
[Herdr recovery checks](herdr-supervision-runbook.md#recovery-checks) to inspect
connection state without exposing pane content. Do not interrupt active Herdr
panes merely to test reconnection.

## Recovery after an LXC rebuild

Home Manager enables `collie-bootstrap.service` at boot. It resolves the current
`herdr.collie` checkout from `~/.config/herdr/plugins.json` and invokes that
installation's `scripts/collie-ctl.sh start`. Collie regenerates and enables its
own service; no generated executable path is persisted in Home Manager.

The bootstrap is ordered after `default.target` because Collie's startup waits
for its own unit, which is also ordered after that target. It has no Herdr
service dependency. A missing registry or absent Collie entry is a successful
skip. Malformed metadata, a missing registered checkout, or failed startup is a
visible failure. After repairing the installation, retry:

```bash
systemctl --user restart collie-bootstrap.service
systemctl --user status collie-bootstrap.service collie.service --no-pager
```

The oneshot remains active after success and does not continually undo a manual
Collie stop. A new boot runs it again. Installation after a skipped bootstrap
requires the normal plugin start action or the retry above.

Recovery requires the Herdr registry, plugin checkout, and plugin configuration
to survive the rebuild, plus the provisioned workstation profile and host
systemd. Service regeneration is not a backup mechanism: it does not establish
persistence for VAPID keys or subscription state. Preserve or restore those
separately; do not generate a replacement signing identity as a routine repair.

## Manual update

Collie is outside `workstation-update`; there is no automatic update timer.
Check the installed version before and after an update. Within the installed
major version:

```bash
herdr plugin action invoke update --plugin herdr.collie
```

Crossing a major version requires separate, explicit consent:

```bash
herdr plugin action invoke update-major --plugin herdr.collie
```

These actions update the checkout, rebuild the UI, and restart the bridge.
Check that the action exists in the installed manifest before relying on it;
older manifests need not support the same update policy. A pinned reinstall
using `herdr plugin install ... --ref <tag> -y` must be followed by the restart
action. Configuration and `COLLIE_STATE_DIR` live outside the replaced checkout;
keep them intact and recheck version, health, and loopback binding afterward.

A Herdr-managed checkout advances in place and has no `versions/` layout, so
`update --rollback` is unsupported. For a downgrade, reinstall the intended
previously supported tag, resolve the replacement checkout, and remove the
compiled binary before restarting so an old binary is not reused:

```bash
collie_plugin_root="$(
  herdr plugin list --plugin herdr.collie --json |
    jq --exit-status --raw-output \
      '.result.plugins[] | select(.plugin_id == "herdr.collie") | .plugin_root'
)"
rm -f "$collie_plugin_root/bin/collie"
herdr plugin action invoke restart --plugin herdr.collie
```

## Device pairing

Collie 1.x provides per-device write credentials through `collie pair` and
`collie devices`. Pairing is not configured for this installation. The write
gate is active only while at least one device is paired; revoking the last
device disables it again. Do not assume an unpaired installation enforces a
per-device write gate. Pairing policy is outside this runbook's setup.

## Web Push

Web Push configuration and dependencies remain app-owned. These procedures
target the documented `v1.5.6` checkout; do not update Collie as part of push
setup. Keep the `.env`, VAPID private key, and browser subscription contents out
of Git, command output, diffs, and logs. Do not `cat` or source the `.env`.

### Dependency and signing identity

Resolve the installed checkout rather than copying a cache path:

```bash
collie_plugin_root="$(
  herdr plugin list --plugin herdr.collie --json |
    jq --exit-status --raw-output \
      '.result.plugins[] | select(.plugin_id == "herdr.collie") | .plugin_root'
)"
(
  set -euo pipefail
  test -f "$collie_plugin_root/herdr-plugin.toml"
  test "$(git -C "$collie_plugin_root" rev-parse HEAD)" = \
    'bc73318574cd1de858855a2414df9f66a362203c'
  cd "$collie_plugin_root"
  bun add web-push
  bun -e '
    const mod = await import("web-push");
    const api = mod.default ?? mod;
    if (typeof api.sendNotification !== "function") process.exit(1);
    console.log("web-push import: ok");
  '
)
```

The import check must print `web-push import: ok`. The dependency belongs in
that checkout, not dotfiles or a global Bun environment. Recheck it after
reinstalling or updating the plugin.

Keep an existing VAPID identity. For first-time setup only, the following
subshell refuses existing VAPID entries, generates both keys together without
printing them, and installs the merged environment with mode `600`. Do not use
`bunx web-push generate-vapid-keys` directly: it prints the private key.

```bash
(
  set -euo pipefail
  umask 077
  collie_env="$(herdr plugin config-dir herdr.collie)/.env"
  test "$(stat --format='%a' "$collie_env")" = '600'
  if grep --quiet '^COLLIE_VAPID_\(PUBLIC\|PRIVATE\|SUBJECT\)=' "$collie_env"; then
    echo 'VAPID configuration already exists; refusing to rotate it' >&2
    exit 1
  fi
  collie_vapid_tmp="$(mktemp -d)"
  trap 'rm -rf -- "$collie_vapid_tmp"' EXIT
  COLLIE_VAPID_OUTPUT="$collie_vapid_tmp/vapid.env" \
    COLLIE_VAPID_SUBJECT_VALUE='https://collie.admin.faviann.com' \
    bun --cwd "$collie_plugin_root" -e '
      const mod = await import("web-push");
      const api = mod.default ?? mod;
      const keys = api.generateVAPIDKeys();
      await Bun.write(process.env.COLLIE_VAPID_OUTPUT, [
        `COLLIE_VAPID_PUBLIC=${keys.publicKey}`,
        `COLLIE_VAPID_PRIVATE=${keys.privateKey}`,
        `COLLIE_VAPID_SUBJECT=${process.env.COLLIE_VAPID_SUBJECT_VALUE}`,
        "",
      ].join("\n"));
    '
  awk '!/^COLLIE_VAPID_(PUBLIC|PRIVATE|SUBJECT)=/' "$collie_env" \
    >"$collie_vapid_tmp/base.env"
  printf '\n' >>"$collie_vapid_tmp/base.env"
  dd if="$collie_vapid_tmp/vapid.env" of="$collie_vapid_tmp/base.env" \
    oflag=append conv=notrunc status=none
  install --mode=600 "$collie_vapid_tmp/base.env" "$collie_env"
)
```

Check metadata and key shapes without displaying values. Require mode `600`,
owner/group `faviann:faviann`, and exactly one valid entry per name:

```bash
collie_env="$(herdr plugin config-dir herdr.collie)/.env"
stat --format='%a %U:%G %n' "$collie_env"
awk -F= '
  /^COLLIE_VAPID_(PUBLIC|PRIVATE|SUBJECT)=/ {
    count[$1]++
    value = substr($0, index($0, "=") + 1)
    if ($1 == "COLLIE_VAPID_PUBLIC")
      valid[$1] = length(value) == 87 && value !~ /[^A-Za-z0-9_-]/
    else if ($1 == "COLLIE_VAPID_PRIVATE")
      valid[$1] = length(value) == 43 && value !~ /[^A-Za-z0-9_-]/
    else
      valid[$1] = value == "https://collie.admin.faviann.com"
  }
  END {
    names[1]="COLLIE_VAPID_PUBLIC"
    names[2]="COLLIE_VAPID_PRIVATE"
    names[3]="COLLIE_VAPID_SUBJECT"
    for (i=1; i<=3; i++) {
      name=names[i]
      ok = count[name] == 1 && valid[name]
      printf "%s: count=%d valid=%s\n", name, count[name], ok ? "yes" : "no"
      if (!ok) bad=1
    }
    exit bad
  }
' "$collie_env"
```

Shape checks do not prove cryptographic pairing; generating both keys in the
same `generateVAPIDKeys()` call establishes that pair. The mutable paths are
`~/.config/herdr/plugins/config/herdr.collie/.env` for the identity and
`~/.local/state/collie/push-subscriptions.json` for browser subscriptions.
Neither is made rebuild-persistent by the bootstrap service.

### Enablement and subscription checks

```bash
herdr plugin action invoke restart --plugin herdr.collie
herdr plugin action invoke status --plugin herdr.collie
journalctl --user -u collie.service --since=-5m --no-pager |
  grep -F '[push] enabled ('
curl --fail --show-error --silent \
  --header 'Host: collie.admin.faviann.com' \
  http://127.0.0.1:8787/api/config |
  jq '{push, vapidPublicKeyPresent:
    (.vapidPublicKey | type == "string" and length > 0), build}'
```

Require healthy status, the push-enabled banner, `push: true`, and
`vapidPublicKeyPresent: true`. On the installed Android Chrome PWA at
`https://collie.admin.faviann.com`, enable **Settings → Push notifications** and
allow Android's notification permission. The switch must remain on when
Settings is reopened. Resolve blocked permissions in Android's site/app
notification settings; do not copy subscription diagnostics.

Check persisted subscription shape and count without printing endpoints or keys:

```bash
collie_subscriptions='/home/faviann/.local/state/collie/push-subscriptions.json'
stat --format='%a %U:%G %n' "$collie_subscriptions"
jq --exit-status '
  if type == "array" and length > 0 and all(.[];
    type == "object" and
    (.endpoint | type == "string" and length > 0) and
    (.keys | type == "object") and
    (.keys.p256dh | type == "string" and length > 0) and
    (.keys.auth | type == "string" and length > 0)
  ) then {subscriptionCount: length, hasValidSubscriptions: true}
  else error("subscription state must be a nonempty array of valid subscriptions")
  end
' "$collie_subscriptions"
```

### Delivery checks

Using the resolved checkout, send through Collie's own saved-subscription and
VAPID signing path:

```bash
(cd "$collie_plugin_root" && \
  bash scripts/collie-ctl.sh push-test \
    'Collie Web Push test' 'Operator delivery check') >/dev/null 2>&1
```

Keep both streams suppressed, not redirected to a persistent file: send errors
may include subscription endpoints. Exit status alone is not delivery evidence;
per-endpoint failure can coexist with a successful command exit. Confirm the
phone displays that title/body and tapping opens the canonical origin. This
test uses a special `test` pane ID, so landing at the origin root is expected.

For lifecycle delivery, observe a real agent transition to `blocked` or `done`,
then confirm that tapping the notification opens that agent's pane. With only
one affected agent, the title is `<agent> needs you` or `<agent> is done` and the
body is `<workspace> · <cwd>`. In this version the body is not the agent's
blocking message; a manually supplied push-test body does not prove otherwise.
Do not record pane output, subscription endpoints, or browser keys during checks.
