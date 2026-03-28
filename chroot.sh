#!/usr/bin/env bash
# Stage 2 installer: runs inside chroot (/root/chroot.sh)
# Applies system configuration, installs packages, bootloader, services, and users.

set -Eeuo pipefail

# shellcheck source=/root/lib.sh
source /root/lib.sh

CONFIG_FILE="/root/config.toml"
SETTINGS_FILE="/root/settings.json"

HOSTNAME=""
USERNAME=""
ROOT_PASSWORD=""
USER_PASSWORD=""
TIMEZONE=""
LOCALE=""
KEYMAP=""

on_error() {
  local code=$?
  log_error "Chroot stage failed at line $1 (exit code: $code)."
  exit "$code"
}
trap 'on_error $LINENO' ERR

check_chroot_environment() {
  require_root
  assert_gentoo "chroot.sh"

  for cmd in emerge env-update source eselect locale-gen ln hwclock rc-update useradd chpasswd awk; do
    need_cmd "$cmd"
  done

  [[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE"
  [[ -f "$SETTINGS_FILE" ]] || die "Missing $SETTINGS_FILE"
}

emerge_with_autounmask() {
  if [[ $# -eq 0 ]]; then
    die "emerge_with_autounmask requires at least one package atom."
  fi

  if emerge --ask=n "$@"; then
    return 0
  fi

  log_warn "Initial emerge failed; retrying with autounmask enabled."
  emerge \
    --ask=n \
    --autounmask=y \
    --autounmask-write=y \
    --autounmask-continue=y \
    --autounmask-backtrack=y \
    "$@"
}

ensure_bootloader_tools() {
  if ! command -v grub-install >/dev/null 2>&1 || ! command -v grub-mkconfig >/dev/null 2>&1; then
    log_info "GRUB tools missing; installing sys-boot/grub and sys-boot/efibootmgr"
    emerge_with_autounmask sys-boot/grub sys-boot/efibootmgr
  fi

  need_cmd grub-install
  need_cmd grub-mkconfig
}

load_settings() {
  HOSTNAME="$(json_get_string "$SETTINGS_FILE" hostname)"
  USERNAME="$(json_get_string "$SETTINGS_FILE" username)"
  ROOT_PASSWORD="$(json_get_string "$SETTINGS_FILE" root_password)"
  USER_PASSWORD="$(json_get_string "$SETTINGS_FILE" user_password)"
  TIMEZONE="$(json_get_string "$SETTINGS_FILE" timezone)"
  LOCALE="$(json_get_string "$SETTINGS_FILE" locale)"
  KEYMAP="$(json_get_string "$SETTINGS_FILE" keymap)"

  HOSTNAME="${HOSTNAME:-gentoo}"
  USERNAME="${USERNAME:-oz}"
  ROOT_PASSWORD="${ROOT_PASSWORD:-wizard}"
  USER_PASSWORD="${USER_PASSWORD:-wizard}"
  TIMEZONE="${TIMEZONE:-America/New_York}"
  LOCALE="${LOCALE:-en_US.UTF-8}"
  KEYMAP="${KEYMAP:-us}"

  log_ok "Loaded settings for host '$HOSTNAME' and user '$USERNAME'"
}

configure_portage() {
  log_info "Refreshing portage tree"
  emerge-webrsync || emerge --sync
}

configure_portage_licenses() {
  local license_dir="/etc/portage/package.license"
  local license_file="${license_dir}/artix-omakase"

  mkdir -p "$license_dir"
  touch "$license_file"

  if grep -Eq '^sys-kernel/linux-firmware([[:space:]]+|$).*linux-fw-redistributable' "$license_file"; then
    log_info "Portage license override for linux-firmware already present"
    return
  fi

  log_info "Accepting linux-fw-redistributable for sys-kernel/linux-firmware"
  echo "sys-kernel/linux-firmware linux-fw-redistributable" >> "$license_file"
}

configure_system_basics() {
  log_info "Configuring hostname"
  echo "$HOSTNAME" > /etc/hostname

  cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

  log_info "Configuring timezone: $TIMEZONE"
  echo "$TIMEZONE" > /etc/timezone
  emerge --config sys-libs/timezone-data >/dev/null 2>&1 || true

  log_info "Configuring locale: $LOCALE"
  grep -Eq "^${LOCALE//./\\.} UTF-8$" /etc/locale.gen || echo "$LOCALE UTF-8" >> /etc/locale.gen
  locale-gen
  eselect locale set "$LOCALE" || true

  env-update
  # Some profile snippets may assume variables exist and can fail under `set -u`.
  # shellcheck disable=SC1091
  set +u
  source /etc/profile
  set -u

  log_info "Configuring keymap: $KEYMAP"
  cat > /etc/conf.d/keymaps <<KEYMAPCONF
keymap="${KEYMAP}"
KEYMAPCONF
}

install_packages_from_config() {
  local packages additional filtered pkg
  mapfile -t packages < <(parse_toml_packages "$CONFIG_FILE")
  mapfile -t additional < <(json_get_additional_packages "$SETTINGS_FILE")

  if [[ ${#additional[@]} -gt 0 ]]; then
    log_info "Appending additional packages from settings.json"
    packages+=("${additional[@]}")
  fi

  filtered=()
  for pkg in "${packages[@]}"; do
    pkg="${pkg%\"}"
    pkg="${pkg#\"}"
    pkg="$(printf '%s' "$pkg" | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')"
    [[ -n "$pkg" ]] || continue
    if [[ "$pkg" =~ ^[A-Za-z0-9+_.-]+/[A-Za-z0-9+_.@:-]+$ ]]; then
      filtered+=("$pkg")
    else
      log_warn "Skipping invalid package atom from config/settings: '$pkg'"
    fi
  done

  mapfile -t packages < <(printf '%s\n' "${filtered[@]}" | awk '!seen[$0]++')
  [[ ${#packages[@]} -gt 0 ]] || die "No packages to install."

  log_info "Installing ${#packages[@]} packages from config.toml"
  emerge_with_autounmask "${packages[@]}"
}

validate_boot_mountpoint() {
  if ! findmnt /boot >/dev/null 2>&1; then
    die "/boot is not mounted inside chroot. Mount the EFI partition at /boot and retry."
  fi

  if [[ ! -d /boot ]] || [[ ! -w /boot ]]; then
    die "/boot is unavailable or not writable. Fix the mount and permissions, then retry."
  fi
}

configure_dist_kernel_if_present() {
  local configured=0

  if emerge --config sys-kernel/gentoo-kernel-bin; then
    configured=1
  fi

  if emerge --config sys-kernel/gentoo-kernel; then
    configured=1
  fi

  if [[ "$configured" -eq 1 ]]; then
    log_ok "Kernel post-install hooks completed."
  else
    log_info "No configured dist-kernel package post-install hooks were run."
  fi
}

configure_bootloader() {
  log_info "Installing GRUB to EFI"
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo
  grub-mkconfig -o /boot/grub/grub.cfg
}

enable_services() {
  log_info "Enabling OpenRC services"
  rc-update add NetworkManager default
  rc-update add sshd default || true
  rc-update add keymaps boot || true
}

configure_privilege_escalation() {
  if [[ ! -f /etc/sudoers.bak_omakase ]]; then
    cp /etc/sudoers /etc/sudoers.bak_omakase
  fi

  grep -Eq '^%wheel ALL=\(ALL:ALL\) ALL' /etc/sudoers || echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers

  cat > /etc/doas.conf <<DOAS
permit persist :wheel
DOAS
  chmod 0400 /etc/doas.conf
}

create_user_and_passwords() {
  log_info "Setting root password"
  echo "root:${ROOT_PASSWORD}" | chpasswd

  if id "$USERNAME" >/dev/null 2>&1; then
    log_warn "User '$USERNAME' already exists; updating password and groups."
    usermod -aG wheel,video,audio,input,usb,plugdev "$USERNAME"
  else
    log_info "Creating user: $USERNAME"
    useradd -m -G wheel,video,audio,input,usb,plugdev -s /bin/bash "$USERNAME"
  fi

  echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

  install -m 0755 /root/post-install.sh "/home/${USERNAME}/post-install.sh"
  chown "$USERNAME:$USERNAME" "/home/${USERNAME}/post-install.sh"
}

cleanup() {
  log_ok "Chroot stage finished cleanly"
}

main() {
  check_chroot_environment
  load_settings
  configure_portage
  configure_portage_licenses
  configure_system_basics
  install_packages_from_config
  ensure_bootloader_tools
  validate_boot_mountpoint
  configure_dist_kernel_if_present
  configure_bootloader
  enable_services
  configure_privilege_escalation
  create_user_and_passwords
  cleanup
}

main "$@"
