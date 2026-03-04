#!/usr/bin/env bash

TESTROOT_RELATIVE_PATH='__TESTROOT__'

SESSION_SDK=''
SESSION_DEVICE_ARCH=''
SESSION_WORK_DIR=''
SESSION_DELETE_WORK_DIR=1
SESSION_OUTPUT_DIR=''
SESSION_DELETE_OUTPUT_DIR=1
SESSION_STARTUP_TIMEOUT_SEC=''
SESSION_DESTINATION_TIMEOUT_SEC=''
SESSION_KEEP_XCRESULT_DATA=true
SESSION_XCTESTRUN_FILE=''
SESSION_XCTESTRUN_ROOT_KEY=''
SESSION_TEST_TYPE=''
SESSION_AUT_BUNDLE_ID=''
SESSION_PREPARED=0

SESSION_LOGIC_TEST_BUNDLE=''
SESSION_LOGIC_LAUNCH_OPTIONS_JSON=''

SESSION_DISABLE_UITEST_AUTO_SCREENSHOTS=1
SESSION_TEST_ROOT_DIR=''
SESSION_APP_UNDER_TEST_DIR=''
SESSION_TEST_BUNDLE_DIR=''
SESSION_TEST_NAME=''
SESSION_SIGNING_OPTIONS_JSON=''

session_init() {
  SESSION_SDK="$1"
  SESSION_DEVICE_ARCH="$2"
  SESSION_WORK_DIR="${3:-}"
  SESSION_OUTPUT_DIR="${4:-}"

  SESSION_DELETE_WORK_DIR=1
  SESSION_DELETE_OUTPUT_DIR=1
  SESSION_STARTUP_TIMEOUT_SEC=''
  SESSION_DESTINATION_TIMEOUT_SEC=''
  SESSION_KEEP_XCRESULT_DATA=true
  SESSION_XCTESTRUN_FILE=''
  SESSION_XCTESTRUN_ROOT_KEY=''
  SESSION_TEST_TYPE=''
  SESSION_AUT_BUNDLE_ID=''
  SESSION_PREPARED=0
  SESSION_LOGIC_TEST_BUNDLE=''
  SESSION_LOGIC_LAUNCH_OPTIONS_JSON=''
  SESSION_DISABLE_UITEST_AUTO_SCREENSHOTS=1
  SESSION_TEST_ROOT_DIR=''
  SESSION_APP_UNDER_TEST_DIR=''
  SESSION_TEST_BUNDLE_DIR=''
  SESSION_TEST_NAME=''
  SESSION_SIGNING_OPTIONS_JSON=''
}

session_prepare() {
  local app_under_test="$1"
  local test_bundle="$2"
  local xctestrun_file_path="$3"
  local test_type="$4"
  local signing_options_json="$5"

  SESSION_SIGNING_OPTIONS_JSON="$signing_options_json"

  _session_prepare_directories || return 1

  if [ -n "$xctestrun_file_path" ]; then
    if [ ! -f "$xctestrun_file_path" ]; then
      fatal "xctestrun file does not exist: ${xctestrun_file_path}" || return 1
    fi
    SESSION_XCTESTRUN_FILE="$xctestrun_file_path"
    SESSION_XCTESTRUN_ROOT_KEY=$(plist_first_root_key "$SESSION_XCTESTRUN_FILE")
    if [ -z "$SESSION_XCTESTRUN_ROOT_KEY" ]; then
      fatal "Could not parse root key from xctestrun: ${SESSION_XCTESTRUN_FILE}" || return 1
    fi

    if [ -n "$test_type" ]; then
      SESSION_TEST_TYPE="$test_type"
    else
      if plist_has_key "$SESSION_XCTESTRUN_FILE" "${SESSION_XCTESTRUN_ROOT_KEY}.UITargetAppPath"; then
        SESSION_TEST_TYPE="$TEST_TYPE_XCUITEST"
      else
        SESSION_TEST_TYPE="$TEST_TYPE_XCTEST"
      fi
    fi
  else
    if [ -z "$test_bundle" ]; then
      fatal 'Without providing xctestrun file, test bundle is required.' || return 1
    fi

    _prepare_bundles "$SESSION_WORK_DIR" "$app_under_test" "$test_bundle" || return 1

    local finalized
    finalized=$(_finalize_test_type "$SESSION_TEST_BUNDLE_DIR" "$SESSION_SDK" "$SESSION_APP_UNDER_TEST_DIR" "$test_type") || return 1
    SESSION_TEST_TYPE="$finalized"

    case "$SESSION_TEST_TYPE" in
      "$TEST_TYPE_XCUITEST"|"$TEST_TYPE_XCTEST")
        _generate_xctestrun || return 1
        ;;
      "$TEST_TYPE_LOGIC_TEST")
        SESSION_LOGIC_TEST_BUNDLE="$SESSION_TEST_BUNDLE_DIR"
        ;;
      *)
        fatal "Unsupported test type: ${SESSION_TEST_TYPE}" || return 1
        ;;
    esac
  fi

  SESSION_PREPARED=1
}

