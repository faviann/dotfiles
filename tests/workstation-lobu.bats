#!/usr/bin/env bats
set -euo pipefail

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
readonly REPO_ROOT

setup() {
  export TMPDIR="$BATS_TEST_TMPDIR"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

rendered_lobu() {
  if [[ -n "${TEST_WORKSTATION_RENDERED_CONFIGURATION:-}" ]]; then
    jq -c '{service: .lobuService, bootstrap: .lobuBootstrap}' \
      "$TEST_WORKSTATION_RENDERED_CONFIGURATION"
  else
    nix eval --json "$REPO_ROOT#homeConfigurations.workstation.config" \
      --apply 'c: { service = c.systemd.user.services.lobu; bootstrap = c.home.activation.bootstrapLobu; }'
  fi
}

make_fixture() {
  local fixture="$1"
  mkdir -p "$fixture/home/.local/bin" "$fixture/bin"
  printf '#!%s\n' "$(command -v bash)" >"$fixture/bin/npm"
  cat >>"$fixture/bin/npm" <<'STUB'
set -euo pipefail
printf '%s\n' "$@" >>"$HOME/npm-arguments"
[[ "${FAIL_INSTALL:-0}" == 0 ]] || exit 23
[[ "${OMIT_EXECUTABLE:-0}" == 0 ]] || exit 0
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/lobu"
chmod +x "$HOME/.local/bin/lobu"
STUB
  chmod +x "$fixture/bin/npm"
}

run_bootstrap() {
  local fixture="$1"
  shift
  env HOME="$fixture/home" PATH="$fixture/bin:$PATH" "$@" \
    bash "$REPO_ROOT/scripts/lobu-bootstrap"
}

@test "test_lobu_bootstrap_installs_missing_cli_without_initializing_state" {
  local fixture
  fixture="$(mktemp -d)"
  make_fixture "$fixture"
  run_bootstrap "$fixture" || fail 'bootstrap failed'
  diff -u <(printf '%s\n' install --global --prefix "$fixture/home/.local" \
    --engine-strict @lobu/cli@latest) "$fixture/home/npm-arguments" \
    || fail 'bootstrap did not use the intended package, prefix, and engine policy'
  [[ -x "$fixture/home/.local/bin/lobu" ]] || fail 'CLI missing'
  [[ ! -e "$fixture/home/.config/lobu" ]] || fail 'bootstrap initialized Lobu state'
}

@test "test_lobu_bootstrap_preserves_an_existing_installation" {
  local fixture
  fixture="$(mktemp -d)"
  make_fixture "$fixture"
  printf '#!/bin/sh\nexit 42\n' >"$fixture/home/.local/bin/lobu"
  chmod +x "$fixture/home/.local/bin/lobu"
  run_bootstrap "$fixture" || fail 'existing installation was not accepted'
  [[ ! -e "$fixture/home/npm-arguments" ]] || fail 'existing CLI was upgraded'
  [[ ! -e "$fixture/home/.config/lobu" ]] || fail 'bootstrap initialized Lobu state'
}

@test "test_lobu_bootstrap_propagates_installation_failures" {
  local fixture status=0
  fixture="$(mktemp -d)"
  make_fixture "$fixture"
  run_bootstrap "$fixture" FAIL_INSTALL=1 || status=$?
  [[ "$status" == 23 ]] || fail 'npm failure was swallowed'
  if run_bootstrap "$fixture" OMIT_EXECUTABLE=1; then
    fail 'bootstrap accepted a missing executable after npm success'
  fi
}

@test "test_lobu_activation_orders_installation_and_honors_dry_runs" {
  local fixture rendered activation
  fixture="$(mktemp -d)"
  rendered="$(rendered_lobu)"
  jq -e '
    (.bootstrap.after | index("installPackages") != null) and
    (.bootstrap.before | index("reloadSystemd") != null)
  ' <<<"$rendered" >/dev/null || fail 'unsafe bootstrap ordering'
  activation="$(jq -r '.bootstrap.data' <<<"$rendered")"
  # Exercise the rendered activation with the Home Manager dry-run contract:
  # run reports its command, without executing the installation.
  # shellcheck disable=SC2016
  env HOME="$fixture" ACTIVATION="$activation" bash -euo pipefail -c '
    run() { printf "%s\n" "$@" >"$HOME/dry-run-command"; }
    eval "$ACTIVATION"
  '
  [[ "$(cat "$fixture/dry-run-command")" == /nix/store/*/bin/lobu-bootstrap ]] \
    || fail 'activation did not delegate installation through run'
  [[ ! -e "$fixture/.local" && ! -e "$fixture/.config/lobu" ]] \
    || fail 'dry-run activation mutated the home'
}

@test "test_lobu_service_supervises_the_persistent_headless_device" {
  local rendered
  rendered="$(rendered_lobu)"
  jq -e '
    .service |
    (.Unit.ConditionPathExists == "%h/.config/lobu/credentials.json") and
    (.Service.Type == "simple") and
    (.Service.ExecStart == ["/home/faviann/.local/bin/lobu daemon --api-url https://app.lobu.ai --no-interactive-session"]) and
    (.Service.WorkingDirectory == "/home/faviann") and
    (.Service.Environment == [
      "HOME=/home/faviann",
      "PATH=/home/faviann/.local/bin:/home/faviann/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin"
    ]) and
    (.Service.UMask == "0077") and
    (.Service.Restart == "on-failure") and
    (.Service.RestartSec == 30) and
    (.Service.RestartSteps == null) and
    (.Service.RestartMaxDelaySec == null) and
    (.Install.WantedBy == ["default.target"])
  ' <<<"$rendered" >/dev/null || fail 'unexpected Lobu service contract'
}
