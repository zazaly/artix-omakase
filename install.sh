#!/usr/bin/env bash
# Stage 1 installer: run in Gentoo live environment as root.
# Performs destructive disk partitioning, filesystems, stage3 bootstrap, and chroot handoff.

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
STAGE3_URL=""
TARGET_MNT="/mnt/gentoo"

on_error() {
  local code=$?
  log_error "Installation failed at line $1 (exit code: $code)."
  exit "$code"
}
trap 'on_error $LINENO' ERR

check_environment() {
  require_root
  assert_gentoo "install.sh"

  for cmd in lsblk sgdisk mkfs.vfat mkfs.ext4 mount umount tar chroot awk wget udevadm; do
    need_cmd "$cmd"
  done

  if [[ ! -d /sys/firmware/efi ]]; then
    die "UEFI firmware not detected. This installer supports UEFI only."
  fi

  [[ -f "$CONFIG_FILE" ]] || die "Missing config.toml at: $CONFIG_FILE"
}

load_or_prompt_settings() {
  local default_username="oz"
  local default_hostname="gentoo"
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
  "stage3_url": "",
  "additional_packages": []
}
JSON

    log_ok "Wrote settings template to: $SETTINGS_FILE"
    cp -n "$SETTINGS_FILE" "$SETTINGS_EXAMPLE" || true
  fi

  BOOT_PART_SIZE="$(json_get_string "$SETTINGS_FILE" "boot_part_size")"
  ROOT_PART_SIZE="$(json_get_string "$SETTINGS_FILE" "root_part_size")"
  STAGE3_URL="$(json_get_string "$SETTINGS_FILE" "stage3_url")"
  BOOT_PART_SIZE="${BOOT_PART_SIZE:-$default_boot_part_size}"
  ROOT_PART_SIZE="${ROOT_PART_SIZE:-$default_root_part_size}"

  log_info "Partition sizes from settings: BOOT=${BOOT_PART_SIZE}, ROOT=${ROOT_PART_SIZE}, HOME=remaining"
}

