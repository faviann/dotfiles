#!/usr/bin/env bash

# test_cases is the suite-owned public case registry.
# shellcheck disable=SC2154
suite_dispatch() {
  local pass_message="$1"
  local requested_case
  local test_case
  shift

  if (( $# == 1 )) && [[ "$1" == --list ]]; then
    printf '%s\n' "${test_cases[@]}"
    return 0
  fi

  if (( $# == 2 )) && [[ "$1" == --case && -n "$2" ]]; then
    requested_case="$2"
    for test_case in "${test_cases[@]}"; do
      if [[ "$test_case" == "$requested_case" ]]; then
        "$test_case"
        trap - RETURN
        printf 'PASS: %s\n' "$pass_message"
        return 0
      fi
    done
    printf 'ERROR: unknown test case: %s\n' "$requested_case" >&2
    return 2
  fi

  if (( $# != 0 )); then
    printf 'Usage: %s [--list | --case EXACT_NAME]\n' "$0" >&2
    return 2
  fi

  for test_case in "${test_cases[@]}"; do
    "$test_case"
    trap - RETURN
  done
  printf 'PASS: %s\n' "$pass_message"
}
