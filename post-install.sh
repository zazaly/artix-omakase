#!/usr/bin/env bash
# Stage 3 script: run as normal user after first boot.
# Generates package manifest and prints optional next-step guidance.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
  # shellcheck source=lib.sh
  source "${SCRIPT_DIR}/lib.sh"
elif [[ -f /root/lib.sh ]]; then
  # shellcheck source=/root/lib.sh
  source /root/lib.sh
else
  # Fallback tiny logger if lib.sh is unavailable.
  log_info()  { echo "[INFO] $*"; }
  log_ok()    { echo "[ OK ] $*"; }
  log_warn()  { echo "[WARN] $*"; }
  log_error() { echo "[ERR ] $*" >&2; }
  die()       { log_error "$*"; exit 1; }
fi

[[ "${EUID}" -ne 0 ]] || die "Run post-install.sh as your normal user, not root."
command -v pacman >/dev/null 2>&1 || die "pacman not found. Are you on Artix/Arch-based system?"

OUT_FILE="$HOME/installed-packages.txt"

log_info "Generating explicit package list..."
{
  echo "# Omakase package snapshot"
  echo "# Host: $(hostname)"
  echo "# Date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "#"
  echo "# Restore hint:"
  echo "#   sudo pacman -S --needed - < installed-packages.txt"
  echo
  pacman -Qqe
} > "$OUT_FILE"

log_ok "Wrote package list: $OUT_FILE"

echo
echo "Welcome to your Omakase Artix install, $(whoami)!"
echo ""
echo "To reset/reinstall packages later:"
echo "  sudo pacman -S --needed - < ~/installed-packages.txt"
echo ""
echo "Optional next steps:"
echo "  - Install an AUR helper (e.g. paru)"
echo "  - Clone your dotfiles"
echo "  - Enable additional OpenRC services as needed"
