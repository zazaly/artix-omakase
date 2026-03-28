# Omakase Gentoo Linux Install Script

A staged, beginner-friendly, **UEFI-only** Gentoo installer designed for testing in **virt-manager** and customization for real hardware.

## Preface

This repo is written for people who want a reproducible Gentoo install flow without memorizing every handbook step. It is still a destructive installer, so treat it as an automation aid rather than a “one-click” tool.

If you are preparing a real machine (for example: **Ryzen** + **Radeon RX**), do a quick Portage/bootstrap sanity pass from the live environment before running `install.sh`:

```bash
emerge --sync
emerge --ask --verbose --tree --jobs 8 --load-average 7 dev-vcs/git
```

Why this variant?
- `--verbose --tree` lets you inspect exactly what Portage plans to build.
- `--jobs 8 --load-average 7` is a safe, practical parallelism baseline for an 8-core CPU while keeping the system responsive.
- Installing `dev-vcs/git` early helps when you want to pull/track this installer or your own dotfiles during setup.

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

## Troubleshooting: dist-kernel post-install failures

If `sys-kernel/gentoo-kernel-bin` fails during `pkg_postinst` with a message like:

```text
Kernel install failed, please fix the problems and run emerge --config
```

the usual cause is that `/boot` is not mounted correctly inside chroot. The installer now validates `/boot` before running bootloader/kernel post-install steps, but you can also recover manually:

```bash
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run
chroot /mnt/gentoo /bin/bash
findmnt /boot
emerge --config sys-kernel/gentoo-kernel-bin
```

If your system uses `sys-kernel/gentoo-kernel` instead, run:

```bash
emerge --config sys-kernel/gentoo-kernel
```

## License

MIT. See [LICENSE](LICENSE).
