#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

readonly behavioral_suites=(
  workstation-login.bash
  chezmoi-target-inventory.bash
  update-agent-tools-check.bash
  workstation-agent-tools-bootstrap.bash
  workstation-collie-forwarder.bash
  workstation-moraine.bash
  workstation-skills-bootstrap.bash
  workstation-update.bash
)

expected_cases() {
  case "$1" in
    workstation-login.bash)
      printf '%s\n' \
        test_regular_ssh_login_reports_actionable_freshness_before_shell_ready \
        test_healthy_ssh_login_is_silent \
        test_login_profile_loads_required_shell_environment_without_bashrc \
        test_missing_login_command_warns_without_blocking_shell \
        test_missing_freshness_checker_warns_without_blocking_shell \
        test_failed_freshness_checker_warns_on_every_login \
        test_ineligible_login_contexts_skip_freshness \
        test_kitty_ssh_injection_loads_the_managed_login_profile_once
      ;;
    chezmoi-target-inventory.bash)
      printf '%s\n' \
        test_repository_only_paths_are_ignored \
        test_fish_is_ignored_only_on_the_configured_workstation \
        test_dry_run_proposes_only_intentional_targets
      ;;
    update-agent-tools-check.bash)
      printf '%s\n' \
        test_managed_npm_inventory_drives_install_and_version_checks \
        test_machine_status_reports_current_by_exit_status_without_output \
        test_machine_status_reports_outdated_by_exit_status_without_output \
        test_machine_status_reports_discovery_failure_and_preserves_freshness_state \
        test_machine_status_reports_unresolved_activation_failure_as_maintenance_needed \
        test_conditional_update_leaves_current_toolchain_and_acp_workers_alone \
        test_conditional_update_stops_before_mutation_when_discovery_fails \
        test_conditional_update_refreshes_the_whole_toolchain_when_outdated \
        test_conditional_update_requires_yes_for_unattended_acp_disruption \
        test_conditional_update_yes_authorizes_only_acp_disruption \
        test_conditional_interactive_update_prompts_once_for_acp_disruption \
        test_conditional_update_retries_a_current_toolchain_after_activation_failure \
        test_conditional_update_retries_after_pre_activation_failure_makes_versions_current \
        test_due_check_runs_once_per_success_interval \
        test_internal_freshness_interface_reuses_cache_without_a_subordinate_action \
        test_internal_freshness_interface_does_not_wait_for_maintenance \
        test_internal_timeout_record_preserves_last_successful_result \
        test_state_uses_local_state_fallback \
        test_state_writes_replace_the_state_file_atomically \
        test_concurrent_due_checks_are_serialized \
        test_update_and_check_modes_share_the_state_lock \
        test_failed_check_preserves_cache_and_retries_after_one_hour \
        test_malformed_aoe_release_is_a_failed_check \
        test_empty_npm_version_is_a_failed_check \
        test_npm_registry_failure_preserves_cache_and_retries_after_one_hour \
        test_current_toolchain_is_silent \
        test_outdated_components_report_exact_versions \
        test_missing_components_are_reported \
        test_nested_codex_runtime_is_a_distinct_scope \
        test_nested_codex_uses_latest_adapter_compatible_target \
        test_nested_codex_accepts_a_single_compatible_version \
        test_nested_codex_ignores_compatible_prereleases \
        test_default_update_refreshes_and_activates_the_complete_toolchain \
        test_interactive_update_without_running_workers_does_not_prompt \
        test_noninteractive_update_with_running_workers_requires_yes \
        test_yes_authorizes_noninteractive_update_with_running_workers \
        test_interactive_decline_happens_once_before_mutation \
        test_workers_are_reconciled_by_identity_after_pre_activation_verification \
        test_temporarily_unregistered_worker_is_reconciled_without_restart \
        test_coexisting_old_and_replacement_identities_fail_health_without_restarting_again \
        test_each_worker_restart_decision_uses_a_fresh_identity_snapshot \
        test_worker_replacement_health_failure_is_bounded_and_not_successful \
        test_final_service_health_failure_after_worker_replacement_is_bounded \
        test_partial_install_does_not_restart_the_service \
        test_default_update_removes_stale_cli_shims_before_npm_refresh \
        test_pre_activation_diagnostics_failure_does_not_restart_the_service \
        test_pre_activation_command_resolution_failure_does_not_restart_the_service \
        test_pre_activation_version_failure_does_not_restart_the_service \
        test_pre_activation_empty_package_inventory_names_its_component \
        test_pre_activation_registry_failure_names_the_managed_component \
        test_post_activation_failure_retains_failure_without_rollback \
        test_activation_failure_is_recovered_by_a_full_rerun \
        test_standalone_and_bundled_codex_remain_separate_on_update \
        test_outdated_bun_runtime_is_installed_before_the_harnesses \
        test_missing_bun_runtime_is_reported_and_installed \
        test_bun_archive_digest_mismatch_stops_before_the_harnesses_change \
        test_bun_archive_matches_the_host_instruction_set \
        test_harness_node_floor_above_the_profile_stops_before_mutation \
        test_harness_bun_floor_above_the_latest_release_stops_before_mutation \
        test_unparsable_engine_range_does_not_block_the_update \
        test_engine_floor_refuses_a_direct_update_before_any_change \
        test_current_bun_is_not_redownloaded \
        test_bun_release_metadata_failure_is_a_failed_check \
        test_bun_archive_download_failure_stops_before_the_harnesses_change \
        test_abandoned_bun_work_directories_are_swept \
        test_unreadable_engine_metadata_refuses_before_mutation \
        test_absent_engine_declaration_does_not_block_the_update
      ;;
    workstation-agent-tools-bootstrap.bash)
      printf '%s\n' \
        test_missing_tools_are_installed_by_the_bootstrap_handoff \
        test_complete_toolchain_is_not_refreshed_during_bootstrap \
        test_missing_new_harnesses_are_repaired_by_the_bootstrap_handoff \
        test_bootstrap_handoff_runs_after_the_profile_exists \
        test_updater_host_tools_are_reachable_from_the_bootstrap_handoff \
        test_bootstrap_handoff_keeps_system_directories_for_systemctl \
        test_failed_install_fails_the_bootstrap_handoff
      ;;
    workstation-collie-forwarder.bash)
      printf '%s\n' \
        test_workstation_profile_includes_dotnet_10_lts_sdk \
        test_collie_origin_socket_listens_on_the_portal_origin_port \
        test_collie_origin_socket_activates_with_normal_user_sockets \
        test_collie_origin_forwarder_connects_to_the_loopback_bridge \
        test_collie_origin_forwarder_has_no_collie_service_dependency_or_fallback \
        test_aoe_serve_pulls_up_its_origin_socket \
        test_collie_service_drop_in_pulls_up_its_origin_socket \
        test_existing_aoe_forwarder_rendering_is_unchanged
      ;;
    workstation-moraine.bash)
      printf '%s\n' \
        test_moraine_profile_uses_one_integrity_pinned_release_bundle \
        test_moraine_configures_codex_and_claude_sources_with_backfill \
        test_moraine_config_keeps_redaction_and_the_default_local_topology \
        test_moraine_service_owns_and_restarts_the_upstream_stack \
        test_moraine_leaves_user_codex_configuration_unmanaged
      ;;
    workstation-skills-bootstrap.bash)
      printf '%s\n' \
        test_missing_checkout_is_cloned_and_reconciled \
        test_existing_checkout_is_preserved_and_idempotent \
        test_invalid_existing_path_fails_without_reconciliation \
        test_clone_and_reconciler_failures_propagate \
        test_reconciler_cannot_read_the_unlocked_vault_session \
        test_non_lxc_render_is_a_noop
      ;;
    workstation-update.bash)
      printf '%s\n' \
        test_freshness_combines_dotfiles_and_agent_updates_without_mutation \
        test_freshness_always_reports_local_blockers_and_incomplete_maintenance \
        test_freshness_treats_unapplied_dotfiles_as_retryable_maintenance \
        test_freshness_sources_age_independently \
        test_freshness_failures_retain_each_source_result \
        test_due_freshness_sources_run_concurrently \
        test_hard_freshness_timeout_is_generic_fail_open_and_non_corrupting \
        test_hard_freshness_timeout_bounds_stalled_local_preflight \
        test_freshness_infrastructure_failure_is_not_reported_as_timeout \
        test_freshness_lock_contention_warns_instead_of_claiming_healthy \
        test_freshness_history_blockers_are_local_when_fetch_fails \
        test_freshness_git_reads_do_not_refresh_the_index \
        test_freshness_accumulates_independent_local_blockers \
        test_setup_must_be_complete_before_source_discovery \
        test_first_run_adopts_verified_equal_history \
        test_current_agent_tools_are_checked_without_mutation \
        test_successful_update_reports_progress_and_completion \
        test_required_apply_unlocks_bitwarden_once_for_all_chezmoi_phases \
        test_required_apply_reuses_an_existing_bitwarden_session_without_prompting \
        test_post_apply_verification_does_not_rerun_lifecycle_scripts \
        test_noninteractive_apply_requires_a_pre_unlocked_bitwarden_session \
        test_yes_forwards_only_agent_disruption_consent \
        test_agent_consent_refusal_names_only_the_unified_retry \
        test_agent_discovery_failure_preserves_applied_dotfiles_for_retry \
        test_concurrent_update_is_rejected_without_queueing \
        test_outdated_agent_tools_use_the_latest_verified_updater \
        test_dotfiles_work_delegates_workstation_configuration_to_setup \
        test_source_only_change_still_delegates_workstation_configuration \
        test_current_workstation_does_not_delegate_workstation_configuration \
        test_workstation_configuration_failure_stops_before_agent_tools \
        test_agent_update_failure_retries_without_reapplying_dotfiles \
        test_unsupported_arguments_fail_before_maintenance \
        test_dotfiles_failure_prevents_agent_tool_checks \
        test_repository_structure_is_validated_before_fetch \
        test_all_source_extras_and_unfinished_operations_are_preserved \
        test_fetch_and_unsafe_history_fail_diagnostically \
        test_behind_history_fast_forwards_then_applies_in_order \
        test_failed_ref_transaction_is_safe_to_retry \
        test_missing_maintenance_executable_enters_the_apply_path \
        test_drifted_maintenance_executable_enters_the_apply_path \
        test_matching_marker_does_not_reconcile_unrelated_target_drift \
        test_first_run_with_drift_enters_the_apply_path \
        test_unattended_overwrite_and_phase_failures_preserve_the_marker \
        test_dry_run_and_verification_failures_are_safe_to_retry
      ;;
    *) fail "no expected cases for $1" ;;
  esac
}

