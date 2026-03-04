#!/usr/bin/env bash

PLUTIL_BIN='/usr/bin/plutil'
PLISTBUDDY_BIN='/usr/libexec/PlistBuddy'

ensure_plist_tools() {
  if [ ! -x "$PLUTIL_BIN" ]; then
    fatal "plutil not found at ${PLUTIL_BIN}" || return 1
  fi
  if [ ! -x "$PLISTBUDDY_BIN" ]; then
    fatal "PlistBuddy not found at ${PLISTBUDDY_BIN}" || return 1
  fi
}

__path_join_dot() {
  local left="$1"
  local right="$2"
  if [ -z "$left" ]; then
    printf '%s' "$right"
  else
    printf '%s.%s' "$left" "$right"
  fi
}

plist_init_empty_dict() {
  local plist_file="$1"
  cat >"$plist_file" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
PLIST
}

plist_has_key() {
  local plist_file="$1"
  local keypath="$2"
  "$PLUTIL_BIN" -extract "$keypath" raw -o - "$plist_file" >/dev/null 2>&1
}

plist_remove_key() {
  local plist_file="$1"
  local keypath="$2"
  "$PLUTIL_BIN" -remove "$keypath" "$plist_file" >/dev/null 2>&1 || true
}

plist_set_string() {
  local plist_file="$1"
  local keypath="$2"
  local value="$3"
  if plist_has_key "$plist_file" "$keypath"; then
    "$PLUTIL_BIN" -replace "$keypath" -string "$value" "$plist_file"
  else
    "$PLUTIL_BIN" -insert "$keypath" -string "$value" "$plist_file"
  fi
}

plist_set_bool() {
  local plist_file="$1"
  local keypath="$2"
  local value="$3"
  if plist_has_key "$plist_file" "$keypath"; then
    "$PLUTIL_BIN" -replace "$keypath" -bool "$value" "$plist_file"
  else
    "$PLUTIL_BIN" -insert "$keypath" -bool "$value" "$plist_file"
  fi
}

plist_set_integer() {
  local plist_file="$1"
  local keypath="$2"
  local value="$3"
  if plist_has_key "$plist_file" "$keypath"; then
    "$PLUTIL_BIN" -replace "$keypath" -integer "$value" "$plist_file"
  else
    "$PLUTIL_BIN" -insert "$keypath" -integer "$value" "$plist_file"
  fi
}

plist_set_json() {
  local plist_file="$1"
  local keypath="$2"
  local json_value="$3"
  if plist_has_key "$plist_file" "$keypath"; then
    "$PLUTIL_BIN" -replace "$keypath" -json "$json_value" "$plist_file"
  else
    "$PLUTIL_BIN" -insert "$keypath" -json "$json_value" "$plist_file"
  fi
}

plist_extract_raw() {
  local plist_file="$1"
  local keypath="$2"
  "$PLUTIL_BIN" -extract "$keypath" raw -o - "$plist_file"
}

plist_extract_json() {
  local plist_file="$1"
  local keypath="$2"
  "$PLUTIL_BIN" -extract "$keypath" json -o - "$plist_file"
}

plist_first_root_key() {
  local plist_file="$1"
  "$PLISTBUDDY_BIN" -c 'Print' "$plist_file" 2>/dev/null |
    awk '/ = / {print $1; exit}'
}

json_file_has_key() {
  local json_file="$1"
  local keypath="$2"
  "$PLUTIL_BIN" -extract "$keypath" raw -o - "$json_file" >/dev/null 2>&1
}

json_file_get_raw() {
  local json_file="$1"
  local keypath="$2"
  "$PLUTIL_BIN" -extract "$keypath" raw -o - "$json_file"
}

json_file_get_json() {
  local json_file="$1"
  local keypath="$2"
  "$PLUTIL_BIN" -extract "$keypath" json -o - "$json_file"
}

json_file_array_lines() {
  local json_file="$1"
  local keypath="$2"
  local idx=0
  local path
  local value
  while true; do
    path="$(__path_join_dot "$keypath" "$idx")"
    if ! value=$(json_file_get_raw "$json_file" "$path" 2>/dev/null); then
      break
    fi
    printf '%s\n' "$value"
    idx=$((idx + 1))
  done
}

json_file_array_count() {
  local json_file="$1"
  local keypath="$2"
  local idx=0
  local path
  while true; do
    path="$(__path_join_dot "$keypath" "$idx")"
    if ! json_file_get_raw "$json_file" "$path" >/dev/null 2>&1; then
      break
    fi
    idx=$((idx + 1))
  done
  printf '%s\n' "$idx"
}

json_file_dict_keys() {
  local json_file="$1"
  local keypath="${2:-}"
  local tmp_xml

  tmp_xml=$(mktemp)
  track_temp_path "$tmp_xml"

  if [ -n "$keypath" ]; then
    "$PLUTIL_BIN" -extract "$keypath" xml1 -o "$tmp_xml" "$json_file" >/dev/null 2>&1 || return 1
  else
    "$PLUTIL_BIN" -convert xml1 -o "$tmp_xml" "$json_file" >/dev/null 2>&1 || return 1
  fi

  # This is sufficient for launch/signing options where values are flat.
  sed -n 's@^[[:space:]]*<key>\(.*\)</key>[[:space:]]*$@\1@p' "$tmp_xml"
}

json_fragment_to_file() {
  local json_fragment="$1"
  local out_file="$2"
  printf '%s' "$json_fragment" >"$out_file"
}

plist_merge_json_object() {
  local plist_file="$1"
  local keypath="$2"
  local add_json="$3"
  local add_json_file
  local key
  local value_json

  add_json_file=$(mktemp)
  track_temp_path "$add_json_file"
  json_fragment_to_file "$add_json" "$add_json_file"

  if ! plist_has_key "$plist_file" "$keypath"; then
    plist_set_json "$plist_file" "$keypath" '{}'
  fi

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    value_json=$(json_file_get_json "$add_json_file" "$key" 2>/dev/null || true)
    [ -n "$value_json" ] || continue
    plist_set_json "$plist_file" "${keypath}.${key}" "$value_json"
  done < <(json_file_dict_keys "$add_json_file" '')
}

plist_merge_json_object_from_json_file() {
  local plist_file="$1"
  local keypath="$2"
  local json_file="$3"
  local source_keypath="$4"
  local key
  local value_json

  if ! plist_has_key "$plist_file" "$keypath"; then
    plist_set_json "$plist_file" "$keypath" '{}'
  fi

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    value_json=$(json_file_get_json "$json_file" "${source_keypath}.${key}" 2>/dev/null || true)
    [ -n "$value_json" ] || continue
    plist_set_json "$plist_file" "${keypath}.${key}" "$value_json"
  done < <(json_file_dict_keys "$json_file" "$source_keypath")
}
