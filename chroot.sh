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
  for cmd in pacman pacman-key locale-gen ln hwclock grub-install grub-mkconfig rc-update useradd chpasswd awk git make; do
    need_cmd "$cmd"
  done
  [[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE"
  [[ -f "$SETTINGS_FILE" ]] || die "Missing $SETTINGS_FILE"
}

load_settings() {
  HOSTNAME="$(json_get_string "$SETTINGS_FILE" hostname)"
  USERNAME="$(json_get_string "$SETTINGS_FILE" username)"
  ROOT_PASSWORD="$(json_get_string "$SETTINGS_FILE" root_password)"
  USER_PASSWORD="$(json_get_string "$SETTINGS_FILE" user_password)"
  TIMEZONE="$(json_get_string "$SETTINGS_FILE" timezone)"
  LOCALE="$(json_get_string "$SETTINGS_FILE" locale)"
  KEYMAP="$(json_get_string "$SETTINGS_FILE" keymap)"

  # Fallback defaults if jq is unavailable or values are empty.
  HOSTNAME="${HOSTNAME:-desktop}"
  USERNAME="${USERNAME:-oz}"
  ROOT_PASSWORD="${ROOT_PASSWORD:-wizard}"
  USER_PASSWORD="${USER_PASSWORD:-wizard}"
  TIMEZONE="${TIMEZONE:-America/New_York}"
  LOCALE="${LOCALE:-en_US.UTF-8}"
  KEYMAP="${KEYMAP:-us}"

  log_ok "Loaded settings for host '$HOSTNAME' and user '$USERNAME'"
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
  [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Invalid timezone: $TIMEZONE"
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  hwclock --systohc

  log_info "Configuring locale: $LOCALE"
  if ! grep -Eq "^${LOCALE//./\\.} UTF-8$" /etc/locale.gen; then
    echo "$LOCALE UTF-8" >> /etc/locale.gen
  fi
  locale-gen
  cat > /etc/locale.conf <<LC
LANG=$LOCALE
LC

  log_info "Configuring keymap: $KEYMAP"
  cat > /etc/vconsole.conf <<VC
KEYMAP=$KEYMAP
VC
}

initialize_pacman() {
  log_info "Initializing pacman keyring"
  pacman-key --init
  pacman-key --populate

  log_info "Updating package database"
  pacman -Syu --noconfirm
}

install_packages_from_config() {
  local packages additional
  mapfile -t packages < <(parse_toml_packages "$CONFIG_FILE")

  mapfile -t additional < <(json_get_additional_packages "$SETTINGS_FILE")
  if [[ ${#additional[@]} -gt 0 ]]; then
    log_info "Appending additional packages from settings.json"
    packages+=("${additional[@]}")
  fi

  # Ensure uniqueness while keeping order.
  mapfile -t packages < <(printf '%s\n' "${packages[@]}" | awk '!seen[$0]++')

  [[ ${#packages[@]} -gt 0 ]] || die "No packages to install."

  log_info "Installing ${#packages[@]} packages from config.toml"
  # --needed avoids reinstalling already-installed base packages.
  # --noconfirm ensures unattended execution in chroot stage.
  # --overwrite '*' provides resilience if package file overlaps occur.
  pacman -S --needed --noconfirm --overwrite '*' "${packages[@]}"

  # Explicit XLibre enforcement reminder and sanity check.
  if pacman -Q xorg-server >/dev/null 2>&1; then
    log_warn "xorg-server is installed; XLibre should replace it. Attempting cleanup."
    pacman -Rns --noconfirm xorg-server || true
  fi

  local required=(xlibre-xserver xlibre-xserver-common xlibre-video-amdgpu mesa vulkan-radeon lib32-mesa lib32-vulkan-radeon)
  local p
  for p in "${required[@]}"; do
    pacman -Q "$p" >/dev/null 2>&1 || die "Required package missing after install: $p"
  done
  log_ok "XLibre + AMD userspace stack verified"
}

install_suckless_stack() {
  local repos=(
    "https://github.com/bakkeby/dmenu-flexipatch"
    "https://github.com/bakkeby/st-flexipatch"
    "https://github.com/bakkeby/dwm-flexipatch"
  )
  local workdir="/usr/local/src/suckless-flexipatch"
  local repo name

  log_info "Building and installing suckless tools (dmenu, st, dwm)"
  install -d -m 0755 "$workdir"

  for repo in "${repos[@]}"; do
    name="${repo##*/}"
    if [[ -d "${workdir}/${name}/.git" ]]; then
      log_info "Refreshing existing repo: ${name}"
      git -C "${workdir}/${name}" pull --ff-only
    else
      log_info "Cloning repo: ${name}"
      git clone --depth 1 "$repo" "${workdir}/${name}"
    fi

    make -C "${workdir}/${name}" clean
    make -C "${workdir}/${name}"
    make -C "${workdir}/${name}" install
  done

  command -v dmenu >/dev/null 2>&1 || die "dmenu install verification failed"
  command -v st >/dev/null 2>&1 || die "st install verification failed"
  command -v dwm >/dev/null 2>&1 || die "dwm install verification failed"
  log_ok "Suckless toolchain installed"
}

configure_bootloader() {
  log_info "Refreshing /etc/fstab"
  fstabgen -U / > /etc/fstab

  log_info "Installing GRUB to EFI"
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  grub-mkconfig -o /boot/grub/grub.cfg
}

enable_services() {
  log_info "Enabling OpenRC services"
  rc-update add NetworkManager default
  rc-update add lightdm default
  rc-update add sshd default || true
}

configure_privilege_escalation() {
  # Wheel group sudo access (password required).
  if [[ ! -f /etc/sudoers.bak_omakase ]]; then
    cp /etc/sudoers /etc/sudoers.bak_omakase
  fi
  if ! grep -Eq '^%wheel ALL=\(ALL:ALL\) ALL' /etc/sudoers; then
    echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers
  fi

  # Minimal doas setup.
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
    usermod -aG wheel,video,audio,input,storage "$USERNAME"
  else
    log_info "Creating user: $USERNAME"
    useradd -m -G wheel,video,audio,input,storage -s /bin/bash "$USERNAME"
  fi

  echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

  # Place post-install script in user's home for stage 3 convenience.
  install -m 0755 /root/post-install.sh "/home/${USERNAME}/post-install.sh"
  chown "$USERNAME:$USERNAME" "/home/${USERNAME}/post-install.sh"

  cat > "/home/${USERNAME}/.xinitrc" <<'XINIT'
#!/bin/sh
exec dwm
XINIT
  chmod 0755 "/home/${USERNAME}/.xinitrc"
  chown "$USERNAME:$USERNAME" "/home/${USERNAME}/.xinitrc"
}

cleanup() {
  log_info "Cleaning package cache"
  pacman -Scc --noconfirm || true
  log_ok "Chroot stage finished cleanly"
}

main() {
  check_chroot_environment
  load_settings
  configure_system_basics
  initialize_pacman
  install_packages_from_config
  install_suckless_stack
  configure_bootloader
  enable_services
  configure_privilege_escalation
  create_user_and_passwords
  cleanup
}

main "$@"