test_every_suite_lists_all_case_names() {
  local suite
  local listed_cases
  local all_cases

  all_cases="$(mktemp)"
  trap 'rm -f "$all_cases"' RETURN
  for suite in "${behavioral_suites[@]}"; do
    listed_cases="$(bash "$REPO_ROOT/tests/$suite" --list)" \
      || fail "$suite --list exited nonzero"
    diff -u \
      <(expected_cases "$suite") \
      <(printf '%s\n' "$listed_cases") \
      || fail "$suite --list did not expose its complete case set"
    printf '%s\n' "$listed_cases" >>"$all_cases"
  done

  [[ -z "$(sort "$all_cases" | uniq -d)" ]] \
    || fail 'case names are ambiguous across suites'
}

test_every_suite_preserves_no_argument_full_run() {
  local specification
  local suite
  local pass_line
  local output

  for specification in \
    'workstation-login.bash|PASS: workstation SSH login freshness' \
    'chezmoi-target-inventory.bash|PASS: chezmoi target inventory' \
    'update-agent-tools-check.bash|PASS: update-agent-tools --check' \
    'workstation-agent-tools-bootstrap.bash|PASS: workstation agent-tool bootstrap handoff' \
    'workstation-collie-forwarder.bash|PASS: workstation Collie runtime and origin forwarder' \
    'workstation-moraine.bash|PASS: workstation-local Moraine producer' \
    'workstation-skills-bootstrap.bash|PASS: workstation skills bootstrap' \
    'workstation-update.bash|PASS: workstation update'; do
    IFS='|' read -r suite pass_line <<<"$specification"
    output="$(bash "$REPO_ROOT/tests/$suite")" \
      || fail "$suite no-argument full run exited nonzero"
    [[ "$output" == "$pass_line" ]] \
      || fail "$suite no-argument full run produced unexpected output: $output"
  done
}

