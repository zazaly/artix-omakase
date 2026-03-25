#!/usr/bin/env bash
# Stage 1 installer: run in Artix live environment as root.
# Performs destructive disk partitioning, filesystems, basestrap, and chroot handoff.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

SETTINGS_FILE="${SCRIPT_DIR}/settings.json"
SETTINGS_EXAMPLE="${SCRIPT_DIR}/settings.json.example"
CONFIG_FILE="${SCRIPT_DIR}/config.toml"

TARGET_DRIVE=""
EFI_PART=""
ROOT_PART=""
HOME_PART=""
BOOT_PART_SIZE="1GiB"
ROOT_PART_SIZE="40GiB"

on_error() {
  local code=$?
  log_error "Installation failed at line $1 (exit code: $code)."
  exit "$code"
}
trap 'on_error $LINENO' ERR

check_environment() {
  require_root
  for cmd in lsblk sgdisk mkfs.fat mkfs.ext4 mount umount basestrap fstabgen artix-chroot awk; do
    need_cmd "$cmd"
  done

  if [[ ! -d /sys/firmware/efi ]]; then
    die "UEFI firmware not detected. This installer supports UEFI only."
  fi

  if [[ ! -f /etc/artix-release ]]; then
    log_warn "This does not look like an Artix live environment (/etc/artix-release missing)."
    confirm "Continue anyway?" || die "Aborted by user."
  fi

  [[ -f "$CONFIG_FILE" ]] || die "Missing config.toml at: $CONFIG_FILE"
}

load_or_prompt_settings() {
  local default_username="oz"
  local default_hostname="desktop"
  local default_root_password="wizard"
  local default_user_password="wizard"
  local default_timezone="America/New_York"
  local default_locale="en_US.UTF-8"
  local default_keymap="us"
  local default_boot_part_size="1GiB"
  local default_root_part_size="40GiB"

  if [[ -f "$SETTINGS_FILE" ]]; then
    log_ok "Found settings file: $SETTINGS_FILE"
  else
    log_warn "settings.json not found. Prompting interactively and writing one."

    read -r -p "Username [${default_username}]: " username
    read -r -p "Hostname [${default_hostname}]: " hostname
    read -r -p "Root password [${default_root_password}]: " root_password
    read -r -p "User password [${default_user_password}]: " user_password
    read -r -p "Timezone [${default_timezone}]: " timezone
    read -r -p "Locale [${default_locale}]: " locale
    read -r -p "Keymap [${default_keymap}]: " keymap

    username="${username:-$default_username}"
    hostname="${hostname:-$default_hostname}"
    root_password="${root_password:-$default_root_password}"
    user_password="${user_password:-$default_user_password}"
    timezone="${timezone:-$default_timezone}"
    locale="${locale:-$default_locale}"
    keymap="${keymap:-$default_keymap}"

    cat > "$SETTINGS_FILE" <<JSON
{
  "username": "${username}",
  "hostname": "${hostname}",
  "root_password": "${root_password}",
  "user_password": "${user_password}",
  "timezone": "${timezone}",
  "locale": "${locale}",
  "keymap": "${keymap}",
  "boot_part_size": "${default_boot_part_size}",
  "root_part_size": "${default_root_part_size}",
  "additional_packages": []
}
JSON

    log_ok "Wrote settings template to: $SETTINGS_FILE"
    cp -n "$SETTINGS_FILE" "$SETTINGS_EXAMPLE" || true
  fi

  BOOT_PART_SIZE="$(json_get_string "$SETTINGS_FILE" "boot_part_size")"
  ROOT_PART_SIZE="$(json_get_string "$SETTINGS_FILE" "root_part_size")"
  BOOT_PART_SIZE="${BOOT_PART_SIZE:-$default_boot_part_size}"
  ROOT_PART_SIZE="${ROOT_PART_SIZE:-$default_root_part_size}"
  log_info "Partition sizes from settings: BOOT=${BOOT_PART_SIZE}, ROOT=${ROOT_PART_SIZE}, HOME=remaining"
}

