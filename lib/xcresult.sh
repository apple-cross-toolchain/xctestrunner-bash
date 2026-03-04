#!/usr/bin/env bash

xcresult_expose() {
  local xcresult_path="$1"
  local output_path="$2"

  if [ ! -d "$xcresult_path" ]; then
    return 0
  fi

  local root_json
  root_json=$(mktemp)
  track_temp_path "$root_json"

  if ! _xcresult_get_object_json "$xcresult_path" '' "$root_json"; then
    return 1
  fi

  local action_result_prefix
  action_result_prefix=$(_xcresult_find_first_action_result_prefix "$root_json") || return 1

  _xcresult_expose_diagnostics "$xcresult_path" "$output_path" "$root_json" "$action_result_prefix" || return 1
  _xcresult_expose_attachments "$xcresult_path" "$output_path" "$root_json" "$action_result_prefix" || return 1
}

_xcresult_expose_diagnostics() {
  local xcresult_path="$1"
  local output_path="$2"
  local action_json="$3"
  local action_result_prefix="$4"
  local diagnostics_id

  if ! json_file_has_key "$action_json" "${action_result_prefix}.diagnosticsRef.id._value"; then
    return 0
  fi

  diagnostics_id=$(json_file_get_raw "$action_json" "${action_result_prefix}.diagnosticsRef.id._value")
  _xcresult_export "$xcresult_path" "$output_path" 'directory' "$diagnostics_id"
}

_xcresult_expose_attachments() {
  local xcresult_path="$1"
  local output_path="$2"
  local action_json="$3"
  local action_result_prefix="$4"

  local tests_ref_id
  local test_plan_json

  if ! json_file_has_key "$action_json" "${action_result_prefix}.testsRef.id._value"; then
    return 0
  fi

  tests_ref_id=$(json_file_get_raw "$action_json" "${action_result_prefix}.testsRef.id._value")
  test_plan_json=$(mktemp)
  track_temp_path "$test_plan_json"
  _xcresult_get_object_json "$xcresult_path" "$tests_ref_id" "$test_plan_json" || return 1

  local root_tests_prefix='summaries._values.0.testableSummaries._values.0.tests._values.0'
  if ! json_file_has_key "$test_plan_json" "$root_tests_prefix"; then
    return 0
  fi

  local failure_ref
  while IFS= read -r failure_ref; do
    [ -n "$failure_ref" ] || continue
    _xcresult_expose_attachments_for_failure "$xcresult_path" "$output_path" "$failure_ref" || return 1
  done < <(_xcresult_collect_failure_test_refs "$test_plan_json" "$root_tests_prefix")
}

_xcresult_expose_attachments_for_failure() {
  local xcresult_path="$1"
  local output_path="$2"
  local failure_ref_id="$3"
  local summary_json

  summary_json=$(mktemp)
  track_temp_path "$summary_json"
  _xcresult_get_object_json "$xcresult_path" "$failure_ref_id" "$summary_json" || return 1

  if ! json_file_has_key "$summary_json" 'activitySummaries._values.0'; then
    return 0
  fi

  local test_identifier
  test_identifier=$(json_file_get_raw "$summary_json" 'identifier._value' 2>/dev/null || printf 'UnknownTest')

  local activity_idx=0
  local attachment_idx
  local filename
  local payload_ref_id
  local target_dir
  local target_file
  while json_file_has_key "$summary_json" "activitySummaries._values.${activity_idx}"; do
    if json_file_has_key "$summary_json" "activitySummaries._values.${activity_idx}.attachments._values.0"; then
      attachment_idx=0
      while json_file_has_key "$summary_json" "activitySummaries._values.${activity_idx}.attachments._values.${attachment_idx}"; do
        filename=$(json_file_get_raw "$summary_json" "activitySummaries._values.${activity_idx}.attachments._values.${attachment_idx}.filename._value" 2>/dev/null || printf '')
        payload_ref_id=$(json_file_get_raw "$summary_json" "activitySummaries._values.${activity_idx}.attachments._values.${attachment_idx}.payloadRef.id._value" 2>/dev/null || printf '')
        if [ -n "$filename" ] && [ -n "$payload_ref_id" ]; then
          target_dir="${output_path%/}/Attachments/${test_identifier}"
          mkdir -p "$target_dir"
          target_file="${target_dir%/}/${filename}"
          _xcresult_export "$xcresult_path" "$target_file" 'file' "$payload_ref_id" || return 1
        fi
        attachment_idx=$((attachment_idx + 1))
      done
    fi
    activity_idx=$((activity_idx + 1))
  done
}

_xcresult_collect_failure_test_refs() {
  local json_file="$1"
  local prefix="$2"

  local subtest_prefix
  local sub_idx=0

  if json_file_has_key "$json_file" "${prefix}.subtests._values.0"; then
    while json_file_has_key "$json_file" "${prefix}.subtests._values.${sub_idx}"; do
      subtest_prefix="${prefix}.subtests._values.${sub_idx}"
      _xcresult_collect_failure_test_refs "$json_file" "$subtest_prefix"
      sub_idx=$((sub_idx + 1))
    done
    return 0
  fi

  local test_status=''
  local summary_ref=''

  if json_file_has_key "$json_file" "${prefix}.testStatus._value"; then
    test_status=$(json_file_get_raw "$json_file" "${prefix}.testStatus._value" 2>/dev/null || printf '')
  fi

  if json_file_has_key "$json_file" "${prefix}.summaryRef.id._value"; then
    summary_ref=$(json_file_get_raw "$json_file" "${prefix}.summaryRef.id._value" 2>/dev/null || printf '')
  fi

  if [ -n "$summary_ref" ] && [ "$test_status" != 'Success' ]; then
    printf '%s\n' "$summary_ref"
  fi
}

_xcresult_find_first_action_result_prefix() {
  local json_file="$1"
  local idx=0
  local action_type

  while json_file_has_key "$json_file" "actions._values.${idx}"; do
    action_type=$(json_file_get_raw "$json_file" "actions._values.${idx}._type._name" 2>/dev/null || printf '')
    if [ "$action_type" = 'ActionRecord' ]; then
      printf '%s\n' "actions._values.${idx}.actionResult"
      return 0
    fi
    idx=$((idx + 1))
  done

  fatal 'Failed to find ActionRecord in xcresult.' || return 1
}

_xcresult_get_object_json() {
  local xcresult_path="$1"
  local bundle_id="$2"
  local out_json_file="$3"
  local -a cmd

  cmd=(get --format json --path "$xcresult_path")
  if [ -n "$bundle_id" ]; then
    cmd+=(--id "$bundle_id")
  fi

  _xcresulttool "${cmd[@]}" >"$out_json_file"
}

_xcresult_export() {
  local xcresult_path="$1"
  local output_path="$2"
  local export_type="$3"
  local ref_id="$4"

  _xcresulttool export \
    --path "$xcresult_path" \
    --output-path "$output_path" \
    --type "$export_type" \
    --id "$ref_id"
}

_xcresulttool() {
  local -a cmd
  local xcode_version

  cmd=(xcrun xcresulttool "$@")
  xcode_version=$(get_xcode_version_number)
  if [ "$xcode_version" -ge 1600 ]; then
    cmd+=(--legacy)
  fi

  "${cmd[@]}"
}
