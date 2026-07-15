#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly RUNNER="$REPO_ROOT/scripts/run-tests"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_fixture() {
  local fixture="$1"

  mkdir -p "$fixture/scripts" "$fixture/tests"
  cp "$RUNNER" "$fixture/scripts/run-tests"
}

write_suite() {
  local fixture="$1"
  local suite="$2"
  local first_case="$3"
  local second_case="$4"

  cat >"$fixture/tests/$suite" <<EOF
#!/usr/bin/env bash
set -euo pipefail

readonly test_cases=(
  $first_case
  $second_case
)

if (( \$# == 1 )) && [[ "\$1" == --list ]]; then
  printf '%s\\n' "\${test_cases[@]}"
  exit 0
fi

if (( \$# == 2 )) && [[ "\$1" == --case ]]; then
  for test_case in "\${test_cases[@]}"; do
    if [[ "\$test_case" == "\$2" ]]; then
      printf '%s:%s\\n' "$suite" "\$test_case" >>"\$INVOCATION_LOG"
      printf 'PASS: %s\\n' "\$test_case"
      exit 0
    fi
  done
  printf 'ERROR: unknown test case: %s\\n' "\$2" >&2
  exit 2
fi

if (( \$# != 0 )); then
  printf 'Usage: %s [--list | --case EXACT_NAME]\\n' "\$0" >&2
  exit 2
fi

printf '%s:all\\n' "$suite" >>"\$INVOCATION_LOG"
printf 'PASS: %s\\n' "$suite"
EOF
  chmod +x "$fixture/tests/$suite"
}

write_gated_suite() {
  local fixture="$1"
  local suite="$2"
  local test_case="$3"
  local status="$4"
  local raw_output="$5"

  cat >"$fixture/tests/$suite" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if (( \$# == 1 )) && [[ "\$1" == --list ]]; then
  printf '%s\\n' "$test_case"
  exit 0
fi

if (( \$# != 0 )); then
  printf 'Usage: %s [--list]\\n' "\$0" >&2
  exit 2
fi

printf '%s:all\\n' "$suite" >>"\$INVOCATION_LOG"
: >"\$START_DIR/$suite"
while [[ ! -e "\$RELEASE_FILE" ]]; do
  sleep 0.01
done
printf '%s\\n' "$raw_output"
exit $status
EOF
  chmod +x "$fixture/tests/$suite"
}

wait_for_file() {
  local path="$1"
  local attempts=0

  while [[ ! -e "$path" ]]; do
    attempts=$((attempts + 1))
    (( attempts < 500 )) || return 1
    sleep 0.01
  done
}

write_interruptible_suite() {
  local fixture="$1"
  local suite="$2"
  local test_case="$3"

  cat >"$fixture/tests/$suite.worker" <<EOF
#!/usr/bin/env bash
set -euo pipefail

printf '%s\\n' "\$BASHPID" >"\$CONTROL_DIR/$suite.descendant.pid"
trap ': >"\$CONTROL_DIR/$suite.descendant.terminated"; exit 143' TERM
: >"\$CONTROL_DIR/$suite.descendant.started"
while :; do
  sleep 1
done
EOF
  chmod +x "$fixture/tests/$suite.worker"

  cat >"$fixture/tests/$suite" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if (( \$# == 1 )) && [[ "\$1" == --list ]]; then
  printf '%s\\n' "$test_case"
  exit 0
fi

if (( \$# != 0 )); then
  exit 2
fi

printf '%s\\n' "\$BASHPID" >"\$CONTROL_DIR/$suite.pid"
trap ': >"\$CONTROL_DIR/$suite.terminated"; exit 143' TERM
bash "\$(dirname "\$0")/$suite.worker" &
: >"\$CONTROL_DIR/$suite.started"
while :; do
  sleep 1
done
EOF
  chmod +x "$fixture/tests/$suite"
}

cleanup_interrupt_fixture() {
  local test_dir="$1"
  local pid_file
  local child_pid

  for pid_file in "$test_dir"/control/*.pid; do
    [[ -e "$pid_file" ]] || continue
    child_pid="$(<"$pid_file")"
    kill "$child_pid" 2>/dev/null || true
  done
  rm -rf "$test_dir"
}

assert_process_is_gone() {
  local pid_file="$1"
  local description="$2"
  local process_id

  process_id="$(<"$pid_file")"
  if kill -0 "$process_id" 2>/dev/null; then
    fail "$description is still running after interruption (pid $process_id)"
  fi
}

assert_runner_fails_with() {
  local fixture="$1"
  local expected_error="$2"
  shift 2

  if INVOCATION_LOG="$fixture/invocations" \
    bash "$fixture/scripts/run-tests" "$@" \
      >"$fixture/stdout" 2>"$fixture/stderr"; then
    fail "runner accepted invalid invocation: $*"
  fi
  [[ ! -s "$fixture/stdout" ]] \
    || fail "invalid invocation produced success output: $*"
  grep -Fq "$expected_error" "$fixture/stderr" \
    || fail "invalid invocation was not explained: $*"
  [[ ! -e "$fixture/invocations" ]] \
    || fail "invalid invocation started a suite: $*"
}

test_lists_suites_and_globally_unambiguous_cases() {
  local test_dir
  local output

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  write_suite "$test_dir" alpha.bash test_alpha_one test_alpha_two
  write_suite "$test_dir" beta.bash test_beta_one test_beta_two

  output="$(bash "$test_dir/scripts/run-tests" --list)" \
    || fail 'listing suites and cases exited nonzero'
  diff -u \
    <(printf '%s\n' \
      'Suites:' \
      'alpha.bash' \
      'beta.bash' \
      'Cases:' \
      'test_alpha_one' \
      'test_alpha_two' \
      'test_beta_one' \
      'test_beta_two') \
    <(printf '%s\n' "$output") \
    || fail 'listing did not expose every suite and globally unique case'
}

test_exact_suite_selection_runs_only_that_complete_suite() {
  local test_dir
  local output

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  write_suite "$test_dir" alpha.bash test_alpha_one test_alpha_two
  write_suite "$test_dir" beta.bash test_beta_one test_beta_two

  output="$(INVOCATION_LOG="$test_dir/invocations" \
    bash "$test_dir/scripts/run-tests" --suite beta.bash)" \
    || fail 'exact suite selection exited nonzero'
  [[ "$output" == 'PASS: beta.bash' ]] \
    || fail "exact suite selection produced unexpected output: $output"
  diff -u \
    <(printf 'beta.bash:all\n') \
    "$test_dir/invocations" \
    || fail 'exact suite selection invoked another suite or selected a case'
}

test_exact_case_selection_runs_only_its_owning_case() {
  local test_dir
  local output

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  write_suite "$test_dir" alpha.bash test_alpha_one test_alpha_two
  write_suite "$test_dir" beta.bash test_beta_one test_beta_two

  output="$(INVOCATION_LOG="$test_dir/invocations" \
    bash "$test_dir/scripts/run-tests" --case test_beta_two)" \
    || fail 'exact case selection exited nonzero'
  [[ "$output" == 'PASS: test_beta_two' ]] \
    || fail "exact case selection produced unexpected output: $output"
  diff -u \
    <(printf 'beta.bash:test_beta_two\n') \
    "$test_dir/invocations" \
    || fail 'exact case selection invoked another suite or case'
}

test_no_selector_starts_every_complete_suite_concurrently() {
  local test_dir
  local runner_pid

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  mkdir "$test_dir/started"
  write_gated_suite "$test_dir" alpha.bash test_alpha 0 'alpha raw output'
  write_gated_suite "$test_dir" beta.bash test_beta 0 'beta raw output'

  INVOCATION_LOG="$test_dir/invocations" \
    START_DIR="$test_dir/started" \
    RELEASE_FILE="$test_dir/release" \
    bash "$test_dir/scripts/run-tests" \
      >"$test_dir/stdout" 2>"$test_dir/stderr" &
  runner_pid=$!

  wait_for_file "$test_dir/started/alpha.bash" \
    || fail 'alpha suite did not start while the runner was active'
  wait_for_file "$test_dir/started/beta.bash" \
    || fail 'beta suite did not start before alpha was released'
  : >"$test_dir/release"
  wait "$runner_pid" \
    || fail "concurrent full run failed: $(<"$test_dir/stderr")"

  diff -u \
    <(printf '%s\n' 'alpha.bash:all' 'beta.bash:all') \
    <(sort "$test_dir/invocations") \
    || fail 'full run did not invoke each complete suite exactly once'
}

test_full_run_groups_failures_and_reports_every_outcome() {
  local test_dir
  local normalized_output

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  mkdir "$test_dir/started"
  : >"$test_dir/release"
  write_gated_suite "$test_dir" alpha.bash test_alpha 7 $'alpha line one\nalpha line two'
  write_gated_suite "$test_dir" beta.bash test_beta 0 'beta successful raw output'
  write_gated_suite "$test_dir" gamma.bash test_gamma 9 'gamma failure output'

  if INVOCATION_LOG="$test_dir/invocations" \
    START_DIR="$test_dir/started" \
    RELEASE_FILE="$test_dir/release" \
    bash "$test_dir/scripts/run-tests" \
      >"$test_dir/stdout" 2>"$test_dir/stderr"; then
    fail 'full run returned success despite failing suites'
  fi
  [[ ! -s "$test_dir/stderr" ]] \
    || fail "full run wrote unexpected stderr: $(<"$test_dir/stderr")"

  normalized_output="$(sed -E 's/[0-9]+ms/<duration>/g' "$test_dir/stdout")"
  diff -u \
    <(printf '%s\n' \
      'Failures:' \
      '===== alpha.bash (status 7) =====' \
      'alpha line one' \
      'alpha line two' \
      '===== end alpha.bash =====' \
      '===== gamma.bash (status 9) =====' \
      'gamma failure output' \
      '===== end gamma.bash =====' \
      'Results:' \
      'FAIL alpha.bash (<duration>, status 7)' \
      'PASS beta.bash (<duration>)' \
      'FAIL gamma.bash (<duration>, status 9)' \
      'Overall: FAIL (1 passed, 2 failed, <duration>)') \
    <(printf '%s\n' "$normalized_output") \
    || fail 'full-run output was not concise, grouped, deterministic, and complete'

  diff -u \
    <(printf '%s\n' 'alpha.bash:all' 'beta.bash:all' 'gamma.bash:all') \
    <(sort "$test_dir/invocations") \
    || fail 'a failing suite cancelled or skipped a peer'
}

test_interruption_terminates_suites_and_removes_temporary_logs() {
  local test_dir
  local runner_pid

  test_dir="$(mktemp -d)"
  trap 'cleanup_interrupt_fixture "$test_dir"' RETURN
  make_fixture "$test_dir"
  mkdir "$test_dir/control" "$test_dir/tmp"
  write_interruptible_suite "$test_dir" alpha.bash test_alpha
  write_interruptible_suite "$test_dir" beta.bash test_beta

  CONTROL_DIR="$test_dir/control" \
    TMPDIR="$test_dir/tmp" \
    bash "$test_dir/scripts/run-tests" \
      >"$test_dir/stdout" 2>"$test_dir/stderr" &
  runner_pid=$!
  wait_for_file "$test_dir/control/alpha.bash.started" \
    || fail 'alpha suite did not start before interruption'
  wait_for_file "$test_dir/control/beta.bash.started" \
    || fail 'beta suite did not start before interruption'
  wait_for_file "$test_dir/control/alpha.bash.descendant.started" \
    || fail 'alpha suite descendant did not start before interruption'
  wait_for_file "$test_dir/control/beta.bash.descendant.started" \
    || fail 'beta suite descendant did not start before interruption'

  kill -TERM "$runner_pid"
  if wait "$runner_pid"; then
    fail 'interrupted runner returned success'
  fi
  wait_for_file "$test_dir/control/alpha.bash.terminated" \
    || fail 'interruption did not terminate alpha suite'
  wait_for_file "$test_dir/control/beta.bash.terminated" \
    || fail 'interruption did not terminate beta suite'
  wait_for_file "$test_dir/control/alpha.bash.descendant.terminated" \
    || fail 'interruption did not terminate alpha suite descendant'
  wait_for_file "$test_dir/control/beta.bash.descendant.terminated" \
    || fail 'interruption did not terminate beta suite descendant'
  assert_process_is_gone \
    "$test_dir/control/alpha.bash.pid" 'alpha suite'
  assert_process_is_gone \
    "$test_dir/control/beta.bash.pid" 'beta suite'
  assert_process_is_gone \
    "$test_dir/control/alpha.bash.descendant.pid" 'alpha suite descendant'
  assert_process_is_gone \
    "$test_dir/control/beta.bash.descendant.pid" 'beta suite descendant'
  [[ -z "$(find "$test_dir/tmp" -mindepth 1 -print -quit)" ]] \
    || fail 'interruption left temporary logging state behind'
}

test_unknown_malformed_and_ambiguous_selectors_fail_clearly() {
  local test_dir

  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' RETURN
  make_fixture "$test_dir"
  write_suite "$test_dir" alpha.bash test_alpha_one test_alpha_two
  write_suite "$test_dir" beta.bash test_beta_one test_beta_two

  assert_runner_fails_with \
    "$test_dir" 'ERROR: unknown test suite: missing.bash' \
    --suite missing.bash
  assert_runner_fails_with \
    "$test_dir" 'ERROR: unknown test case: test_missing' \
    --case test_missing
  assert_runner_fails_with "$test_dir" 'Usage:' --suite
  assert_runner_fails_with "$test_dir" 'Usage:' --suite ''
  assert_runner_fails_with "$test_dir" 'Usage:' --case
  assert_runner_fails_with "$test_dir" 'Usage:' --case ''
  assert_runner_fails_with "$test_dir" 'Usage:' --list unexpected
  assert_runner_fails_with "$test_dir" 'Usage:' alpha.bash
  assert_runner_fails_with \
    "$test_dir" 'Usage:' --suite alpha.bash --case test_alpha_one

  rm "$test_dir/tests/beta.bash"
  write_suite "$test_dir" beta.bash test_alpha_one test_beta_two
  assert_runner_fails_with \
    "$test_dir" 'ERROR: ambiguous test case: test_alpha_one' \
    --list
}

test_lists_suites_and_globally_unambiguous_cases
test_exact_suite_selection_runs_only_that_complete_suite
test_exact_case_selection_runs_only_its_owning_case
test_no_selector_starts_every_complete_suite_concurrently
test_full_run_groups_failures_and_reports_every_outcome
test_interruption_terminates_suites_and_removes_temporary_logs
test_unknown_malformed_and_ambiguous_selectors_fail_clearly

printf 'PASS: parallel test runner\n'
