#!/usr/bin/env bash

VERBOSE=0

# Paths tracked for best-effort cleanup.
__TRACKED_TEMP_PATHS=()

now_epoch() {
  date '+%s'
}

log_ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
  printf '%s %s\n' "$(log_ts)" "$*" >&2
}

log_warn() {
  printf '%s WARNING: %s\n' "$(log_ts)" "$*" >&2
}

log_error() {
  printf '%s ERROR: %s\n' "$(log_ts)" "$*" >&2
}

log_debug() {
  if [ "${VERBOSE}" -eq 1 ]; then
    printf '%s DEBUG: %s\n' "$(log_ts)" "$*" >&2
  fi
}

fatal() {
  log_error "$*"
  return 1
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fatal "Required command not found: ${cmd}" || return 1
  fi
}

track_temp_path() {
  __TRACKED_TEMP_PATHS+=("$1")
}

cleanup_tracked_paths() {
  local path
  for path in "${__TRACKED_TEMP_PATHS[@]}"; do
    [ -n "$path" ] || continue
    if [ -e "$path" ]; then
      rm -rf "$path" >/dev/null 2>&1 || true
    fi
  done
  __TRACKED_TEMP_PATHS=()
}

json_escape() {
  local raw="$1"
  raw=${raw//\\/\\\\}
  raw=${raw//\"/\\\"}
  raw=${raw//$'\n'/\\n}
  raw=${raw//$'\r'/\\r}
  raw=${raw//$'\t'/\\t}
  printf '%s' "$raw"
}

json_string() {
  printf '"%s"' "$(json_escape "$1")"
}

json_array_from_strings() {
  local first=1
  local item
  printf '['
  for item in "$@"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ','
    fi
    json_string "$item"
  done
  printf ']'
}

mktemp_dir() {
  local parent="${1:-}"
  if [ -n "$parent" ]; then
    mkdir -p "$parent"
    mktemp -d "${parent%/}/xctestrunner.XXXXXX"
  else
    mktemp -d
  fi
}

safe_rm_rf() {
  local target="$1"
  [ -n "$target" ] || return 0
  [ "$target" != "/" ] || return 0
  rm -rf "$target"
}
