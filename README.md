# Omakase Artix Linux Install Script

A staged, beginner-friendly, **UEFI-only** Artix Linux installer designed for testing in **virt-manager** and easy customization for real hardware.

> ⚠️ **Danger:** this installer will **wipe the selected disk**.

## Repository layout

```text
omakase-artix-install/
├── README.md
├── LICENSE
├── .gitignore
├── config.toml
├── settings.json.example
├── install.sh
├── chroot.sh
├── post-install.sh
└── lib.sh
```

## What this installer does

This project uses a 3-stage workflow:

1. **`install.sh`** (run in Artix live ISO as root)
   - Lists disks and prompts for target
   - Destroys partition table on target (after explicit confirmation)
   - Creates GPT layout:
     - `BOOT` size from `settings.json` key `boot_part_size` (default `1GiB`) (FAT32, `/boot`)
     - `ROOT` size from `settings.json` key `root_part_size` (default `40GiB`) (ext4, `/`)
     - `HOME` remaining (ext4, `/home`)
   - Mounts target filesystem tree
   - Installs base system with `basestrap`
   - Copies scripts/config into new system and runs `chroot.sh`

2. **`chroot.sh`** (called automatically inside chroot)
   - Applies hostname, locale, keymap, timezone
   - Initializes pacman keyring
   - Installs packages from `config.toml`
   - Installs and configures GRUB for UEFI
   - Enables OpenRC services (NetworkManager, lightdm, sshd)
   - Creates user, sets passwords, sudo policy

3. **`post-install.sh`** (run manually as normal user after first boot)
   - Saves explicit package list to `~/installed-packages.txt`
   - Prints quick restore and next-step guidance

## virt-manager test guide (recommended)

1. Download an **Artix OpenRC base ISO**.
2. Create a new VM in virt-manager:
   - Firmware: **UEFI** (OVMF)
   - Disk: at least **80 GiB** (40 GiB root + home headroom)
   - RAM: 4 GiB+ recommended
   - CPU: 2+ vCPUs
3. Boot ISO and open a root shell.
4. Copy this repo into the live environment (USB/shared folder/git clone).
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

- Edit **`settings.json`** for identity, locale, and partition size values:
  - `boot_part_size` (default `1GiB`)
  - `root_part_size` (default `40GiB`)
- Edit **`config.toml`** to add/remove package groups.
- Add packages at install time via:
  - `settings.json` → `additional_packages`
  - interactive prompt fallback if settings are missing

## Safety notes

- **UEFI only**. Legacy BIOS installs are not supported.
- **No encryption** and **no btrfs** by design (uses ext4 only).
- Installation is intended for clean-disk scenarios.
- Always verify the selected drive (`/dev/sdX`, `/dev/nvmeXn1`) before confirming wipe.

## Quick troubleshooting

- If `pacman-key` initialization is slow, wait (entropy in VMs can delay this).
- If package conflicts appear around X server components, keep replacement prompts at defaults (XLibre should replace Xorg where needed).
- If boot fails, re-open live ISO and verify EFI partition mount and GRUB files in `/boot/grub`.

## License

MIT. See [LICENSE](LICENSE).
