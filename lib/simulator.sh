#!/usr/bin/env bash

run_simctl_command() {
  local attempts=2
  local i
  local stdout
  local stderr
  local all_output
  local output
  local status
  local stdout_file
  local stderr_file

  for ((i = 1; i <= attempts; i++)); do
    stdout_file=$(mktemp)
    stderr_file=$(mktemp)
    track_temp_path "$stdout_file"
    track_temp_path "$stderr_file"

    set +e
    xcrun simctl "$@" >"$stdout_file" 2>"$stderr_file"
    status=$?
    set -e

    stdout=$(cat "$stdout_file")
    stderr=$(cat "$stderr_file")
    all_output="${stdout}"$'\n'"${stderr}"
    output=$(printf '%s' "$stdout" | sed 's/[[:space:]]*$//')

    if [ "$status" -eq 0 ]; then
      printf '%s\n' "$output"
      return 0
    fi

    if [ "$i" -lt "$attempts" ] && [[ "$all_output" == *"${CORESIMULATOR_INTERRUPTED_ERROR}"* ]]; then
      log_warn "simctl interrupted by CoreSimulatorService; retrying (${i}/${attempts})"
      continue
    fi

    log_error "$all_output"
    return 1
  done

  return 1
}

sim_get_state() {
  local sim_id="$1"
  local device_plist
  local state_num

  device_plist="${HOME}/Library/Developer/CoreSimulator/Devices/${sim_id}/device.plist"
  if [ ! -f "$device_plist" ]; then
    printf '%s\n' 'Creating'
    return 0
  fi

  state_num=$(plist_extract_raw "$device_plist" 'state' 2>/dev/null || printf '')
  case "$state_num" in
    0) printf '%s\n' 'Creating' ;;
    1) printf '%s\n' 'Shutdown' ;;
    3) printf '%s\n' 'Booted' ;;
    *) printf '%s\n' 'Unknown' ;;
  esac
}

sim_wait_for_state() {
  local sim_id="$1"
  local target_state="$2"
  local timeout_sec="$3"

  local start
  local now
  local state
  start=$(now_epoch)

  while true; do
    state=$(sim_get_state "$sim_id")
    if [ "$state" = "$target_state" ]; then
      return 0
    fi

    now=$(now_epoch)
    if [ $((now - start)) -ge "$timeout_sec" ]; then
      fatal "Timeout waiting for simulator ${sim_id} to become ${target_state}. Last state: ${state}" || return 1
    fi
    sleep "$SIMULATOR_STATE_POLL_INTERVAL_SEC"
  done
}

sim_boot() {
  local sim_id="$1"
  run_simctl_command boot "$sim_id" >/dev/null || return 1
  sim_wait_for_state "$sim_id" 'Booted' "$SIMULATOR_BOOTED_TIMEOUT_SEC" || return 1
  log_info "Simulator ${sim_id} is booted."
}

sim_boot_status_wait() {
  local sim_id="$1"
  local timeout_sec="$2"

  if xcrun simctl bootstatus "$sim_id" -b >/dev/null 2>&1; then
    return 0
  fi

  local start
  local now
  start=$(now_epoch)
  while true; do
    if [ "$(sim_get_state "$sim_id")" = 'Booted' ]; then
      return 0
    fi
    now=$(now_epoch)
    if [ $((now - start)) -ge "$timeout_sec" ]; then
      return 1
    fi
    sleep 1
  done
}

sim_shutdown() {
  local sim_id="$1"
  local state
  state=$(sim_get_state "$sim_id")

  if [ "$state" = 'Shutdown' ]; then
    log_info "Simulator ${sim_id} is already shut down."
    return 0
  fi

  if [ "$state" = 'Creating' ]; then
    fatal "Cannot shut down simulator ${sim_id} in state Creating." || return 1
  fi

  if ! run_simctl_command shutdown "$sim_id" >/dev/null; then
    # Some Xcode versions return non-zero for already-shutdown targets.
    state=$(sim_get_state "$sim_id")
    if [ "$state" != 'Shutdown' ]; then
      return 1
    fi
  fi

  sim_wait_for_state "$sim_id" 'Shutdown' "$SIMULATOR_SHUTDOWN_TIMEOUT_SEC" || return 1
  log_info "Simulator ${sim_id} shut down."
}