session_set_launch_options() {
  local launch_options_json="$1"

  if [ "$SESSION_PREPARED" -ne 1 ]; then
    fatal 'The session has not been prepared. Please call session_prepare first.' || return 1
  fi

  if [ -z "$launch_options_json" ]; then
    return 0
  fi

  if [ ! -f "$launch_options_json" ]; then
    fatal "Launch options json does not exist: ${launch_options_json}" || return 1
  fi

  if json_file_has_key "$launch_options_json" 'keep_xcresult_data'; then
    SESSION_KEEP_XCRESULT_DATA=$(json_file_get_raw "$launch_options_json" 'keep_xcresult_data')
  fi
  if json_file_has_key "$launch_options_json" 'startup_timeout_sec'; then
    SESSION_STARTUP_TIMEOUT_SEC=$(json_file_get_raw "$launch_options_json" 'startup_timeout_sec')
  fi
  if json_file_has_key "$launch_options_json" 'destination_timeout_sec'; then
    SESSION_DESTINATION_TIMEOUT_SEC=$(json_file_get_raw "$launch_options_json" 'destination_timeout_sec')
  fi

  if [ -n "$SESSION_XCTESTRUN_FILE" ]; then
    local root="$SESSION_XCTESTRUN_ROOT_KEY"

    if json_file_has_key "$launch_options_json" 'env_vars'; then
      plist_merge_json_object_from_json_file \
        "$SESSION_XCTESTRUN_FILE" \
        "${root}.EnvironmentVariables" \
        "$launch_options_json" \
        'env_vars'
    fi

    if json_file_has_key "$launch_options_json" 'args'; then
      plist_set_json "$SESSION_XCTESTRUN_FILE" "${root}.CommandLineArguments" \
        "$(json_file_get_json "$launch_options_json" 'args')"
    fi

    if json_file_has_key "$launch_options_json" 'tests_to_run'; then
      if ! _json_array_is_single_all "$launch_options_json" 'tests_to_run'; then
        plist_set_json "$SESSION_XCTESTRUN_FILE" "${root}.OnlyTestIdentifiers" \
          "$(json_file_get_json "$launch_options_json" 'tests_to_run')"
      fi
    fi

    if json_file_has_key "$launch_options_json" 'skip_tests'; then
      plist_set_json "$SESSION_XCTESTRUN_FILE" "${root}.SkipTestIdentifiers" \
        "$(json_file_get_json "$launch_options_json" 'skip_tests')"
    fi

    if json_file_has_key "$launch_options_json" 'app_under_test_env_vars'; then
      if [ "$SESSION_TEST_TYPE" = "$TEST_TYPE_XCUITEST" ]; then
        plist_merge_json_object_from_json_file \
          "$SESSION_XCTESTRUN_FILE" \
          "${root}.UITargetAppEnvironmentVariables" \
          "$launch_options_json" \
          'app_under_test_env_vars'
      else
        plist_merge_json_object_from_json_file \
          "$SESSION_XCTESTRUN_FILE" \
          "${root}.EnvironmentVariables" \
          "$launch_options_json" \
          'app_under_test_env_vars'
      fi
    fi

    if json_file_has_key "$launch_options_json" 'app_under_test_args'; then
      if [ "$SESSION_TEST_TYPE" = "$TEST_TYPE_XCUITEST" ]; then
        plist_set_json "$SESSION_XCTESTRUN_FILE" "${root}.UITargetAppCommandLineArguments" \
          "$(json_file_get_json "$launch_options_json" 'app_under_test_args')"
      else
        plist_set_json "$SESSION_XCTESTRUN_FILE" "${root}.CommandLineArguments" \
          "$(json_file_get_json "$launch_options_json" 'app_under_test_args')"
      fi
    fi

    if json_file_has_key "$launch_options_json" 'uitest_auto_screenshots'; then
      local auto_shots
      auto_shots=$(json_file_get_raw "$launch_options_json" 'uitest_auto_screenshots')
      if _is_truthy "$auto_shots"; then
        SESSION_DISABLE_UITEST_AUTO_SCREENSHOTS=0
        plist_remove_key "$SESSION_XCTESTRUN_FILE" "${root}.SystemAttachmentLifetime"
      fi
    fi

  elif [ -n "$SESSION_LOGIC_TEST_BUNDLE" ]; then
    SESSION_LOGIC_LAUNCH_OPTIONS_JSON="$launch_options_json"
  fi
}

session_run_test() {
  local device_id="$1"
  local os_version="${2:-}"

  if [ "$SESSION_PREPARED" -ne 1 ]; then
    fatal 'The session has not been prepared. Please call session_prepare first.' || return 1
  fi

  if [ -n "$SESSION_XCTESTRUN_FILE" ]; then
    local result_bundle_path
    local xcode_version
    local exit_code
    local expose_xcresult

    result_bundle_path="${SESSION_OUTPUT_DIR%/}/test.xcresult"
    _xctestrun_run "$device_id" "$SESSION_SDK" "$os_version" "$result_bundle_path"
    exit_code=$?

    xcode_version=$(get_xcode_version_number)
    if [ "$xcode_version" -ge 1100 ]; then
      expose_xcresult="${SESSION_OUTPUT_DIR%/}/ExposeXcresult"
      if ! xcresult_expose "$result_bundle_path" "$expose_xcresult"; then
        log_warn 'Failed to expose xcresult diagnostics/attachments.'
      fi
      if !_is_truthy "$SESSION_KEEP_XCRESULT_DATA"; then
        safe_rm_rf "$result_bundle_path"
      fi
    fi

    return "$exit_code"
  fi

  if [ -n "$SESSION_LOGIC_TEST_BUNDLE" ]; then
    _run_logic_test_on_sim "$device_id" "$SESSION_LOGIC_TEST_BUNDLE" "$os_version"
    return $?
  fi

  fatal 'Unexpected runtime state: neither xctestrun nor logic test bundle is configured.' || return 1
}

