#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

PRIVATE_KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nZml4dHVyZQ==\n-----END OPENSSH PRIVATE KEY-----'
PUBLIC_KEY='ssh-ed25519 AAAAfixture ansible-control@workstation'
VAULT_PASS='fixture-vault-passphrase'

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  export ITEMS="$BATS_TEST_TMPDIR/items"
  local bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$bin" "$ITEMS"
  cat >"$bin/bw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2" == 'get item' ]] || exit 64
case "$3" in
  dotfiles/proxmox-lxc-ssh-key) cat "$ITEMS/controller-key.json" ;;
  dotfiles/ansible-vault-pass) cat "$ITEMS/vault-pass.json" ;;
  *) exit 64 ;;
esac
STUB
  sed -i "1c #!$(command -v bash)" "$bin/bw"
  chmod +x "$bin/bw"
  export PATH="$bin:$PATH"
  jq -n --arg notes "$VAULT_PASS" '{name: "dotfiles/ansible-vault-pass", notes: $notes}' \
    >"$ITEMS/vault-pass.json"
}

write_controller_key_item() {
  local notes="$1"

  jq -n --arg notes "$notes" --arg public_key "$PUBLIC_KEY" '{
    name: "dotfiles/proxmox-lxc-ssh-key",
    notes: $notes,
    fields: [{name: "public_key", value: $public_key, type: 0}]
  }' >"$ITEMS/controller-key.json"
}

apply_controller_files() {
  local profile="$1"
  local destination_dir="$2"
  local runtime_dir="$BATS_TEST_TMPDIR/runtime"

  mkdir -p "$destination_dir" "$runtime_dir"
  HOME="$destination_dir" \
  XDG_CACHE_HOME="$runtime_dir/cache" \
  XDG_CONFIG_HOME="$runtime_dir/config" \
  XDG_STATE_HOME="$runtime_dir/state" \
    chezmoi \
    --source "$REPO_ROOT" \
    --destination "$destination_dir" \
    --config /dev/null \
    --config-format toml \
    --persistent-state "$runtime_dir/chezmoistate.boltdb" \
    --override-data "{\"profile\":\"$profile\"}" \
    apply --force --recursive=false \
    "$destination_dir/.ansible" \
    "$destination_dir/.ansible/ssh" \
    "$destination_dir/.ansible/ssh/proxmox_lxc" \
    "$destination_dir/.ansible/ssh/proxmox_lxc.pub" \
    "$destination_dir/.ansible/vault-pass"
}

@test "test_controller_files_render_from_bitwarden_with_owner_only_secrets_on_every_profile" {
  local profile
  local notes
  local home

  for profile in workstation desktop; do
    for notes in "$PRIVATE_KEY" "$PRIVATE_KEY"$'\n' "$PRIVATE_KEY"$'\n\n'; do
      home="$(mktemp -d)"
      write_controller_key_item "$notes"

      apply_controller_files "$profile" "$home"

      cmp -s "$home/.ansible/ssh/proxmox_lxc" <(printf '%s\n' "$PRIVATE_KEY") \
        || fail "$profile: private key does not end in exactly one newline"
      cmp -s "$home/.ansible/ssh/proxmox_lxc.pub" <(printf '%s\n' "$PUBLIC_KEY") \
        || fail "$profile: public key does not come from the public_key field"
      cmp -s "$home/.ansible/vault-pass" <(printf '%s' "$VAULT_PASS") \
        || fail "$profile: vault passphrase does not come from the item notes"
      [[ "$(stat -c %a "$home/.ansible" "$home/.ansible/ssh")" == $'700\n700' ]] \
        || fail "$profile: controller directories are not owner-only"
      [[ "$(stat -c %a "$home/.ansible/ssh/proxmox_lxc" "$home/.ansible/vault-pass")" == $'600\n600' ]] \
        || fail "$profile: controller secrets are not owner-only"
    done
  done
}
