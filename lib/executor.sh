#!/usr/bin/env bash

xcodebuild_execute() {
  local sdk="$1"
  local test_type="$2"
  local device_id="$3"
  local succeeded_signal="$4"
  local failed_signal="$5"
  local app_bundle_id="$6"
  local startup_timeout_sec="$7"
  local result_bundle_path="$8"
  shift 8

  local -a command=("$@")
  local max_attempts=1
  local attempt

  if [ "$sdk" = "$SDK_IPHONESIMULATOR" ]; then
    max_attempts="$SIM_TEST_MAX_ATTEMPTS"
  elif [ "$sdk" = "$SDK_IPHONEOS" ]; then
    max_attempts="$DEVICE_TEST_MAX_ATTEMPTS"
  fi

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    log_info "Running xcodebuild attempt ${attempt}/${max_attempts}"

    if [ -n "$result_bundle_path" ] && [ -e "$result_bundle_path" ]; then
      safe_rm_rf "$result_bundle_path"
    fi

    local output_file
    local pipe_path
    local cmd_pid
    local reader_pid
    local cmd_status=0
    local test_started=0
    local is_stuck=0

    output_file=$(mktemp)
    pipe_path=$(mktemp -u)
    mkfifo "$pipe_path"
    track_temp_path "$output_file"
    track_temp_path "$pipe_path"

    : >"$output_file"

    (
      while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line"
        printf '%s\n' "$line" >>"$output_file"
      done <"$pipe_path"
    ) &
    reader_pid=$!

    set +e
    NSUnbufferedIO=YES "${command[@]}" >"$pipe_path" 2>&1 &
    cmd_pid=$!
    set -e

    local start_ts
    local now
    start_ts=$(now_epoch)

    while kill -0 "$cmd_pid" >/dev/null 2>&1; do
      if [ "$test_started" -eq 0 ]; then
        if grep -Fq "$TEST_STARTED_SIGNAL" "$output_file"; then
          test_started=1
        elif [ "$test_type" = "$TEST_TYPE_XCUITEST" ] &&
             [ "$sdk" = "$SDK_IPHONESIMULATOR" ] &&
             grep -Fq "$XCTRUNNER_STARTED_SIGNAL" "$output_file"; then
          test_started=1
        fi

        if [ "$test_started" -eq 0 ] && [ -n "$startup_timeout_sec" ] &&
           [ "$startup_timeout_sec" -gt 0 ]; then
          now=$(now_epoch)
          if [ $((now - start_ts)) -gt "$startup_timeout_sec" ]; then
            log_warn "xcodebuild appears stuck before test start (${startup_timeout_sec}s); terminating."
            is_stuck=1
            kill "$cmd_pid" >/dev/null 2>&1 || true
            break
          fi
        fi
      fi
      sleep 2
    done

    set +e
    wait "$cmd_pid"
    cmd_status=$?
    set -e

    wait "$reader_pid" >/dev/null 2>&1 || true

    local output_str
    output_str=$(cat "$output_file")

    _delete_test_cache_dirs "$output_file" "$sdk" "$test_type"

    if [ "$test_started" -eq 1 ]; then
      if grep -Fq "$succeeded_signal" "$output_file"; then
        return "$EXITCODE_SUCCEEDED"
      fi
      if grep -Fq "$failed_signal" "$output_file"; then
        return "$EXITCODE_FAILED"
      fi
      return "$EXITCODE_ERROR"
    fi

    if [ "$is_stuck" -eq 1 ]; then
      if [ "$sdk" = "$SDK_IPHONESIMULATOR" ] && [ "$attempt" -lt "$max_attempts" ]; then
        log_warn "xcodebuild stuck on simulator, rebooting simulator and retrying."
        sim_shutdown "$device_id" >/dev/null 2>&1 || true
        sim_boot "$device_id" >/dev/null 2>&1 || true
        sleep 2
        continue
      fi
      if [ "$sdk" = "$SDK_IPHONEOS" ]; then
        return "$EXITCODE_NEED_REBOOT_DEVICE"
      fi
      return "$EXITCODE_TEST_NOT_START"
    fi

    if [[ "$output_str" == *"${BUNDLE_DAMAGED}"* ]]; then
      return "$EXITCODE_TEST_NOT_START"
    fi

    if [ "$sdk" = "$SDK_IPHONEOS" ]; then
      if _need_retry_for_device_testing "$output_str" && [ "$attempt" -lt "$max_attempts" ]; then
        log_warn 'Failed to launch test on device, retrying in 5s.'
        sleep 5
        continue
      fi
      if [[ "$output_str" == *"${TOO_MANY_INSTANCES_ALREADY_RUNNING}"* ]]; then
        return "$EXITCODE_NEED_REBOOT_DEVICE"
      fi
    fi

    if [ "$sdk" = "$SDK_IPHONESIMULATOR" ]; then
      if _need_reboot_sim "$output_str" "$test_type"; then
        return "$EXITCODE_NEED_REBOOT_DEVICE"
      fi
      if _need_recreate_sim "$output_str"; then
        return "$EXITCODE_NEED_RECREATE_SIM"
      fi

      if _need_retry_for_sim_testing "$output_str" "$app_bundle_id" "$device_id" "$test_type"; then
        if [ "$attempt" -lt "$max_attempts" ]; then
          log_warn 'Failed to launch test on simulator; retrying.'
          continue
        fi
      fi
    fi

    log_debug "xcodebuild command exit status: ${cmd_status}"
    return "$EXITCODE_TEST_NOT_START"
  done

  return "$EXITCODE_TEST_NOT_START"
}