session_close() {
  if [ "$SESSION_DELETE_WORK_DIR" -eq 1 ] && [ -n "$SESSION_WORK_DIR" ] && [ -d "$SESSION_WORK_DIR" ]; then
    safe_rm_rf "$SESSION_WORK_DIR"
  fi
  if [ "$SESSION_DELETE_OUTPUT_DIR" -eq 1 ] && [ -n "$SESSION_OUTPUT_DIR" ] && [ -d "$SESSION_OUTPUT_DIR" ]; then
    safe_rm_rf "$SESSION_OUTPUT_DIR"
  fi
}

_session_prepare_directories() {
  if [ -n "$SESSION_WORK_DIR" ]; then
    mkdir -p "$SESSION_WORK_DIR" || return 1
    SESSION_WORK_DIR=$(cd "$SESSION_WORK_DIR" && pwd)
    SESSION_DELETE_WORK_DIR=0
  else
    SESSION_WORK_DIR=$(mktemp_dir)
    SESSION_DELETE_WORK_DIR=1
  fi

  if [ -n "$SESSION_OUTPUT_DIR" ]; then
    mkdir -p "$SESSION_OUTPUT_DIR" || return 1
    SESSION_OUTPUT_DIR=$(cd "$SESSION_OUTPUT_DIR" && pwd)
    SESSION_DELETE_OUTPUT_DIR=0
  else
    SESSION_OUTPUT_DIR=$(mktemp_dir)
    SESSION_DELETE_OUTPUT_DIR=1
  fi
}