test_every_suite_runs_one_exact_named_case() {
  local specification
  local suite
  local test_case
  local pass_line
  local output

  for specification in \
    'workstation-login.bash|test_healthy_ssh_login_is_silent|PASS: workstation SSH login freshness' \
    'chezmoi-target-inventory.bash|test_repository_only_paths_are_ignored|PASS: chezmoi target inventory' \
    'update-agent-tools-check.bash|test_machine_status_reports_current_by_exit_status_without_output|PASS: update-agent-tools --check' \
    'workstation-agent-tools-bootstrap.bash|test_failed_install_fails_the_bootstrap_handoff|PASS: workstation agent-tool bootstrap handoff' \
    'workstation-collie-forwarder.bash|test_collie_origin_socket_listens_on_the_portal_origin_port|PASS: workstation Collie runtime and origin forwarder' \
    'workstation-moraine.bash|test_moraine_config_keeps_redaction_and_the_default_local_topology|PASS: workstation-local Moraine producer' \
    'workstation-skills-bootstrap.bash|test_non_lxc_render_is_a_noop|PASS: workstation skills bootstrap' \
    'workstation-update.bash|test_unsupported_arguments_fail_before_maintenance|PASS: workstation update'; do
    IFS='|' read -r suite test_case pass_line <<<"$specification"
    output="$(bash "$REPO_ROOT/tests/$suite" --case "$test_case")" \
      || fail "$suite did not run exact case $test_case"
    [[ "$output" == "$pass_line" ]] \
      || fail "$suite exact case produced unexpected output: $output"
  done
}