show_disks_and_choose() {
  log_info "Available block devices:"
  echo
  lsblk -d -o NAME,SIZE,MODEL | sed '1d' | awk '{printf "  /dev/%-12s %-8s %s\n", $1, $2, substr($0, index($0,$3))}'
  echo

  read -r -p "Enter target drive (example: /dev/sda or /dev/nvme0n1): " TARGET_DRIVE
  [[ -b "$TARGET_DRIVE" ]] || die "Invalid block device: $TARGET_DRIVE"

  log_warn "You selected: $TARGET_DRIVE"
  log_warn "ALL DATA ON THIS DRIVE WILL BE DESTROYED."

  read -r -p "Type the full drive path again to confirm wipe: " confirm_drive
  [[ "$confirm_drive" == "$TARGET_DRIVE" ]] || die "Drive confirmation mismatch. Aborting."

  confirm "Final confirmation: wipe and repartition $TARGET_DRIVE ?" || die "Aborted by user."
}

partition_drive() {
  log_info "Wiping existing partition table on $TARGET_DRIVE"
  sgdisk --zap-all "$TARGET_DRIVE"

  log_info "Creating GPT partitions"
  sgdisk -n 1:1MiB:+"${BOOT_PART_SIZE}" -t 1:EF00 -c 1:BOOT "$TARGET_DRIVE"
  sgdisk -n 2:0:+"${ROOT_PART_SIZE}" -t 2:8300 -c 2:ROOT "$TARGET_DRIVE"
  sgdisk -n 3:0:0 -t 3:8300 -c 3:HOME "$TARGET_DRIVE"
  partprobe "$TARGET_DRIVE" || true

  if [[ "$TARGET_DRIVE" =~ nvme|mmcblk ]]; then
    EFI_PART="${TARGET_DRIVE}p1"
    ROOT_PART="${TARGET_DRIVE}p2"
    HOME_PART="${TARGET_DRIVE}p3"
  else
    EFI_PART="${TARGET_DRIVE}1"
    ROOT_PART="${TARGET_DRIVE}2"
    HOME_PART="${TARGET_DRIVE}3"
  fi

  [[ -b "$EFI_PART" && -b "$ROOT_PART" && -b "$HOME_PART" ]] || die "Partition devices not found after partitioning."
  log_ok "Partitions created: $EFI_PART, $ROOT_PART, $HOME_PART"
}

format_and_mount() {
  log_info "Formatting partitions"
  mkfs.fat -F32 -n BOOT "$EFI_PART"
  mkfs.ext4 -F -L ROOT "$ROOT_PART"
  mkfs.ext4 -F -L HOME "$HOME_PART"

  log_info "Mounting target filesystem at /mnt"
  mount "$ROOT_PART" /mnt
  mkdir -p /mnt/boot /mnt/home
  mount "$EFI_PART" /mnt/boot
  mount "$HOME_PART" /mnt/home

  log_ok "Mount layout prepared"
}

install_base_system() {
  local packages
  mapfile -t packages < <(parse_toml_packages "$CONFIG_FILE")
  if [[ ${#packages[@]} -eq 0 ]]; then
    die "No packages parsed from config.toml"
  fi

  log_info "Installing base system with basestrap (${#packages[@]} packages)"
  basestrap /mnt "${packages[@]}"

  log_info "Generating fstab"
  fstabgen -U /mnt > /mnt/etc/fstab

  log_info "Copying installer files into new system"
  install -m 0644 "$CONFIG_FILE" /mnt/root/config.toml
  install -m 0644 "$SETTINGS_FILE" /mnt/root/settings.json
  install -m 0755 "$SCRIPT_DIR/lib.sh" /mnt/root/lib.sh
  install -m 0755 "$SCRIPT_DIR/chroot.sh" /mnt/root/chroot.sh
  install -m 0755 "$SCRIPT_DIR/post-install.sh" /mnt/root/post-install.sh
}

run_chroot_stage() {
  log_info "Entering chroot and launching stage 2..."
  artix-chroot /mnt /root/chroot.sh
  log_ok "Stage 2 complete."
}

finish_message() {
  log_ok "Installation stages 1 and 2 finished successfully."
  echo
  echo "Next steps:"
  echo "  1) umount -R /mnt"
  echo "  2) reboot"
  echo "  3) log in as your new user"
  echo "  4) run: ~/post-install.sh"
  echo
}

main() {
  check_environment
  load_or_prompt_settings
  show_disks_and_choose
  partition_drive
  format_and_mount
  install_base_system
  run_chroot_stage
  finish_message
}

main "$@"