sim_delete() {
  local sim_id="$1"
  run_simctl_command delete "$sim_id" >/dev/null || return 1

  local log_root
  log_root="${HOME}/Library/Logs/CoreSimulator/${sim_id}"
  if [ -d "$log_root" ]; then
    safe_rm_rf "$log_root"
  fi
}

sim_get_system_log_path() {
  local sim_id="$1"
  printf '%s/Library/Logs/CoreSimulator/%s/system.log\n' "$HOME" "$sim_id"
}

sim_is_app_installed() {
  local sim_id="$1"
  local app_bundle_id="$2"
  run_simctl_command get_app_container "$sim_id" "$app_bundle_id" >/dev/null 2>&1
}

sim_get_supported_device_types() {
  local os_type="${1:-}"
  local json_file
  local idx=0
  local name

  json_file=$(mktemp)
  track_temp_path "$json_file"
  xcrun simctl list devicetypes -j >"$json_file"

  while true; do
    if ! name=$(json_file_get_raw "$json_file" "devicetypes.${idx}.name" 2>/dev/null); then
      break
    fi

    if [ -z "$os_type" ]; then
      printf '%s\n' "$name"
    elif [ "$os_type" = 'iOS' ] && [[ "$name" == i* ]]; then
      printf '%s\n' "$name"
    elif [ "$os_type" = 'tvOS' ] && [[ "$name" == *TV* ]]; then
      printf '%s\n' "$name"
    elif [ "$os_type" = 'watchOS' ] && [[ "$name" == *Watch* ]]; then
      printf '%s\n' "$name"
    fi

    idx=$((idx + 1))
  done
}

sim_validate_device_type() {
  local device_type="$1"
  local t
  while IFS= read -r t; do
    if [ "$t" = "$device_type" ]; then
      return 0
    fi
  done < <(sim_get_supported_device_types)
  fatal "The simulator device type ${device_type} is not supported." || return 1
}

sim_get_os_type_for_device_type() {
  local device_type="$1"
  if [[ "$device_type" == i* ]]; then
    printf '%s\n' 'iOS'
    return 0
  fi
  if [[ "$device_type" == *TV* ]]; then
    printf '%s\n' 'tvOS'
    return 0
  fi
  if [[ "$device_type" == *Watch* ]]; then
    printf '%s\n' 'watchOS'
    return 0
  fi
  fatal "Failed to recognize OS type for simulator device type ${device_type}." || return 1
}