_prepare_bundles() {
  local working_dir="$1"
  local app_under_test_path="$2"
  local test_bundle_path="$3"

  SESSION_APP_UNDER_TEST_DIR=''

  if [ -n "$app_under_test_path" ]; then
    if [ ! -e "$app_under_test_path" ]; then
      fatal "The app under test does not exist: ${app_under_test_path}" || return 1
    fi
    case "$app_under_test_path" in
      *.app|*.ipa) ;;
      *)
        fatal "The app under test ${app_under_test_path} should have .app or .ipa extension." || return 1
        ;;
    esac

    SESSION_APP_UNDER_TEST_DIR="${working_dir%/}/$(basename "${app_under_test_path%.*}").app"

    if [ ! -e "$SESSION_APP_UNDER_TEST_DIR" ]; then
      if [[ "$app_under_test_path" == *.ipa ]]; then
        local extracted_app
        extracted_app=$(bundle_extract_app "$app_under_test_path" "$working_dir") || return 1
        mv "$extracted_app" "$SESSION_APP_UNDER_TEST_DIR"
      else
        if [[ "$(cd "$(dirname "$app_under_test_path")" && pwd)/$(basename "$app_under_test_path")" == "${working_dir%/}"/* ]]; then
          SESSION_APP_UNDER_TEST_DIR="$app_under_test_path"
        else
          cp -R "$app_under_test_path" "$SESSION_APP_UNDER_TEST_DIR"
        fi
      fi
    fi
  fi

  if [ ! -e "$test_bundle_path" ]; then
    fatal "The test bundle does not exist: ${test_bundle_path}" || return 1
  fi

  case "$test_bundle_path" in
    *.xctest|*.ipa|*.zip) ;;
    *)
      fatal "The test bundle ${test_bundle_path} should have .xctest, .ipa or .zip extension." || return 1
      ;;
  esac

  SESSION_TEST_BUNDLE_DIR="${working_dir%/}/$(basename "${test_bundle_path%.*}").xctest"
  if [ ! -e "$SESSION_TEST_BUNDLE_DIR" ]; then
    if [[ "$test_bundle_path" == *.ipa ]] || [[ "$test_bundle_path" == *.zip ]]; then
      local extracted_test
      extracted_test=$(bundle_extract_test_bundle "$test_bundle_path" "$working_dir") || return 1
      mv "$extracted_test" "$SESSION_TEST_BUNDLE_DIR"
    else
      if [[ "$(cd "$(dirname "$test_bundle_path")" && pwd)/$(basename "$test_bundle_path")" == "${working_dir%/}"/* ]]; then
        SESSION_TEST_BUNDLE_DIR="$test_bundle_path"
      else
        cp -R "$test_bundle_path" "$SESSION_TEST_BUNDLE_DIR"
      fi
    fi
  fi

  SESSION_TEST_NAME="$(basename "${SESSION_TEST_BUNDLE_DIR%.*}")"
}

_finalize_test_type() {
  local test_bundle_dir="$1"
  local sdk="$2"
  local app_under_test_dir="$3"
  local original_test_type="$4"

  local test_type

  if [ -z "$original_test_type" ]; then
    test_type=$(_detect_test_type "$test_bundle_dir") || return 1
    if [ "$test_type" = "$TEST_TYPE_XCTEST" ] && [ -z "$app_under_test_dir" ] &&
       [ "$sdk" = "$SDK_IPHONESIMULATOR" ]; then
      test_type="$TEST_TYPE_LOGIC_TEST"
    fi
    log_info "Will consider the test as test type ${test_type}."
  else
    test_type="$original_test_type"

    if [ "$test_type" = "$TEST_TYPE_LOGIC_TEST" ] && [ "$sdk" != "$SDK_IPHONESIMULATOR" ]; then
      if [ -n "$app_under_test_dir" ]; then
        test_type="$TEST_TYPE_XCTEST"
        log_info "Will consider the test as XCTest because logic_test only runs on simulator."
      else
        fatal "logic_test only supports simulator SDK. Current SDK: ${sdk}" || return 1
      fi
    elif [ "$test_type" = "$TEST_TYPE_XCTEST" ] && [ -z "$app_under_test_dir" ] &&
         [ "$sdk" = "$SDK_IPHONESIMULATOR" ]; then
      test_type="$TEST_TYPE_LOGIC_TEST"
      log_info 'Will consider the test as logic_test because app_under_test is not given.'
    fi
  fi

  case "$test_type" in
    "$TEST_TYPE_XCUITEST"|"$TEST_TYPE_XCTEST"|"$TEST_TYPE_LOGIC_TEST") ;;
    *)
      fatal "Unsupported test type: ${test_type}" || return 1
      ;;
  esac

  if [ -z "$app_under_test_dir" ] && [ "$test_type" != "$TEST_TYPE_LOGIC_TEST" ]; then
    fatal "The app under test is required for test type ${test_type}." || return 1
  fi

  printf '%s\n' "$test_type"
}

_detect_test_type() {
  local test_bundle_dir="$1"
  local test_bundle_exec

  test_bundle_exec="${test_bundle_dir%/}/$(basename "${test_bundle_dir%.*}")"
  if nm "$test_bundle_exec" 2>/dev/null | grep -Fq 'XCUIApplication'; then
    printf '%s\n' "$TEST_TYPE_XCUITEST"
  else
    printf '%s\n' "$TEST_TYPE_XCTEST"
  fi
}

_generate_xctestrun() {
  SESSION_TEST_ROOT_DIR="${SESSION_WORK_DIR%/}/TEST_ROOT"
  mkdir -p "$SESSION_TEST_ROOT_DIR"

  local xctestrun_file_path="${SESSION_TEST_ROOT_DIR%/}/test.xctestrun"
  if [ -f "$xctestrun_file_path" ]; then
    log_info 'Skipping xctestrun generation; test.xctestrun already exists.'
    SESSION_XCTESTRUN_FILE="$xctestrun_file_path"
    SESSION_XCTESTRUN_ROOT_KEY=$(plist_first_root_key "$SESSION_XCTESTRUN_FILE")
    return 0
  fi

  if [ "$SESSION_TEST_TYPE" != "$TEST_TYPE_LOGIC_TEST" ]; then
    SESSION_APP_UNDER_TEST_DIR=$(_move_and_replace_file "$SESSION_APP_UNDER_TEST_DIR" "$SESSION_TEST_ROOT_DIR")
  fi

  plist_init_empty_dict "$xctestrun_file_path"
  plist_set_json "$xctestrun_file_path" 'Runner' '{}'

  case "$SESSION_TEST_TYPE" in
    "$TEST_TYPE_XCUITEST")
      _generate_test_root_for_xcuitest "$xctestrun_file_path" 'Runner' || return 1
      ;;
    "$TEST_TYPE_XCTEST")
      _generate_test_root_for_xctest "$xctestrun_file_path" 'Runner' || return 1
      ;;
    "$TEST_TYPE_LOGIC_TEST")
      _generate_test_root_for_logic_test "$xctestrun_file_path" 'Runner' || return 1
      ;;
    *)
      fatal "Unsupported test type during xctestrun generation: ${SESSION_TEST_TYPE}" || return 1
      ;;
  esac

  local content
  content=$(cat "$xctestrun_file_path")
  content=${content//${SESSION_TEST_ROOT_DIR}/${TESTROOT_RELATIVE_PATH}}
  printf '%s' "$content" >"$xctestrun_file_path"

  SESSION_XCTESTRUN_FILE="$xctestrun_file_path"
  SESSION_XCTESTRUN_ROOT_KEY='Runner'

  if [ -n "$SESSION_APP_UNDER_TEST_DIR" ]; then
    SESSION_AUT_BUNDLE_ID=$(bundle_get_bundle_id "$SESSION_APP_UNDER_TEST_DIR" 2>/dev/null || true)
  fi
}

_generate_test_root_for_xcuitest() {
  local xctestrun_file="$1"
  local root="$2"

  local platform_path
  local platform_library_path
  local uitest_runner_app
  local on_device=0

  platform_path=$(get_sdk_platform_path "$SESSION_SDK")
  platform_library_path="${platform_path%/}/Developer/Library"

  if [ "$SESSION_SDK" = "$SDK_IPHONEOS" ]; then
    on_device=1
  fi

  uitest_runner_app=$(_get_uitest_runner_app_from_xcode "$platform_library_path") || return 1
  _prepare_uitest_in_runner_app "$uitest_runner_app" || return 1

  if [ "$on_device" -eq 1 ]; then
    _prepare_device_signing_for_uitest_runner "$uitest_runner_app" "$platform_path" "$platform_library_path" || return 1
  fi

  local platform_name='iPhoneSimulator'
  if [ "$on_device" -eq 1 ]; then
    platform_name='iPhoneOS'
  fi

  local developer_path="__PLATFORMS__/${platform_name}.platform/Developer"
  local dyld_framework
  local dyld_library
  local testing_env_json

  dyld_framework="__TESTROOT__:${developer_path}/Library/Frameworks:${developer_path}/Library/PrivateFrameworks"
  dyld_library="__TESTROOT__:${developer_path}/usr/lib"
  testing_env_json="{\"DYLD_FRAMEWORK_PATH\":$(json_string "$dyld_framework"),\"DYLD_LIBRARY_PATH\":$(json_string "$dyld_library")}"

  plist_set_string "$xctestrun_file" "${root}.ProductModuleName" "${SESSION_TEST_NAME//-/_}"
  plist_set_bool "$xctestrun_file" "${root}.IsUITestBundle" true
  plist_set_string "$xctestrun_file" "${root}.SystemAttachmentLifetime" 'keepNever'
  plist_set_string "$xctestrun_file" "${root}.TestBundlePath" "$SESSION_TEST_BUNDLE_DIR"
  plist_set_string "$xctestrun_file" "${root}.TestHostPath" "$uitest_runner_app"
  plist_set_string "$xctestrun_file" "${root}.UITargetAppPath" "$SESSION_APP_UNDER_TEST_DIR"
  plist_set_string "$xctestrun_file" "${root}.UserAttachmentLifetime" 'keepNever'
  plist_set_json "$xctestrun_file" "${root}.TestingEnvironmentVariables" "$testing_env_json"
  plist_set_json "$xctestrun_file" "${root}.DependentProductPaths" "$(json_array_from_strings "$SESSION_APP_UNDER_TEST_DIR" "$SESSION_TEST_BUNDLE_DIR")"
}

_get_uitest_runner_app_from_xcode() {
  local platform_library_path="$1"
  local test_bundle_name
  local xctrunner_app
  local uitest_runner_name
  local uitest_runner_app
  local uitest_runner_exec
  local test_executable
  local test_archs

  test_bundle_name=$(basename "${SESSION_TEST_BUNDLE_DIR%.*}")
  xctrunner_app="${platform_library_path%/}/Xcode/Agents/XCTRunner.app"
  uitest_runner_name="${test_bundle_name}-Runner"
  uitest_runner_app="${SESSION_TEST_ROOT_DIR%/}/${uitest_runner_name}.app"

  safe_rm_rf "$uitest_runner_app"
  cp -R "$xctrunner_app" "$uitest_runner_app"
  uitest_runner_exec="${uitest_runner_app%/}/${uitest_runner_name}"
  mv "${uitest_runner_app%/}/XCTRunner" "$uitest_runner_exec"

  test_executable="${SESSION_TEST_BUNDLE_DIR%/}/${test_bundle_name}"
  test_archs=$(bundle_get_file_archs "$test_executable" 2>/dev/null || true)

  if [ "$SESSION_DEVICE_ARCH" = 'arm64e' ] && [[ "$test_archs" != *'arm64e'* ]]; then
    bundle_remove_arch_type "$uitest_runner_exec" 'arm64e' || true
  elif [ "$SESSION_SDK" != "$SDK_IPHONEOS" ] && [[ "$test_archs" == *'x86_64'* ]]; then
    bundle_remove_arch_type "$uitest_runner_exec" 'arm64' || true
  fi

  local runner_info_plist="${uitest_runner_app%/}/Info.plist"
  plist_set_string "$runner_info_plist" 'CFBundleName' "$uitest_runner_name"
  plist_set_string "$runner_info_plist" 'CFBundleExecutable' "$uitest_runner_name"
  plist_set_string "$runner_info_plist" 'CFBundleIdentifier' "com.apple.test.${uitest_runner_name}"

  printf '%s\n' "$uitest_runner_app"
}

_prepare_uitest_in_runner_app() {
  local uitest_runner_app="$1"
  local plugins_dir
  local new_test_bundle_path

  plugins_dir="${uitest_runner_app%/}/PlugIns"
  mkdir -p "$plugins_dir"

  new_test_bundle_path="${plugins_dir%/}/$(basename "$SESSION_TEST_BUNDLE_DIR")"
  if [ -L "$SESSION_TEST_BUNDLE_DIR" ]; then
    cp -R "$SESSION_TEST_BUNDLE_DIR" "$new_test_bundle_path"
    SESSION_TEST_BUNDLE_DIR="$new_test_bundle_path"
  else
    SESSION_TEST_BUNDLE_DIR=$(_move_and_replace_file "$SESSION_TEST_BUNDLE_DIR" "$plugins_dir")
  fi
}

_prepare_device_signing_for_uitest_runner() {
  local uitest_runner_app="$1"
  local platform_path="$2"
  local platform_library_path="$3"

  local runner_embedded_provision="${uitest_runner_app%/}/embedded.mobileprovision"
  local customized_runner_profile=''
  local use_customized=0

  if [ -n "$SESSION_SIGNING_OPTIONS_JSON" ] &&
     json_file_has_key "$SESSION_SIGNING_OPTIONS_JSON" 'xctrunner_app_provisioning_profile'; then
    customized_runner_profile=$(json_file_get_raw "$SESSION_SIGNING_OPTIONS_JSON" 'xctrunner_app_provisioning_profile')
    if [ -n "$customized_runner_profile" ]; then
      cp "$customized_runner_profile" "$runner_embedded_provision"
      use_customized=1
    fi
  fi

  if [ -n "$SESSION_SIGNING_OPTIONS_JSON" ] &&
     json_file_has_key "$SESSION_SIGNING_OPTIONS_JSON" 'xctrunner_app_enable_ui_file_sharing'; then
    local ui_share
    ui_share=$(json_file_get_raw "$SESSION_SIGNING_OPTIONS_JSON" 'xctrunner_app_enable_ui_file_sharing')
    if _is_truthy "$ui_share"; then
      bundle_enable_ui_file_sharing "$uitest_runner_app" false || true
    fi
  fi

  if [ "$use_customized" -eq 0 ]; then
    cp "${SESSION_APP_UNDER_TEST_DIR%/}/embedded.mobileprovision" "$runner_embedded_provision"
  fi

  local test_bundle_team_id
  local full_test_bundle_id
  local entitlements_plist
  local identity
  local frameworks_dir
  local xcode_version

  test_bundle_team_id=$(bundle_get_development_team "$SESSION_TEST_BUNDLE_DIR") || return 1
  full_test_bundle_id="${test_bundle_team_id}.$(bundle_get_bundle_id "$SESSION_TEST_BUNDLE_DIR")"

  entitlements_plist="${uitest_runner_app%/}/RunnerEntitlements.plist"
  plist_init_empty_dict "$entitlements_plist"
  plist_set_string "$entitlements_plist" 'application-identifier' "$full_test_bundle_id"
  plist_set_string "$entitlements_plist" 'com.apple.developer.team-identifier' "$test_bundle_team_id"
  plist_set_bool "$entitlements_plist" 'get-task-allow' true
  plist_set_json "$entitlements_plist" 'keychain-access-groups' "[$(json_string "$full_test_bundle_id")]"

  identity=$(bundle_get_codesign_identity "$SESSION_TEST_BUNDLE_DIR") || return 1

  frameworks_dir="${uitest_runner_app%/}/Frameworks"
  mkdir -p "$frameworks_dir"

  _copy_and_sign_framework "${platform_library_path%/}/Frameworks/XCTest.framework" "$frameworks_dir" "$identity" || return 1
  _copy_and_sign_framework "${platform_library_path%/}/PrivateFrameworks/XCTAutomationSupport.framework" "$frameworks_dir" "$identity" || return 1

  xcode_version=$(get_xcode_version_number)
  if [ "$xcode_version" -ge 1100 ]; then
    _copy_and_sign_lib "${platform_path%/}/${LIB_XCTEST_SWIFT_RELATIVE_PATH}" "$frameworks_dir" "$identity" || return 1
  fi

  bundle_codesign "$uitest_runner_app" "$entitlements_plist" "$identity" || return 1

  if [ "$xcode_version" -ge 1300 ]; then
    _copy_and_sign_framework "${platform_library_path%/}/PrivateFrameworks/XCUIAutomation.framework" "$frameworks_dir" "$identity" || return 1
    _copy_and_sign_framework "${platform_library_path%/}/PrivateFrameworks/XCTestCore.framework" "$frameworks_dir" "$identity" || return 1
    _copy_and_sign_framework "${platform_library_path%/}/PrivateFrameworks/XCUnit.framework" "$frameworks_dir" "$identity" || return 1
  fi

  if [ "$xcode_version" -ge 1430 ]; then
    _copy_and_sign_framework "${platform_library_path%/}/PrivateFrameworks/XCTestSupport.framework" "$frameworks_dir" "$identity" || return 1
  fi

  bundle_codesign "$SESSION_TEST_BUNDLE_DIR" '' "$identity" || return 1
  bundle_codesign "$SESSION_APP_UNDER_TEST_DIR" '' "$identity" || return 1
}

_generate_test_root_for_xctest() {
  local xctestrun_file="$1"
  local root="$2"

  local plugins_dir
  local new_test_bundle_path
  local on_device=0
  local platform_path
  local frameworks_dir
  local identity
  local xcode_version
  local platform_name
  local developer_path
  local dyld_insert_libs
  local app_name
  local test_env_json

  plugins_dir="${SESSION_APP_UNDER_TEST_DIR%/}/PlugIns"
  mkdir -p "$plugins_dir"

  new_test_bundle_path="${plugins_dir%/}/$(basename "$SESSION_TEST_BUNDLE_DIR")"
  if [ -L "$SESSION_TEST_BUNDLE_DIR" ]; then
    cp -R "$SESSION_TEST_BUNDLE_DIR" "$new_test_bundle_path"
    SESSION_TEST_BUNDLE_DIR="$new_test_bundle_path"
  elif [ "$new_test_bundle_path" != "$SESSION_TEST_BUNDLE_DIR" ]; then
    SESSION_TEST_BUNDLE_DIR=$(_move_and_replace_file "$SESSION_TEST_BUNDLE_DIR" "$plugins_dir")
  fi

  if [ "$SESSION_SDK" = "$SDK_IPHONEOS" ]; then
    on_device=1
    platform_path=$(get_sdk_platform_path "$SESSION_SDK")
    frameworks_dir="${SESSION_APP_UNDER_TEST_DIR%/}/Frameworks"
    mkdir -p "$frameworks_dir"

    identity=$(bundle_get_codesign_identity "$SESSION_APP_UNDER_TEST_DIR") || return 1

    _copy_and_sign_framework "${platform_path%/}/Developer/Library/Frameworks/XCTest.framework" "$frameworks_dir" "$identity" || return 1
    _copy_and_sign_lib "${platform_path%/}/Developer/usr/lib/libXCTestBundleInject.dylib" "$frameworks_dir" "$identity" || return 1

    xcode_version=$(get_xcode_version_number)
    if [ "$xcode_version" -ge 1100 ]; then
      _copy_and_sign_framework "${platform_path%/}/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework" "$frameworks_dir" "$identity" || return 1
      _copy_and_sign_lib "${platform_path%/}/${LIB_XCTEST_SWIFT_RELATIVE_PATH}" "$frameworks_dir" "$identity" || return 1
    fi

    if [ "$xcode_version" -ge 1300 ]; then
      if [ "$xcode_version" -ge 1640 ]; then
        _copy_and_sign_framework "${platform_path%/}/Developer/Library/Frameworks/XCUIAutomation.framework" "$frameworks_dir" "$identity" || return 1
      else
        _copy_and_sign_framework "${platform_path%/}/Developer/Library/PrivateFrameworks/XCUIAutomation.framework" "$frameworks_dir" "$identity" || return 1
      fi
      _copy_and_sign_framework "${platform_path%/}/Developer/Library/PrivateFrameworks/XCTestCore.framework" "$frameworks_dir" "$identity" || return 1
      _copy_and_sign_framework "${platform_path%/}/Developer/Library/PrivateFrameworks/XCUnit.framework" "$frameworks_dir" "$identity" || return 1
    fi

    if [ "$xcode_version" -ge 1430 ]; then
      _copy_and_sign_framework "${platform_path%/}/Developer/Library/PrivateFrameworks/XCTestSupport.framework" "$frameworks_dir" "$identity" || return 1
    fi

    bundle_codesign "$SESSION_TEST_BUNDLE_DIR" '' "$identity" || return 1
    bundle_codesign "$SESSION_APP_UNDER_TEST_DIR" '' "$identity" || return 1
  fi

  app_name=$(basename "${SESSION_APP_UNDER_TEST_DIR%.*}")
  platform_name='iPhoneSimulator'
  if [ "$on_device" -eq 1 ]; then
    platform_name='iPhoneOS'
  fi

  developer_path="__PLATFORMS__/${platform_name}.platform/Developer"
  if [ "$on_device" -eq 1 ]; then
    dyld_insert_libs='__TESTHOST__/Frameworks/libXCTestBundleInject.dylib'
  else
    dyld_insert_libs="${developer_path}/usr/lib/libXCTestBundleInject.dylib"
  fi

  test_env_json="{\"XCInjectBundleInto\":$(json_string "__TESTHOST__/${app_name}"),\"DYLD_FRAMEWORK_PATH\":$(json_string "__TESTROOT__:${developer_path}/Library/Frameworks:${developer_path}/Library/PrivateFrameworks"),\"DYLD_INSERT_LIBRARIES\":$(json_string "$dyld_insert_libs"),\"DYLD_LIBRARY_PATH\":$(json_string "__TESTROOT__:${developer_path}/usr/lib:")}"

  plist_set_string "$xctestrun_file" "${root}.ProductModuleName" "${SESSION_TEST_NAME//-/_}"
  plist_set_string "$xctestrun_file" "${root}.TestHostPath" "$SESSION_APP_UNDER_TEST_DIR"
  plist_set_string "$xctestrun_file" "${root}.TestBundlePath" "$SESSION_TEST_BUNDLE_DIR"
  plist_set_bool "$xctestrun_file" "${root}.IsAppHostedTestBundle" true
  plist_set_json "$xctestrun_file" "${root}.TestingEnvironmentVariables" "$test_env_json"
}

_generate_test_root_for_logic_test() {
  local xctestrun_file="$1"
  local root="$2"
  local dyld_framework_path
  local testing_env_json

  dyld_framework_path="$(get_sdk_platform_path "$SESSION_SDK")/Developer/Library/Frameworks"
  testing_env_json="{\"DYLD_FRAMEWORK_PATH\":$(json_string "$dyld_framework_path"),\"DYLD_LIBRARY_PATH\":$(json_string "$dyld_framework_path")}"

  plist_set_string "$xctestrun_file" "${root}.ProductModuleName" "${SESSION_TEST_NAME//-/_}"
  plist_set_string "$xctestrun_file" "${root}.TestBundlePath" "$SESSION_TEST_BUNDLE_DIR"
  plist_set_string "$xctestrun_file" "${root}.TestHostPath" "$(get_xctest_tool_path "$SESSION_SDK")"
  plist_set_json "$xctestrun_file" "${root}.TestingEnvironmentVariables" "$testing_env_json"
}

_xctestrun_run() {
  local device_id="$1"
  local sdk="$2"
  local os_version="$3"
  local result_bundle_path="$4"

  local xcode_version
  local startup_timeout
  local exit_code
  local command=()

  xcode_version=$(get_xcode_version_number)

  if [ "$xcode_version" -ge 1100 ] && [ "$sdk" = "$SDK_IPHONESIMULATOR" ] && [ -n "$os_version" ]; then
    if [ "$(version_to_number "$os_version")" -lt 1220 ]; then
      local swift_fallback
      local new_env_json
      swift_fallback=$(get_swift5_fallback_libs_dir)
      if [ -n "$swift_fallback" ]; then
        new_env_json="{\"DYLD_FALLBACK_LIBRARY_PATH\":$(json_string "$swift_fallback")}"
        plist_merge_json_object "$SESSION_XCTESTRUN_FILE" "${SESSION_XCTESTRUN_ROOT_KEY}.EnvironmentVariables" "$new_env_json"
      fi
    fi
  fi

  command=(
    xcodebuild test-without-building
    -xctestrun "$SESSION_XCTESTRUN_FILE"
    -destination "id=${device_id}"
    -derivedDataPath "$SESSION_OUTPUT_DIR"
  )

  if [ "$xcode_version" -ge 1100 ] && [ -n "$result_bundle_path" ]; then
    safe_rm_rf "$result_bundle_path"
    command+=(-resultBundlePath "$result_bundle_path")
  fi

  if [ "$xcode_version" -ge 1410 ]; then
    command+=(-collect-test-diagnostics=never)
  fi

  if [ -n "$SESSION_DESTINATION_TIMEOUT_SEC" ]; then
    command+=(-destination-timeout "$SESSION_DESTINATION_TIMEOUT_SEC")
  fi

  startup_timeout="$DEFAULT_XCODEBUILD_STARTUP_TIMEOUT_SEC"
  if [ -n "$SESSION_STARTUP_TIMEOUT_SEC" ]; then
    startup_timeout="$SESSION_STARTUP_TIMEOUT_SEC"
  fi

  xcodebuild_execute \
    "$sdk" \
    "$SESSION_TEST_TYPE" \
    "$device_id" \
    "$SIGNAL_TEST_WITHOUT_BUILDING_SUCCEEDED" \
    "$SIGNAL_TEST_WITHOUT_BUILDING_FAILED" \
    "$SESSION_AUT_BUNDLE_ID" \
    "$startup_timeout" \
    "$result_bundle_path" \
    "${command[@]}"
  exit_code=$?

  return "$exit_code"
}

_run_logic_test_on_sim() {
  local sim_id="$1"
  local test_bundle_path="$2"
  local os_version="$3"

  local -a command
  local tests_to_run='All'
  local return_code
  local line
  local key
  local value
  local env_args=()

  command=(
    xcrun simctl spawn -s "$sim_id"
    "$(get_xctest_tool_path "$SDK_IPHONESIMULATOR")"
  )

  if [ -n "$SESSION_LOGIC_LAUNCH_OPTIONS_JSON" ] &&
     json_file_has_key "$SESSION_LOGIC_LAUNCH_OPTIONS_JSON" 'args'; then
    while IFS= read -r value; do
      [ -n "$value" ] || continue
      command+=("$value")
    done < <(json_file_array_lines "$SESSION_LOGIC_LAUNCH_OPTIONS_JSON" 'args')
  fi

  if [ -n "$SESSION_LOGIC_LAUNCH_OPTIONS_JSON" ] &&
     json_file_has_key "$SESSION_LOGIC_LAUNCH_OPTIONS_JSON" 'tests_to_run'; then
    local collected=()
    while IFS= read -r value; do
      [ -n "$value" ] || continue
      collected+=("$value")
    done < <(json_file_array_lines "$SESSION_LOGIC_LAUNCH_OPTIONS_JSON" 'tests_to_run')
    if [ "${#collected[@]}" -gt 0 ]; then
      local joined
      joined=''
      for line in "${collected[@]}"; do
        if [ -z "$joined" ]; then
          joined="$line"
        else
          joined="${joined},${line}"
        fi
      done
      tests_to_run="$joined"
    fi
  fi

  if [ -n "$SESSION_LOGIC_LAUNCH_OPTIONS_JSON" ] &&
     json_file_has_key "$SESSION_LOGIC_LAUNCH_OPTIONS_JSON" 'env_vars'; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      value=$(json_file_get_raw "$SESSION_LOGIC_LAUNCH_OPTIONS_JSON" "env_vars.${key}" 2>/dev/null || true)
      env_args+=("SIMCTL_CHILD_${key}=${value}")
    done < <(json_file_dict_keys "$SESSION_LOGIC_LAUNCH_OPTIONS_JSON" 'env_vars')
  fi

  env_args+=("NSUnbufferedIO=YES")

  if [ -n "${DEVELOPER_DIR:-}" ]; then
    env_args+=("DEVELOPER_DIR=${DEVELOPER_DIR}")
  fi

  if [ -n "$os_version" ] && [ "$(get_xcode_version_number)" -ge 1100 ] &&
     [ "$(version_to_number "$os_version")" -lt 1220 ]; then
    env_args+=("SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH=$(get_swift5_fallback_libs_dir)")
  fi

  set +e
  env "${env_args[@]}" "${command[@]}" -XCTest "$tests_to_run" "$test_bundle_path"
  return_code=$?
  set -e

  if [ "$return_code" -ne 0 ]; then
    return "$EXITCODE_FAILED"
  fi
  return "$EXITCODE_SUCCEEDED"
}

_move_and_replace_file() {
  local src_file="$1"
  local target_parent_dir="$2"
  local new_file_path

  new_file_path="${target_parent_dir%/}/$(basename "$src_file")"
  safe_rm_rf "$new_file_path"
  mv "$src_file" "$new_file_path"
  printf '%s\n' "$new_file_path"
}

_copy_and_sign_framework() {
  local src_framework="$1"
  local target_parent_dir="$2"
  local signing_identity="$3"
  local target_path

  target_path="${target_parent_dir%/}/$(basename "$src_framework")"
  safe_rm_rf "$target_path"
  cp -R "$src_framework" "$target_path"
  bundle_codesign "$target_path" '' "$signing_identity"
}

_copy_and_sign_lib() {
  local src_lib="$1"
  local target_parent_dir="$2"
  local signing_identity="$3"
  local target_path

  target_path="${target_parent_dir%/}/$(basename "$src_lib")"
  rm -f "$target_path"
  cp "$src_lib" "$target_path"
  bundle_codesign "$target_path" '' "$signing_identity"
}

_json_array_is_single_all() {
  local json_file="$1"
  local keypath="$2"
  local count
  local first

  count=$(json_file_array_count "$json_file" "$keypath")
  if [ "$count" -ne 1 ]; then
    return 1
  fi

  first=$(json_file_get_raw "$json_file" "${keypath}.0" 2>/dev/null || true)
  [ "$first" = 'all' ]
}

_is_truthy() {
  local value="$1"
  case "$value" in
    true|TRUE|True|1|YES|yes|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
