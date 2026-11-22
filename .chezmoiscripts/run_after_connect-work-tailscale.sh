#!/bin/bash
# Installs Tailscale and keeps it set for split tunneling to work services.
# Signing in is left to the user: the notice below prints the command.
set -euo pipefail

# Tests point this at a scratch root; a real run leaves it empty.
root="${CONNECT_WORK_TAILSCALE_TEST_ROOT:-}"
keyring="$root/usr/share/keyrings/tailscale-archive-keyring.gpg"
sources_list="$root/etc/apt/sources.list.d/tailscale.list"
pref_flags=(--accept-routes --accept-dns --shields-up)

say() { printf 'connect-work-tailscale: %s\n' "$*"; }
die() {
  printf 'connect-work-tailscale: error: %s\n' "$*" >&2
  exit 1
}

install_tailscale() {
  local ID VERSION_CODENAME base attempt
  # shellcheck source=/dev/null
  . "$root/etc/os-release"
  base="https://pkgs.tailscale.com/stable/$ID/$VERSION_CODENAME"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  curl -fsSL --proto '=https' --tlsv1.2 -o "$work/keyring.gpg" "$base.noarmor.gpg" \
    || die "cannot download $base.noarmor.gpg; rerun chezmoi apply to retry"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$work/tailscale.list" "$base.tailscale-keyring.list" \
    || die "cannot download $base.tailscale-keyring.list; rerun chezmoi apply to retry"
  sudo install -D -m 0644 "$work/keyring.gpg" "$keyring"
  sudo install -D -m 0644 "$work/tailscale.list" "$sources_list"

  for attempt in $(seq 60); do
    sudo apt-get update && break
    ((attempt < 60)) || die 'apt-get update failed; rerun chezmoi apply to retry'
    sleep 10
  done
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y tailscale \
    || die 'cannot install tailscale with apt-get; rerun chezmoi apply to retry'
}

tries=1
if ! command -v tailscale >/dev/null; then
  install_tailscale
  # The package starts tailscaled through systemd; give it a moment.
  tries=10
fi

prefs=
for _ in $(seq "$tries"); do
  prefs="$(tailscale debug prefs 2>/dev/null)" && break
  prefs=
  sleep 1
done
[[ -n "$prefs" ]] || die 'tailscaled is not reachable; check systemctl status tailscaled'

if [[ "$(jq -r '.OperatorUser // ""' <<<"$prefs")" != "$USER" ]]; then
  sudo tailscale set --operator="$USER"
fi

if ! jq -e '.RouteAll and .CorpDNS and .ShieldsUp' <<<"$prefs" >/dev/null; then
  tailscale set "${pref_flags[@]}"
fi

state="$(tailscale status --json | jq -r '.BackendState')"
case "$state" in
  NeedsLogin | NoState)
    say "sign in to the work tailnet with your work account: tailscale up --operator=$USER ${pref_flags[*]}"
    ;;
esac