sim_get_available_runtimes() {
  local os_type="${1:-iOS}"
  local xcode_version_num
  local json_file
  local idx=0
  local name
  local identifier
  local is_available
  local availability
  local runtime_path
  local min_xcode_version_num
  local ios_major
  local ios_minor
  local ios_version_num
  local version

  xcode_version_num=$(get_xcode_version_number)
  json_file=$(mktemp)
  track_temp_path "$json_file"
  xcrun simctl list runtimes -j >"$json_file"

  while true; do
    if ! name=$(json_file_get_raw "$json_file" "runtimes.${idx}.name" 2>/dev/null); then
      break
    fi

    if ! identifier=$(json_file_get_raw "$json_file" "runtimes.${idx}.identifier" 2>/dev/null); then
      idx=$((idx + 1))
      continue
    fi

    is_available=''
    if json_file_has_key "$json_file" "runtimes.${idx}.isAvailable"; then
      is_available=$(json_file_get_raw "$json_file" "runtimes.${idx}.isAvailable" 2>/dev/null || true)
    fi

    availability=''
    if json_file_has_key "$json_file" "runtimes.${idx}.availability"; then
      availability=$(json_file_get_raw "$json_file" "runtimes.${idx}.availability" 2>/dev/null || true)
    fi

    if [ -n "$is_available" ] && [ "$is_available" != 'true' ] && [ "$is_available" != 'YES' ]; then
      idx=$((idx + 1))
      continue
    fi

    if [ -n "$availability" ] && [[ "$availability" == *unavailable* ]]; then
      idx=$((idx + 1))
      continue
    fi

    if [[ "$name" != "${os_type} "* ]]; then
      idx=$((idx + 1))
      continue
    fi

    if json_file_has_key "$json_file" "runtimes.${idx}.bundlePath"; then
      runtime_path=$(json_file_get_raw "$json_file" "runtimes.${idx}.bundlePath" 2>/dev/null || true)
      if [ -n "$runtime_path" ] && [ -f "${runtime_path%/}/Contents/Info.plist" ]; then
        min_xcode_version_num=$(plist_extract_raw "${runtime_path%/}/Contents/Info.plist" 'DTXcode' 2>/dev/null || true)
        if [ -n "$min_xcode_version_num" ] && [ "$xcode_version_num" -lt "$min_xcode_version_num" ]; then
          idx=$((idx + 1))
          continue
        fi
      fi
    else
      if [ "$os_type" = 'iOS' ]; then
        version="${name#${os_type} }"
        ios_major="${version%%.*}"
        ios_minor="${version#*.}"
        ios_minor="${ios_minor%%[^0-9]*}"
        ios_minor="${ios_minor:0:1}"
        ios_major="${ios_major:-0}"
        ios_minor="${ios_minor:-0}"
        ios_version_num=$((ios_major * 100 + ios_minor * 10))
        if [ "$ios_version_num" -gt $((xcode_version_num + 200)) ]; then
          idx=$((idx + 1))
          continue
        fi
      fi
    fi

    version="${name#${os_type} }"
    printf '%s|%s\n' "$version" "$identifier"
    idx=$((idx + 1))
  done
}

