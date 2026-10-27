#!/usr/bin/env bash
set -euo pipefail

readonly DOTFILES_REPO=https://github.com/faviann/dotfiles.git
readonly DOTFILES_REF="${DOTFILES_REF:-main}"
readonly BIN_DIR="$HOME/.local/bin"
readonly NIX_PROFILE_SCRIPT=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
readonly CHEZMOI_SOURCE="${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi"
readonly CHEZMOI_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi/chezmoi.toml"

readonly APT_PACKAGES=(git curl jq gh unzip)
readonly CHEZMOI_VERSION=2.73.3
readonly CHEZMOI_SHA256=6e5827598cbfc02d132b04f95b5ea10efb5b79230e2a4a0e52df4af144a8ee9f
readonly BW_VERSION=2026.10.0
readonly BW_SHA256=269b67559caab860d1737f7554b32bdb8be9285d5689fee55193c137a0df9973
readonly NIX_INSTALLER_VERSION=3.24.1
readonly NIX_INSTALLER_SHA256=c3866cc8ed9cf64546e77b5791160a87ec628467b17cd2746d3b2ed258262df6

readonly STEPS=(apt chezmoi bw bw_login bw_unlock nix nix_daemon chezmoi_init)

say() { printf 'bootstrap: %s\n' "$*"; }
die() {
  printf 'bootstrap: error: %s\n' "$*" >&2
  exit 1
}

download() {
  local url="$1" sha256="$2" dest="$3"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$dest" "$url" || die "cannot download $url"
  sha256sum --check --status <<<"$sha256  $dest" || die "checksum mismatch for $url"
}

load_nix() {
  if [[ -r "$NIX_PROFILE_SCRIPT" ]]; then
    set +u
    # shellcheck source=/dev/null
    . "$NIX_PROFILE_SCRIPT"
    set -u
  fi
}

apt_done() {
  local package
  for package in "${APT_PACKAGES[@]}"; do
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null)" == installed ]] || return 1
  done
}
apt_run() {
  sudo apt-get update || die 'apt-get update failed'
  sudo apt-get install -y "${APT_PACKAGES[@]}" \
    || die "cannot install ${APT_PACKAGES[*]} with apt-get"
}

chezmoi_done() { command -v chezmoi >/dev/null; }
chezmoi_run() {
  local archive="$work/chezmoi.tar.gz"
  download "https://github.com/twpayne/chezmoi/releases/download/v$CHEZMOI_VERSION/chezmoi_${CHEZMOI_VERSION}_linux_amd64.tar.gz" \
    "$CHEZMOI_SHA256" "$archive"
  tar -xzf "$archive" -C "$BIN_DIR" chezmoi || die "cannot extract chezmoi into $BIN_DIR"
}

bw_done() { command -v bw >/dev/null; }
bw_run() {
  local archive="$work/bw.zip"
  download "https://github.com/bitwarden/clients/releases/download/cli-v$BW_VERSION/bw-linux-$BW_VERSION.zip" \
    "$BW_SHA256" "$archive"
  unzip -o -q "$archive" bw -d "$BIN_DIR" || die "cannot extract bw into $BIN_DIR"
  chmod 755 "$BIN_DIR/bw"
}

bw_login_done() { bw login --check >/dev/null 2>&1; }
bw_login_run() {
  BW_SESSION="$(bw login --raw)" || die 'Bitwarden login failed; rerun this command to try again'
  export BW_SESSION
}

bw_unlock_done() { bw unlock --check >/dev/null 2>&1; }
bw_unlock_run() {
  BW_SESSION="$(bw unlock --raw)" || die 'Bitwarden unlock failed; rerun this command to try again'
  export BW_SESSION
  bw sync >/dev/null || die 'bw sync failed'
}

nix_done() { command -v nix >/dev/null; }
nix_run() {
  local installer="$work/nix-installer"
  local plan=()
  download "https://github.com/DeterminateSystems/nix-installer/releases/download/v$NIX_INSTALLER_VERSION/nix-installer-x86_64-linux" \
    "$NIX_INSTALLER_SHA256" "$installer"
  chmod 755 "$installer"
  [[ -d /run/systemd/system ]] || plan=(linux --init none)
  sudo "$installer" install "${plan[@]}" --no-confirm || die 'the Determinate Nix installer failed'
  load_nix
}

nix_daemon_done() { nix store info >/dev/null 2>&1; }
nix_daemon_run() {
  [[ ! -d /run/systemd/system ]] \
    || die 'nix cannot reach its daemon; check systemctl status nix-daemon.socket'
  sudo sh -c 'nohup /nix/var/nix/profiles/default/bin/nix-daemon >/var/log/nix-daemon.log 2>&1 &'
  local _
  for _ in $(seq 30); do
    nix_daemon_done && return
    sleep 1
  done
  die 'the Nix daemon did not start; see /var/log/nix-daemon.log'
}

chezmoi_init_done() { [[ -d "$CHEZMOI_SOURCE/.git" && -f "$CHEZMOI_CONFIG" ]]; }
chezmoi_init_run() {
  chezmoi init --branch "$DOTFILES_REF" "$DOTFILES_REPO" || die "chezmoi init of $DOTFILES_REF failed"
}

host="$(uname -n)"
[[ "${host%%.*}" != workstation ]] \
  || die 'this is the workstation, which homelab-iac provisions; run workstation-setup instead'
[[ "$(uname -m)" == x86_64 ]] || die 'only x86_64 is supported; the desktop Home Manager profile builds for x86_64-linux'
[[ "$(id -u)" != 0 ]] || die 'run this as your own user, not root; it calls sudo when it needs to'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"
load_nix

for step in "${STEPS[@]}"; do
  if "${step}_done"; then
    say "$step: already done"
  else
    say "$step: running"
    "${step}_run"
  fi
done

say 'chezmoi_apply: running'
chezmoi apply || die 'chezmoi apply failed; fix the error above, then rerun this command'

say 'done. Next steps:'
say '  Open a new terminal so it picks up Nix and the new PATH.'
say '  Run codex login to sign Codex in on this machine.'