show_disks_and_choose() {
  local -a drives
  local selection
  local i

  mapfile -t drives < <(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" {print "/dev/" $1}')
  [[ "${#drives[@]}" -gt 0 ]] || die "No block devices detected."

  log_info "Select target drive:"
  for i in "${!drives[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${drives[$i]}"
  done

  read -r -p "Drive number (1-${#drives[@]}): " selection
  [[ "$selection" =~ ^[0-9]+$ ]] || die "Selection must be a number."
  (( selection >= 1 && selection <= ${#drives[@]} )) || die "Selection out of range."

  TARGET_DRIVE="${drives[$((selection - 1))]}"
  [[ -b "$TARGET_DRIVE" ]] || die "Invalid block device selected: $TARGET_DRIVE"

  log_info "Selected drive: $TARGET_DRIVE"
}

partition_drive() {
  log_info "Deleting all existing partitions on $TARGET_DRIVE"
  sgdisk --zap-all "$TARGET_DRIVE"
  sgdisk --clear "$TARGET_DRIVE"

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

  # Allow the kernel/udev a moment to expose newly created partitions.
  udevadm settle || true
  for _ in {1..10}; do
    if [[ -b "$EFI_PART" && -b "$ROOT_PART" && -b "$HOME_PART" ]]; then
      break
    fi
    partprobe "$TARGET_DRIVE" || true
    sleep 1
  done

  [[ -b "$EFI_PART" && -b "$ROOT_PART" && -b "$HOME_PART" ]] || die "Partition devices not found after partitioning."
  log_ok "Partitions created: $EFI_PART, $ROOT_PART, $HOME_PART"
}

format_and_mount() {
  log_info "Formatting partitions"

  # In some live environments the partition table appears first, but mkfs.vfat
  # can still race with udev and fail with exit code 1.
  local attempt=0
  local fat32_done=0
  for attempt in {1..5}; do
    if mkfs.vfat -F32 -n BOOT "$EFI_PART"; then
      fat32_done=1
      break
    fi
    log_warn "Failed to format $EFI_PART as FAT32 (attempt ${attempt}/5). Retrying..."
    udevadm settle || true
    partprobe "$TARGET_DRIVE" || true
    sleep 1
  done
  [[ "$fat32_done" -eq 1 ]] || die "Unable to format EFI partition: $EFI_PART"

  mkfs.ext4 -F -L ROOT "$ROOT_PART"
  mkfs.ext4 -F -L HOME "$HOME_PART"

  log_info "Mounting target filesystem at ${TARGET_MNT}"
  mkdir -p "$TARGET_MNT"
  mount "$ROOT_PART" "$TARGET_MNT"
  mkdir -p "$TARGET_MNT/boot" "$TARGET_MNT/home"
  mount "$EFI_PART" "$TARGET_MNT/boot"
  mount "$HOME_PART" "$TARGET_MNT/home"

  log_ok "Mount layout prepared"
}

download_and_extract_stage3() {
  local stage3_tarball="/tmp/stage3-amd64.tar.xz"
  local stage3_base_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc"
  local stage3_latest_index_url="${stage3_base_url}/latest-stage3-amd64-openrc.txt"
  local default_stage3_url=""
  local latest_stage3_relpath=""

  latest_stage3_relpath="$(wget -qO- "$stage3_latest_index_url" | awk '!/^[[:space:]]*#/ && NF {print $1; exit}' || true)"
  if [[ -n "$latest_stage3_relpath" ]]; then
    default_stage3_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_stage3_relpath}"
  else
    # Fallback kept for resilience if index parsing fails.
    default_stage3_url="${stage3_base_url}/stage3-amd64-openrc.tar.xz"
    log_warn "Could not parse ${stage3_latest_index_url}; using fallback stage3 filename."
  fi

  if [[ -z "$STAGE3_URL" ]]; then
    STAGE3_URL="$default_stage3_url"
    log_warn "stage3_url not set in settings.json; using latest OpenRC stage3 URL."
  fi

  log_info "Validating stage3 URL"
  if ! wget --spider --tries=2 --timeout=20 "$STAGE3_URL"; then
    if [[ "$STAGE3_URL" != "$default_stage3_url" ]]; then
      log_warn "Configured stage3_url is unreachable. Falling back to detected latest stage3 URL."
      STAGE3_URL="$default_stage3_url"
    fi
    wget --spider --tries=2 --timeout=20 "$STAGE3_URL" || die "Stage3 URL is not reachable: $STAGE3_URL"
  fi

  log_info "Downloading stage3 tarball from: $STAGE3_URL"
  wget --tries=3 --waitretry=2 --timeout=30 -O "$stage3_tarball" "$STAGE3_URL" || die "Failed to download stage3 tarball from: $STAGE3_URL"

  log_info "Verifying downloaded stage3 archive"
  tar -tf "$stage3_tarball" >/dev/null || die "Downloaded stage3 tarball is invalid: $stage3_tarball"

  log_info "Extracting stage3 into ${TARGET_MNT}"
  tar xpf "$stage3_tarball" --xattrs-include='*.*' --numeric-owner -C "$TARGET_MNT"

  cp -L /etc/resolv.conf "$TARGET_MNT/etc/resolv.conf"
}

generate_fstab() {
  log_info "Generating ${TARGET_MNT}/etc/fstab"
  cat > "${TARGET_MNT}/etc/fstab" <<FSTAB
# <fs>                                 <mountpoint> <type>  <opts>         <dump/pass>
$(blkid -s UUID -o value "$ROOT_PART") /     ext4  noatime       0 1
$(blkid -s UUID -o value "$EFI_PART")  /boot vfat  noatime       0 2
$(blkid -s UUID -o value "$HOME_PART") /home ext4  noatime       0 2
FSTAB

  sed -i 's#^#UUID=#' "${TARGET_MNT}/etc/fstab"
}

copy_installer_files() {
  log_info "Copying installer files into new system"
  install -m 0644 "$CONFIG_FILE" "$TARGET_MNT/root/config.toml"
  install -m 0644 "$SETTINGS_FILE" "$TARGET_MNT/root/settings.json"
  install -m 0755 "$SCRIPT_DIR/lib.sh" "$TARGET_MNT/root/lib.sh"
  install -m 0755 "$SCRIPT_DIR/chroot.sh" "$TARGET_MNT/root/chroot.sh"
  install -m 0755 "$SCRIPT_DIR/post-install.sh" "$TARGET_MNT/root/post-install.sh"
}

prepare_chroot_mounts() {
  mount --types proc /proc "$TARGET_MNT/proc"
  mount --rbind /sys "$TARGET_MNT/sys"
  mount --make-rslave "$TARGET_MNT/sys"
  mount --rbind /dev "$TARGET_MNT/dev"
  mount --make-rslave "$TARGET_MNT/dev"
  mount --bind /run "$TARGET_MNT/run"
  mount --make-slave "$TARGET_MNT/run"
}

run_chroot_stage() {
  log_info "Entering chroot and launching stage 2..."
  chroot "$TARGET_MNT" /bin/bash /root/chroot.sh
  log_ok "Stage 2 complete."
}

finish_message() {
  log_ok "Installation stages 1 and 2 finished successfully."
  echo
  echo "Next steps:"
  echo "  1) umount -R ${TARGET_MNT}"
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
  download_and_extract_stage3
  generate_fstab
  copy_installer_files
  prepare_chroot_mounts
  run_chroot_stage
  finish_message
}

main "$@"
