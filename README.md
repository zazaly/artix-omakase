# Omakase Gentoo Linux Install Script

A staged, beginner-friendly, **UEFI-only** Gentoo installer designed for testing in **virt-manager** and customization for real hardware.

> ⚠️ **Danger:** this installer will **wipe the selected disk**.

## Repository layout

```text
omakase-gentoo-install/
├── README.md
├── LICENSE
├── .gitignore
├── config.toml
├── settings.json
├── install.sh
├── chroot.sh
├── post-install.sh
└── lib.sh
```

## What this installer does

This project uses a 3-stage workflow:

1. **`install.sh`** (run in Gentoo live ISO as root)
   - Lists disks and prompts for target
   - Destroys partition table on target (after explicit confirmation)
   - Creates GPT layout:
     - `BOOT` size from `settings.json` key `boot_part_size` (default `1GiB`) (FAT32, `/boot`)
     - `ROOT` size from `settings.json` key `root_part_size` (default `40GiB`) (ext4, `/`)
     - `HOME` remaining (ext4, `/home`)
   - Mounts target filesystem tree at `/mnt/gentoo`
   - Downloads and extracts Gentoo Stage 3 (OpenRC by default)
   - Generates `fstab`, copies scripts/config, and runs `chroot.sh`

2. **`chroot.sh`** (called automatically inside chroot)
   - Applies hostname, locale, keymap, timezone
   - Syncs Portage tree
   - Installs packages from `config.toml` with `emerge`
   - Installs/configures GRUB for UEFI
   - Enables OpenRC services (NetworkManager, sshd)
   - Creates user, sets passwords, sudo/doas policy

3. **`post-install.sh`** (run manually as normal user after first boot)
   - Saves Gentoo world-set snapshot to `~/installed-packages.txt`
   - Prints quick restore and next-step guidance

## virt-manager test guide (recommended)

1. Download a **Gentoo live ISO**.
2. Create a new VM in virt-manager:
   - Firmware: **UEFI** (OVMF)
   - Disk: at least **80 GiB** (40 GiB root + home headroom)
   - RAM: 4 GiB+ recommended
   - CPU: 2+ vCPUs
3. Boot ISO and open a root shell.
4. Copy this repo into the live environment.
5. Run installer:
   ```bash
   chmod +x *.sh
   ./install.sh
   ```
6. Reboot into installed system.
7. Log in as your configured user and run:
   ```bash
   ~/post-install.sh
   ```

## Customization

- Edit **`settings.json`** for identity, locale, and partition values:
  - `boot_part_size` (default `1GiB`)
  - `root_part_size` (default `40GiB`)
  - `stage3_url` (optional; defaults to Gentoo OpenRC Stage 3)
- Edit **`config.toml`** to add/remove package atoms.
- Add packages at install time via:
  - `settings.json` → `additional_packages`

## Safety notes

- **UEFI only**. Legacy BIOS installs are not supported.
- **No encryption** and **no btrfs** by design (uses ext4 only).
- Installation is intended for clean-disk scenarios.
- Always verify the selected drive (`/dev/sdX`, `/dev/nvmeXn1`) before confirming wipe.

## License

MIT. See [LICENSE](LICENSE).
