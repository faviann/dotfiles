#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

PRIVATE_KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nZml4dHVyZQ==\n-----END OPENSSH PRIVATE KEY-----'
PUBLIC_KEY='ssh-ed25519 AAAAfixture ansible-control@workstation'

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  export ITEM="$BATS_TEST_TMPDIR/item.json"
  local bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$bin"
  cat >"$bin/bw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == 'get item dotfiles/proxmox-lxc-ssh-key' ]] || exit 64
cat "$ITEM"
STUB
  sed -i "1c #!$(command -v bash)" "$bin/bw"
  chmod +x "$bin/bw"
  export PATH="$bin:$PATH"
}

write_item() {
  local notes="$1"

  jq -n --arg notes "$notes" --arg public_key "$PUBLIC_KEY" '{
    name: "dotfiles/proxmox-lxc-ssh-key",
    notes: $notes,
    fields: [{name: "public_key", value: $public_key, type: 0}]
  }' >"$ITEM"
}

apply_controller_key() {
  local destination_dir="$1"
  local runtime_dir="$BATS_TEST_TMPDIR/runtime"

  mkdir -p "$destination_dir/.ansible" "$runtime_dir"
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
    --override-data '{"is_workstation":false}' \
    apply --force "$destination_dir/.ansible/ssh"
}

@test "test_controller_key_pair_renders_from_bitwarden_with_owner_only_private_key" {
  local notes
  local home

  for notes in "$PRIVATE_KEY" "$PRIVATE_KEY"$'\n' "$PRIVATE_KEY"$'\n\n'; do
    home="$(mktemp -d)"
    write_item "$notes"

    apply_controller_key "$home"

    cmp -s "$home/.ansible/ssh/proxmox_lxc" <(printf '%s\n' "$PRIVATE_KEY") \
      || fail 'private key does not end in exactly one newline'
    cmp -s "$home/.ansible/ssh/proxmox_lxc.pub" <(printf '%s\n' "$PUBLIC_KEY") \
      || fail 'public key does not come from the public_key field'
    [[ "$(stat -c %a "$home/.ansible/ssh")" == 700 ]] \
      || fail 'controller key directory is not owner-only'
    [[ "$(stat -c %a "$home/.ansible/ssh/proxmox_lxc")" == 600 ]] \
      || fail 'controller private key is not owner-only'
  done
}
