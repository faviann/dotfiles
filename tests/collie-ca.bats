#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

CA_KEY=$'-----BEGIN PRIVATE KEY-----\nZml4dHVyZS1rZXk=\n-----END PRIVATE KEY-----'
CA_CERTIFICATE='-----BEGIN CERTIFICATE-----
MIIBfjCCASWgAwIBAgIUL7PdjLSCakcQ/LEajuIusd+eR8wwCgYIKoZIzj0EAwIw
FTETMBEGA1UEAwwKZml4dHVyZS1jYTAeFw0yNjEwMjYyMzUzNTVaFw0yNjEwMjcy
MzUzNTVaMBUxEzARBgNVBAMMCmZpeHR1cmUtY2EwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAASu5Ng6eIxS6//RvmEXYJ58jhrwtc1IrEUULjUj1Br8rJynL85tpk4B
yerc18LCOtqcVQgFEoVP0L/H7xyAdt0zo1MwUTAdBgNVHQ4EFgQUnqoU7Q2hE9vh
m8qSRFGsIb4BijMwHwYDVR0jBBgwFoAUnqoU7Q2hE9vhm8qSRFGsIb4BijMwDwYD
VR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiA/wz2s8uVHLyqJgW43mAKh
iOclhbWwGegqxUhmGy00eQIgbfuwoPs6D8ugXj5SpimIjo64Jflc8yI07fTzN1Ei
9uM=
-----END CERTIFICATE-----'
FULL_LAST_LINE_CERTIFICATE='-----BEGIN CERTIFICATE-----
MIIBejCCAR+gAwIBAgIUYRXVl1008FzdX6SQA0+QCYCalHMwCgYIKoZIzj0EAwIw
EjEQMA4GA1UEAwwHZml4dHVyZTAeFw0yNjEwMjYyMzUzNDdaFw0yNjEwMjcyMzUz
NDdaMBIxEDAOBgNVBAMMB2ZpeHR1cmUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC
AAQ/K/+3EB1qq2cY+3oUEus14l2Smo2pSeYFC6zhDWVIRNNLaM9rcfaLVTeYY0z7
s5zzP2MtaINz0rbc7Qzz3/u+o1MwUTAdBgNVHQ4EFgQU63ljdqsjbQLgJNfdbcBq
Frnj1XYwHwYDVR0jBBgwFoAU63ljdqsjbQLgJNfdbcBqFrnj1XYwDwYDVR0TAQH/
BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAiFr0Ppc0YLZgAhAg78/FwCondZup
naEBHs/237OoQwsCIQCDSgQLSKzknL8Yp+wg2Xm0ZheXEamBtpnDXxkfhQXRyQ==
-----END CERTIFICATE-----'

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  export ITEM="$BATS_TEST_TMPDIR/item.json"
  HOME_DIR="$BATS_TEST_TMPDIR/home"
  local bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$bin" "$HOME_DIR/.ansible"
  cat >"$bin/bw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == 'get item dotfiles/collie-ca' ]] || exit 64
cat "$ITEM"
STUB
  sed -i "1c #!$(command -v bash)" "$bin/bw"
  chmod +x "$bin/bw"
  export PATH="$bin:$PATH"
  write_item "$CA_KEY"$'\n' "$CA_CERTIFICATE"$'\n'
}

write_item() {
  jq -n --arg notes "$1" --arg certificate "$2" '{
    name: "dotfiles/collie-ca",
    notes: $notes,
    fields: [{name: "certificate", value: $certificate, type: 0}]
  }' >"$ITEM"
}

run_chezmoi() {
  local runtime_dir="$BATS_TEST_TMPDIR/runtime"

  mkdir -p "$runtime_dir"
  HOME="$HOME_DIR" \
  XDG_CACHE_HOME="$runtime_dir/cache" \
  XDG_CONFIG_HOME="$runtime_dir/config" \
  XDG_STATE_HOME="$runtime_dir/state" \
    chezmoi \
    --source "$REPO_ROOT" \
    --destination "$HOME_DIR" \
    --config /dev/null \
    --config-format toml \
    --persistent-state "$runtime_dir/chezmoistate.boltdb" \
    --override-data '{"profile":"workstation"}' \
    "$@"
}

apply_collie_ca() {
  run_chezmoi apply --force "$HOME_DIR/.ansible/collie-ca"
}