_need_reboot_sim() {
  local output_str="$1"
  local test_type="$2"
  if [ "$test_type" = "$TEST_TYPE_XCUITEST" ] &&
     [[ "$output_str" == *"${BACKGROUND_TEST_RUNNER_ERROR}"* ]]; then
    return 0
  fi
  return 1
}

_need_recreate_sim() {
  local output_str="$1"
  if printf '%s\n' "$output_str" | grep -E 'Application ".*" is unknown to FrontBoard\.' >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$output_str" == *"${REQUEST_DENIED_ERROR}"* ]]; then
    return 0
  fi
  if [[ "$output_str" == *"${INIT_SIM_SERVICE_ERROR}"* ]]; then
    return 0
  fi
  return 1
}

_need_retry_for_device_testing() {
  local output_str="$1"
  if [[ "$output_str" == *"${DEVICE_TYPE_WAS_NULL_ERROR}"* ]]; then
    return 0
  fi
  if [[ "$output_str" == *"${LOST_CONNECTION_ERROR}"* ]]; then
    return 0
  fi
  if [[ "$output_str" == *"${LOST_CONNECTION_TO_DTSERVICEHUB_ERROR}"* ]]; then
    return 0
  fi
  if [[ "$output_str" == *"${DEVICE_NO_LONGER_CONNECTED}"* ]]; then
    return 0
  fi
  if [[ "$output_str" == *"${UNABLE_FIND_DEVICE_IDENTIFIER}"* ]]; then
    return 0
  fi
  return 1
}

_need_retry_for_sim_testing() {
  local output_str="$1"
  local app_bundle_id="$2"
  local device_id="$3"
  local test_type="$4"
  local sim_log_path
  local tail_log

  if [[ "$output_str" == *"${PROCESS_EXITED_OR_CRASHED_ERROR}"* ]]; then
    return 0
  fi

  if [[ "$output_str" == *"${CORESIMULATOR_INTERRUPTED_ERROR}"* ]]; then
    sleep 1
    return 0
  fi

  sim_log_path=$(sim_get_system_log_path "$device_id")
  if [ -f "$sim_log_path" ]; then
    tail_log=$(tail -n 200 "$sim_log_path" 2>/dev/null || true)
    if [ "$test_type" = "$TEST_TYPE_LOGIC_TEST" ] && sim_is_xctest_failed_to_launch "$tail_log"; then
      return 0
    fi
    if [ "$test_type" != "$TEST_TYPE_LOGIC_TEST" ] && sim_is_app_failed_to_launch "$tail_log" "$app_bundle_id"; then
      return 0
    fi
    if sim_is_coresimulator_crash "$tail_log"; then
      return 0
    fi
  fi

  if [ -n "$app_bundle_id" ] && ! sim_is_app_installed "$device_id" "$app_bundle_id"; then
    return 0
  fi

  return 1
}

_delete_test_cache_dirs() {
  local output_file="$1"
  local sdk="$2"
  local test_type="$3"

  if [ "$sdk" != "$SDK_IPHONEOS" ]; then
    return 0
  fi

  local max_dirs=1
  if [ "$test_type" = "$TEST_TYPE_XCUITEST" ]; then
    max_dirs=2
  fi

  local cache_root
  cache_root=$(get_xcode_embedded_app_deltas_dir)
  if [ -z "$cache_root" ] || [ ! -d "$cache_root" ]; then
    return 0
  fi

  local matches
  local dir
  local escaped_root
  escaped_root=$(printf '%s' "$cache_root" | sed -e 's/[][(){}.^$*+?|\\/]/\\&/g')
  matches=$(grep -Eo "${escaped_root}/[a-z0-9]+/" "$output_file" 2>/dev/null | sed 's#/$##' | uniq | head -n "$max_dirs" || true)

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ -d "$dir" ]; then
      log_info "Removing cache files directory: ${dir}"
      safe_rm_rf "$dir"
    fi
  done <<EOF_DIRS
$matches
EOF_DIRS
}