sim_get_last_supported_os_version() {
  local os_type="${1:-iOS}"
  local device_type="${2:-}"
  local versions=()
  local line
  local version
  local max_os_version=''

  while IFS= read -r version; do
    [ -n "$version" ] || continue
    versions+=("$version")
  done < <(sim_get_supported_os_versions "$os_type")

  if [ "${#versions[@]}" -eq 0 ]; then
    fatal "Cannot find supported OS version for ${os_type}." || return 1
  fi

  if [ -z "$device_type" ]; then
    printf '%s\n' "${versions[$((${#versions[@]} - 1))]}"
    return 0
  fi

  max_os_version=$(sim_type_max_os_version "$device_type" 2>/dev/null || true)
  if [ -z "$max_os_version" ]; then
    printf '%s\n' "${versions[$((${#versions[@]} - 1))]}"
    return 0
  fi

  local i
  for ((i = ${#versions[@]} - 1; i >= 0; i--)); do
    version="${versions[$i]}"
    if _float_lte "$(sim_version_to_float "$version")" "$max_os_version"; then
      printf '%s\n' "$version"
      return 0
    fi
  done

  fatal "The supported OS versions cannot match simulator type ${device_type} (max ${max_os_version})." || return 1
}

sim_get_supported_os_versions() {
  local os_type="${1:-iOS}"
  local rows=()
  local line
  local version
  local num

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    version="${line%%|*}"
    num=$(version_to_number "$version")
    rows+=("${num}|${version}")
  done < <(sim_get_available_runtimes "$os_type")

  if [ "${#rows[@]}" -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1n | awk -F'|' '!seen[$2]++ {print $2}'
}

sim_get_runtime_id_for_version() {
  local os_type="$1"
  local os_version="$2"
  local line
  local version
  local runtime_id

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    version="${line%%|*}"
    runtime_id="${line#*|}"
    if [ "$version" = "$os_version" ]; then
      printf '%s\n' "$runtime_id"
      return 0
    fi
  done < <(sim_get_available_runtimes "$os_type")

  fatal "The simulator OS version ${os_version} is not supported for ${os_type}." || return 1
}

sim_get_last_supported_iphone_type() {
  local os_version="$1"
  local types=()
  local t
  local i
  local min_os

  while IFS= read -r t; do
    [ -n "$t" ] || continue
    types+=("$t")
  done < <(sim_get_supported_device_types 'iOS')

  for ((i = ${#types[@]} - 1; i >= 0; i--)); do
    t="${types[$i]}"
    [[ "$t" == iPhone* ]] || continue
    min_os=$(sim_type_min_os_version "$t" 2>/dev/null || printf '0')
    if _float_gte "$(sim_version_to_float "$os_version")" "$min_os"; then
      printf '%s\n' "$t"
      return 0
    fi
  done

  fatal 'Cannot find supported iPhone simulator type for the requested OS version.' || return 1
}

sim_validate_device_type_with_os_version() {
  local device_type="$1"
  local os_version="$2"
  local os_float
  local min_os
  local max_os

  os_float=$(sim_version_to_float "$os_version")
  min_os=$(sim_type_min_os_version "$device_type")
  if ! _float_gte "$os_float" "$min_os"; then
    fatal "The min OS version of ${device_type} is ${min_os}. Current OS version is ${os_version}." || return 1
  fi

  max_os=$(sim_type_max_os_version "$device_type" 2>/dev/null || true)
  if [ -n "$max_os" ] && ! _float_lte "$os_float" "$max_os"; then
    fatal "The max OS version of ${device_type} is ${max_os}. Current OS version is ${os_version}." || return 1
  fi
}

sim_type_profile_path() {
  local device_type="$1"
  local xcode_version
  local platform_path
  local sim_profiles_dir

  xcode_version=$(get_xcode_version_number)
  platform_path=$(get_sdk_platform_path "$SDK_IPHONEOS")

  if [ "$xcode_version" -ge 1630 ]; then
    sim_profiles_dir='/Library/Developer/CoreSimulator/Profiles'
  elif [ "$xcode_version" -ge 1100 ]; then
    sim_profiles_dir="${platform_path%/}/Library/Developer/CoreSimulator/Profiles"
  else
    sim_profiles_dir="${platform_path%/}/Developer/Library/CoreSimulator/Profiles"
  fi

  printf '%s/DeviceTypes/%s.simdevicetype/Contents/Resources/profile.plist\n' \
    "$sim_profiles_dir" "$device_type"
}

sim_type_min_os_version() {
  local device_type="$1"
  local profile
  local min_runtime

  profile=$(sim_type_profile_path "$device_type")
  min_runtime=$(plist_extract_raw "$profile" 'minRuntimeVersion')
  sim_version_to_float "$min_runtime"
}

sim_type_max_os_version() {
  local device_type="$1"
  local profile
  local max_runtime

  profile=$(sim_type_profile_path "$device_type")
  if ! plist_has_key "$profile" 'maxRuntimeVersion'; then
    return 1
  fi
  max_runtime=$(plist_extract_raw "$profile" 'maxRuntimeVersion')
  sim_version_to_float "$max_runtime"
}

sim_version_to_float() {
  local os_version="$1"
  if [ "${os_version//./}" = "$os_version" ]; then
    printf '%.1f\n' "$os_version"
    return 0
  fi

  # Remove potential build component, e.g. 10.255.255 -> 10.255.
  if [ "${os_version#*.*.}" != "$os_version" ]; then
    os_version="${os_version%.*}"
  fi
  awk -v v="$os_version" 'BEGIN { printf "%.1f\n", v + 0 }'
}

_float_gte() {
  local a="$1"
  local b="$2"
  awk -v a="$a" -v b="$b" 'BEGIN { exit !(a >= b) }'
}

_float_lte() {
  local a="$1"
  local b="$2"
  awk -v a="$a" -v b="$b" 'BEGIN { exit !(a <= b) }'
}

sim_create_new_simulator() {
  local device_type="${1:-}"
  local os_version="${2:-}"
  local name_prefix="${3:-New}"
  local os_type='iOS'
  local runtime_id
  local name
  local sim_id
  local attempt

  if [ -n "$device_type" ]; then
    sim_validate_device_type "$device_type" || return 1
    os_type=$(sim_get_os_type_for_device_type "$device_type") || return 1
  fi

  if [ -n "$os_version" ]; then
    local supported=0
    local listed
    while IFS= read -r listed; do
      if [ "$listed" = "$os_version" ]; then
        supported=1
        break
      fi
    done < <(sim_get_supported_os_versions "$os_type")
    if [ "$supported" -ne 1 ]; then
      fatal "The simulator OS version ${os_version} is not supported." || return 1
    fi
  else
    os_version=$(sim_get_last_supported_os_version "$os_type" "$device_type") || return 1
  fi

  if [ -z "$device_type" ]; then
    device_type=$(sim_get_last_supported_iphone_type "$os_version") || return 1
  else
    sim_validate_device_type_with_os_version "$device_type" "$os_version" || return 1
  fi

  runtime_id=$(sim_get_runtime_id_for_version "$os_type" "$os_version") || return 1
  name="${name_prefix}-${device_type}-${os_version}"

  log_info "Creating simulator: name=${name}, runtime=${runtime_id}, type=${device_type}"

  for attempt in 1 2 3; do
    if ! sim_id=$(run_simctl_command create "$name" "$device_type" "$runtime_id" 2>/dev/null); then
      log_warn "Failed to create simulator on attempt ${attempt}/3"
      continue
    fi
    sim_id=$(printf '%s\n' "$sim_id" | tail -n 1 | tr -d '\r')

    if sim_wait_for_state "$sim_id" 'Shutdown' "$SIMULATOR_CREATING_TO_SHUTDOWN_TIMEOUT_SEC"; then
      printf '%s|%s|%s|%s\n' "$sim_id" "$device_type" "$os_version" "$name"
      return 0
    fi

    log_warn "Simulator ${sim_id} did not reach Shutdown state; deleting and retrying."
    sim_delete "$sim_id" >/dev/null 2>&1 || true
    sleep 2
  done

  fatal 'Failed to create simulator in 3 attempts.' || return 1
}

sim_is_app_failed_to_launch() {
  local sim_log="$1"
  local app_bundle_id="${2:-}"
  local pattern
  pattern="com\\.apple\\.CoreSimulator\\.SimDevice\\.[A-Z0-9\\-]+.*\\(UIKitApplication:${app_bundle_id}.*\\): Service exited"
  printf '%s\n' "$sim_log" | grep -E "$pattern" >/dev/null 2>&1
}

sim_is_xctest_failed_to_launch() {
  local sim_log="$1"
  local pattern
  pattern='com\\.apple\\.CoreSimulator\\.SimDevice\\.[A-Z0-9\\-]+.*\\((.+)xctest\\[[0-9]+\\]\\): Service exited'
  printf '%s\n' "$sim_log" | grep -E "$pattern" >/dev/null 2>&1
}

sim_is_coresimulator_crash() {
  local sim_log="$1"
  local pattern
  pattern='com\\.apple\\.CoreSimulator\\.SimDevice\\.[A-Z0-9\\-]+.*\\(com\\.apple\\.CoreSimulator.*\\): Service exited due to'
  printf '%s\n' "$sim_log" | grep -E "$pattern" >/dev/null 2>&1
}