@test "test_collie_ca_renders_owner_only_from_bitwarden_and_keeps_unmanaged_files" {
  mkdir -p "$HOME_DIR/.ansible/collie-ca"
  printf '1A2B\n' >"$HOME_DIR/.ansible/collie-ca/ca.srl"

  apply_collie_ca

  cmp -s "$HOME_DIR/.ansible/collie-ca/ca.key" <(printf '%s\n' "$CA_KEY") \
    || fail 'ca.key is not the Notes ending in exactly one newline'
  cmp -s "$HOME_DIR/.ansible/collie-ca/ca.crt" <(printf '%s\n' "$CA_CERTIFICATE") \
    || fail 'ca.crt is not the certificate field ending in exactly one newline'
  [[ "$(stat -c %a "$HOME_DIR/.ansible/collie-ca" \
    "$HOME_DIR/.ansible/collie-ca/ca.key" "$HOME_DIR/.ansible/collie-ca/ca.crt")" \
    == $'700\n600\n600' ]] || fail 'the Collie CA is not owner-only'
  [[ "$(cat "$HOME_DIR/.ansible/collie-ca/ca.srl")" == 1A2B ]] \
    || fail 'apply removed or changed the unmanaged ca.srl'
}

@test "test_certificate_renders_unchanged_with_or_without_its_line_breaks" {
  local certificate
  local field

  for certificate in "$CA_CERTIFICATE" "$FULL_LAST_LINE_CERTIFICATE"; do
    for field in "$certificate" "${certificate//$'\n'/}" "${certificate//$'\n'/ }" \
      "${certificate//$'\n'/$'\r\n'}"$'\r\n'; do
      write_item "$CA_KEY" "$field"

      apply_collie_ca

      cmp -s "$HOME_DIR/.ansible/collie-ca/ca.crt" <(printf '%s\n' "$certificate") \
        || fail "ca.crt is not the original PEM for field $(jq -Rs . <<<"$field"): $(cat "$HOME_DIR/.ansible/collie-ca/ca.crt")"
    done
  done
}

@test "test_non_pem_certificate_fails_and_keeps_the_existing_certificate" {
  local field

  mkdir -p "$HOME_DIR/.ansible/collie-ca"
  printf 'existing certificate\n' >"$HOME_DIR/.ansible/collie-ca/ca.crt"

  for field in 'not a certificate' "$CA_KEY" \
    $'-----BEGIN CERTIFICATE-----\nnot*base64\n-----END CERTIFICATE-----' \
    $'-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----'; do
    write_item "$CA_KEY" "$field"

    run apply_collie_ca

    [ "$status" -ne 0 ]
    [[ "$output" == *'Bitwarden item dotfiles/collie-ca must hold the PEM certificate in its certificate field'* ]]
    [[ "$(cat "$HOME_DIR/.ansible/collie-ca/ca.crt")" == 'existing certificate' ]] \
      || fail "a rejected certificate replaced ca.crt: $field"
  done
}

@test "test_flattened_or_missing_private_key_fails" {
  local notes

  for notes in "${CA_KEY//$'\n'/ }" "$CA_CERTIFICATE" ''; do
    write_item "$notes" "$CA_CERTIFICATE"
    run apply_collie_ca
    [ "$status" -ne 0 ]
    [[ "$output" == *'Bitwarden item dotfiles/collie-ca must hold the PEM private key, with its line breaks, in its Notes'* ]]
    [[ ! -e "$HOME_DIR/.ansible/collie-ca/ca.key" ]] || fail 'a rejected key wrote ca.key'
  done
}

@test "test_missing_certificate_field_fails_with_the_field_name" {
  jq -n --arg notes "$CA_KEY" '{name: "dotfiles/collie-ca", notes: $notes, fields: []}' >"$ITEM"

  run apply_collie_ca

  [ "$status" -ne 0 ]
  [[ "$output" == *'in its certificate field'* ]]
}

@test "test_collie_ca_is_secret_backed_for_workstation_update" {
  run_chezmoi dump --include files --skip-secrets --format json \
    | jq -e 'has(".ansible/collie-ca/ca.key") or has(".ansible/collie-ca/ca.crt") | not' >/dev/null \
    || fail 'the Collie CA renders without secrets, so workstation-update would overwrite it'
}
