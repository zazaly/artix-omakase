#!/usr/bin/env bash
# Stage 3 script: run as normal user after first boot.
# Captures package world set and prints optional next-step guidance.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
  # shellcheck source=lib.sh
  source "${SCRIPT_DIR}/lib.sh"
elif [[ -f /root/lib.sh ]]; then
  # shellcheck source=/root/lib.sh
  source /root/lib.sh
else
  log_info()  { echo "[INFO] $*"; }
  log_ok()    { echo "[ OK ] $*"; }
  log_warn()  { echo "[WARN] $*"; }
  log_error() { echo "[ERR ] $*" >&2; }
  die()       { log_error "$*"; exit 1; }
  assert_gentoo() { [[ -f /etc/gentoo-release ]] || die "Gentoo environment not detected."; }
fi

[[ "${EUID}" -ne 0 ]] || die "Run post-install.sh as your normal user, not root."
assert_gentoo "post-install.sh"

OUT_FILE="$HOME/installed-packages.txt"
WORLD_FILE="/var/lib/portage/world"

[[ -f "$WORLD_FILE" ]] || die "Gentoo world file not found at $WORLD_FILE"

log_info "Generating Gentoo package world snapshot..."
{
  echo "# Omakase package snapshot (Gentoo world set)"
  echo "# Host: $(hostname)"
  echo "# Date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "#"
  echo "# Restore hint:"
  echo "#   sudo cp installed-packages.txt /var/lib/portage/world"
  echo "#   sudo emerge --ask --update --deep --newuse @world"
  echo
  cat "$WORLD_FILE"
} > "$OUT_FILE"

log_ok "Wrote package list: $OUT_FILE"

echo
echo "Welcome to your Omakase Gentoo install, $(whoami)!"
echo ""
echo "To rebuild your world set later:"
echo "  sudo emerge --ask --update --deep --newuse @world"
echo ""
echo "Optional next steps:"
echo "  - Configure USE flags in /etc/portage/package.use"
echo "  - Clone your dotfiles"
echo "  - Enable additional OpenRC services as needed"