assert_dispatch_fails_with() {
  local suite="$1"
  local expected_error="$2"
  local test_dir
  shift 2

  test_dir="$(mktemp -d)"
  if bash "$REPO_ROOT/tests/$suite" "$@" \
    >"$test_dir/stdout" 2>"$test_dir/stderr"; then
    fail "$suite accepted invalid invocation: $*"
  fi
  [[ ! -s "$test_dir/stdout" ]] \
    || fail "$suite produced success output for invalid invocation: $*"
  grep -Fq "$expected_error" "$test_dir/stderr" \
    || fail "$suite did not explain invalid invocation: $*"
  rm -rf "$test_dir"
}

test_unknown_and_malformed_invocations_fail_clearly() {
  local suite

  for suite in "${behavioral_suites[@]}"; do
    assert_dispatch_fails_with \
      "$suite" 'ERROR: unknown test case:' \
      --case definitely_not_a_test_case
    assert_dispatch_fails_with "$suite" 'Usage:' --case
    assert_dispatch_fails_with "$suite" 'Usage:' --case ''
    assert_dispatch_fails_with "$suite" 'Usage:' --list unexpected
    assert_dispatch_fails_with \
      "$suite" 'Usage:' test_healthy_ssh_login_is_silent
  done

  assert_dispatch_fails_with \
    update-agent-tools-check.bash 'ERROR: unknown test case:' \
    --case test_nested_codex
}

test_every_suite_lists_all_case_names
test_every_suite_preserves_no_argument_full_run
test_every_suite_runs_one_exact_named_case
test_unknown_and_malformed_invocations_fail_clearly

printf 'PASS: universal suite dispatch\n'
