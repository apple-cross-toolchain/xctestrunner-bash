#!/usr/bin/env bash

bundle_extract_app() {
  local compressed_app_path="$1"
  local working_dir="$2"

  case "$compressed_app_path" in
    *.ipa) ;;
    *) fatal "The extension of the compressed app should be .ipa: ${compressed_app_path}" || return 1 ;;
  esac

  local unzip_target_dir
  unzip_target_dir=$(mktemp_dir "$working_dir") || return 1
  track_temp_path "$unzip_target_dir"

  unzip -q -o "$compressed_app_path" -d "$unzip_target_dir" || {
    fatal "Failed to unzip ${compressed_app_path}" || return 1
  }

  _extract_single_bundle "${unzip_target_dir}/Payload" 'app'
}

bundle_extract_test_bundle() {
  local compressed_test_path="$1"
  local working_dir="$2"

  case "$compressed_test_path" in
    *.ipa|*.zip) ;;
    *) fatal "The extension of the compressed test should be .ipa or .zip: ${compressed_test_path}" || return 1 ;;
  esac

  local unzip_target_dir
  unzip_target_dir=$(mktemp_dir "$working_dir") || return 1
  track_temp_path "$unzip_target_dir"

  unzip -q -o "$compressed_test_path" -d "$unzip_target_dir" || {
    fatal "Failed to unzip ${compressed_test_path}" || return 1
  }

  _extract_single_bundle "$unzip_target_dir" 'xctest' ||
    _extract_single_bundle "${unzip_target_dir}/Payload" 'xctest'
}

bundle_get_minimum_os_version() {
  local bundle_path="$1"
  local info_plist="${bundle_path%/}/Info.plist"
  plist_extract_raw "$info_plist" 'MinimumOSVersion'
}

bundle_get_bundle_id() {
  local bundle_path="$1"
  local info_plist="${bundle_path%/}/Info.plist"
  plist_extract_raw "$info_plist" 'CFBundleIdentifier'
}

bundle_get_codesign_identity() {
  local bundle_path="$1"
  local output
  output=$(codesign -dvv "$bundle_path" 2>&1) || {
    fatal "Failed to inspect code signature on ${bundle_path}: ${output}" || return 1
  }
  local line
  while IFS= read -r line; do
    case "$line" in
      Authority=*)
        printf '%s\n' "${line#Authority=}"
        return 0
        ;;
    esac
  done <<EOF_OUTPUT
$output
EOF_OUTPUT
  fatal "Failed to extract signing identity from ${bundle_path}" || return 1
}

bundle_get_development_team() {
  local bundle_path="$1"
  local output
  output=$(codesign -dvv "$bundle_path" 2>&1) || {
    fatal "Failed to inspect code signature on ${bundle_path}: ${output}" || return 1
  }
  local line
  while IFS= read -r line; do
    case "$line" in
      TeamIdentifier=*)
        printf '%s\n' "${line#TeamIdentifier=}"
        return 0
        ;;
    esac
  done <<EOF_OUTPUT
$output
EOF_OUTPUT
  fatal "Failed to extract development team from ${bundle_path}" || return 1
}

bundle_codesign() {
  local bundle_path="$1"
  local entitlements_plist_path="${2:-}"
  local identity="${3:-}"

  if [ -z "$identity" ]; then
    identity=$(bundle_get_codesign_identity "$bundle_path") || return 1
  fi

  local output
  if [ -z "$entitlements_plist_path" ]; then
    output=$(codesign -f --preserve-metadata=identifier,entitlements --timestamp=none \
      -s "$identity" "$bundle_path" 2>&1) || {
      fatal "Failed to codesign ${bundle_path} with ${identity}: ${output}" || return 1
    }
  else
    output=$(codesign -f --entitlements "$entitlements_plist_path" --timestamp=none \
      -s "$identity" "$bundle_path" 2>&1) || {
      fatal "Failed to codesign ${bundle_path} with ${identity}: ${output}" || return 1
    }
  fi
}

bundle_enable_ui_file_sharing() {
  local bundle_path="$1"
  local resigning="${2:-true}"
  local info_plist="${bundle_path%/}/Info.plist"

  plist_set_bool "$info_plist" 'UIFileSharingEnabled' true || return 1
  if [ "$resigning" = 'true' ]; then
    bundle_codesign "$bundle_path" || return 1
  fi
}

bundle_get_file_archs() {
  local file_path="$1"
  /usr/bin/lipo "$file_path" -archs
}

bundle_remove_arch_type() {
  local file_path="$1"
  local arch_type="$2"
  /usr/bin/lipo "$file_path" -remove "$arch_type" -output "$file_path"
}

_extract_single_bundle() {
  local target_dir="$1"
  local bundle_ext="$2"
  local found=()
  local item

  [ -d "$target_dir" ] || {
    fatal "Directory not found while extracting bundle: ${target_dir}" || return 1
  }

  while IFS= read -r item; do
    [ -n "$item" ] || continue
    found+=("$item")
  done < <(find "$target_dir" -maxdepth 1 -name "*.${bundle_ext}" -print)

  if [ "${#found[@]}" -eq 0 ]; then
    fatal "No file with extension ${bundle_ext} is found under ${target_dir}." || return 1
  fi
  if [ "${#found[@]}" -gt 1 ]; then
    fatal "Multiple files with extension ${bundle_ext} are found under ${target_dir}: ${found[*]}" || return 1
  fi
  printf '%s\n' "${found[0]}"
}
