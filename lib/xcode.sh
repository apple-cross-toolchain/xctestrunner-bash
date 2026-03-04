#!/usr/bin/env bash

_XCODE_VERSION_NUMBER=''

version_to_number() {
  local version_str="$1"
  local major minor patch
  major=0
  minor=0
  patch=0

  IFS='.' read -r major minor patch <<EOF_PARTS
$version_str
EOF_PARTS

  major=${major:-0}
  minor=${minor:-0}
  patch=${patch:-0}

  printf '%s\n' "$((major * 100 + minor * 10 + patch))"
}

get_xcode_developer_path() {
  xcode-select -p
}

get_xcode_version_number() {
  if [ -n "$_XCODE_VERSION_NUMBER" ]; then
    printf '%s\n' "$_XCODE_VERSION_NUMBER"
    return 0
  fi

  local output
  local version
  output=$(xcodebuild -version)
  version=$(printf '%s\n' "$output" | awk 'NR==1 {print $2}')
  _XCODE_VERSION_NUMBER=$(version_to_number "$version")
  printf '%s\n' "$_XCODE_VERSION_NUMBER"
}

get_sdk_platform_path() {
  local sdk="$1"
  xcrun --sdk "$sdk" --show-sdk-platform-path
}

get_sdk_version() {
  local sdk="$1"
  xcrun --sdk "$sdk" --show-sdk-version
}

get_xctest_tool_path() {
  local sdk="$1"
  printf '%s/Developer/Library/Xcode/Agents/xctest\n' "$(get_sdk_platform_path "$sdk")"
}

get_darwin_user_cache_dir() {
  getconf DARWIN_USER_CACHE_DIR
}

get_xcode_embedded_app_deltas_dir() {
  printf '%s/com.apple.DeveloperTools/All/Xcode/EmbeddedAppDeltas\n' "$(get_darwin_user_cache_dir)"
}

get_swift5_fallback_libs_dir() {
  local developer_path
  local libs_dir
  local platform_dir

  developer_path=$(get_xcode_developer_path)
  libs_dir="${developer_path%/}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0"
  platform_dir="${libs_dir%/}/${SDK_IPHONESIMULATOR}"
  if [ -d "$platform_dir" ]; then
    printf '%s\n' "$platform_dir"
    return 0
  fi
  printf '%s\n' "$libs_dir"
}
