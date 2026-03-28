#!/usr/bin/env bash
# Shared utility functions for all installer stages.

set -Eeuo pipefail

# -------- Colors --------
if [[ -t 1 ]]; then
  C_RED='\033[0;31m'
  C_GRN='\033[0;32m'
  C_YLW='\033[1;33m'
  C_BLU='\033[0;34m'
  C_RST='\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_RST=''
fi

log_info()  { printf "%b[INFO]%b %s\n" "$C_BLU" "$C_RST" "$*"; }
log_ok()    { printf "%b[ OK ]%b %s\n" "$C_GRN" "$C_RST" "$*"; }
log_warn()  { printf "%b[WARN]%b %s\n" "$C_YLW" "$C_RST" "$*"; }
log_error() { printf "%b[ERR ]%b %s\n" "$C_RED" "$C_RST" "$*" >&2; }

die() {
  log_error "$*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

confirm() {
  local prompt="${1:-Are you sure?}"
  local reply
  read -r -p "$prompt [y/N]: " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Reads a string value from settings.json if jq exists and key is present.
json_get_string() {
  local file="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -er ".${key} // empty" "$file" 2>/dev/null || true
  fi
}

# Reads additional_packages array from settings.json (space-separated).
json_get_additional_packages() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -er '.additional_packages // [] | .[]' "$file" 2>/dev/null || true
  fi
}

# Parse package groups from config.toml arrays, supporting both inline and
# multi-line forms:
#   group = ["pkg1", "pkg2"]
#   group = [
#     "pkg1",
#     "pkg2"
#   ]
# Returns a newline-separated package list, unique and sorted in input order.
parse_toml_packages() {
  local file="$1"
  [[ -f "$file" ]] || die "config.toml not found at $file"

  awk '
    /^[[:space:]]*#/ { next }
    {
      line=$0

      # Start of an array value assignment.
      if (!in_array && line ~ /^[[:space:]]*[a-zA-Z0-9_]+[[:space:]]*=[[:space:]]*\[/) {
        in_array=1
        sub(/^[^\[]*\[/, "", line)
      }

      if (in_array) {
        # Remove trailing comments, then parse tokens separated by commas.
        sub(/[[:space:]]*#.*/, "", line)
        has_close = (line ~ /\]/)
        sub(/\][^\]]*$/, "", line)
        gsub(/"/, "", line)

        n=split(line, arr, /,[[:space:]]*/)
        for (i=1; i<=n; i++) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", arr[i])
          if (arr[i] != "") print arr[i]
        }

        if (has_close) {
          in_array=0
        }
      }
    }
  ' "$file" | awk '!seen[$0]++'
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "This script must be run as root."
}

is_gentoo() {
  [[ -f /etc/gentoo-release ]]
}

assert_gentoo() {
  local context="${1:-this installer}"
  is_gentoo || die "${context} currently supports Gentoo only."
}
