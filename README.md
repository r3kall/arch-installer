# arch-installer

A small Arch bootstrap followed by aconfmgr for system state and chezmoi for
home-directory configuration. Supports x86_64 UEFI, GRUB, and unencrypted ext4
or Btrfs. Desktop selection, drivers, packages, service policy, and tuning belong
in your configuration repositories.

## Install from the Arch ISO

Connect to the network and boot the ISO in UEFI mode. These commands modify the
live environment; the installer then **erases the disk you select**.

```bash
pacman -Syu --needed git
git clone https://github.com/r3kall/arch-installer
cd arch-installer
cp install.conf.example install.conf
nano install.conf
./arch-install.sh --config install.conf --disk /dev/nvme0n1 --fs btrfs
```

The disk must be unmounted with no active swap or mapped devices. Confirmation
requires typing the disk path. `--yes` explicitly skips that confirmation.
`--reserve 10` leaves ten percent unallocated. Defaults are ext4 and no reserved
space. Btrfs creates only `@` and `@home`; snapshot integration can be added to
your system configuration when needed.

For an existing partition layout, mount root at `/mnt` and a FAT32 ESP at
`/mnt/boot`, then use `./arch-install.sh --config install.conf --mounted`.
This skips formatting, installs the base, and regenerates fstab from the mounts.
Use only an empty target. Encryption, LVM, RAID, BIOS boot, and dual-boot setup
are outside this bootstrap's supported layouts.

The installer configures locale, timezone, keyboard, hostname, a wheel user,
passwords, NetworkManager, initramfs, and GRUB. Default credentials remain
`root:root` and `arch:admin`, as requested. Override `ROOT_PASSWORD` and
`USER_PASSWORD` in the configuration or environment; no password prompt is used.
Configuration files are sourced as trusted Bash; file assignments win over the
environment. `--config FILE` must be the first option.

Mounts remain available for inspection. When ready:

```bash
umount -R /mnt
reboot
```

## Restore after first login

Set `ACONFMGR_REPO` and `CHEZMOI_REPO` in `install.conf` before installation, or
edit the generated `~/arch-installer/restore.conf` after reboot. The handoff
contains restoration settings only, without passwords.

```bash
cd ~/arch-installer
./arch-post.sh --config restore.conf
```

Run as the normal user, without sudo. The script performs a full system upgrade,
installs build prerequisites, obtains aconfmgr if missing, applies system state
with interactive confirmations, initializes chezmoi, shows its diff, then applies
with prompts. Foreign packages use aconfmgr's `makepkg` backend as the normal
user; no separate AUR helper or skipped review is configured.

Existing aconfmgr directories and tool clones are reused without an automatic
pull. Update them deliberately before restoring. Chezmoi's existing source
repository is also reused by `init`; changing `CHEZMOI_REPO` does not switch an
existing checkout. For a different repository, select separate source/config
paths as shown below. Profile switching in one repository is the recommended
workflow here.

## Installation types

`INSTALL_PROFILE=workstation` supplies a common default. Override either selector
independently:

```bash
INSTALL_PROFILE=workstation
ACONFMGR_PROFILE=workstation
CHEZMOI_PROFILE=personal
```

Names may contain letters, numbers, underscores, and hyphens. These are selectors;
your configuration repositories define which names are valid and what they do.

### aconfmgr: conditional configuration

The restore script exports `ACONFMGR_PROFILE` to aconfmgr. A configuration might
contain:

```bash
case "${ACONFMGR_PROFILE:?Set ACONFMGR_PROFILE}" in
  minimal) ;;
  workstation) AddPackage niri;;
  *) echo 'Unknown system profile' >&2; exit 1;;
esac
```

These snippets are additions to a complete configuration, not complete package
manifests. For later direct `aconfmgr save` or `apply` calls, export the same
selector (or persist it in your shell environment through chezmoi):

```bash
export ACONFMGR_PROFILE=workstation
aconfmgr -c ~/.config/aconfmgr --paranoid apply
```

Alternatively, keep complete configurations in separate directories:

```bash
ACONFMGR_REPO=https://example.org/me/system-config.git
ACONFMGR_CONFIG_SUBDIR=configurations/workstation
```

The repo is cloned into `${XDG_CONFIG_HOME:-$HOME/.config}/aconfmgr` by default.
`ACONFMGR_DIR` overrides that clone root when invoking `arch-post.sh`; the selected
subdirectory is passed with `aconfmgr -c`. Each selected configuration must include
its shared baseline. No directory composition or profile guessing happens here.

**aconfmgr reconciles the whole declared system.** Include the seed packages:
`base`, `linux`, `linux-firmware`, `mkinitcpio`, `networkmanager`, `sudo`, `git`,
`chezmoi`, `grub`, `efibootmgr`, the applicable microcode, and `btrfs-progs` for
Btrfs. Account for restoration tools and `base-devel` too. Unlisted packages can
be removed during apply. Keep required optional dependencies explicit.

Account for machine-specific fstab, hostname, timezone, accounts, sudo access,
and NetworkManager enablement before the first apply. Use host-specific rules or
explicit `IgnorePath` rules for bootstrap-owned files, credentials, generated
boot artifacts, machine IDs, and locally generated network secrets. Do not copy
another machine's UUIDs or credentials into a new installation. Service
enablement belongs in aconfmgr's declared files/symlinks, with restarts handled
explicitly when needed.

### chezmoi: conditional dotfiles

Chezmoi supports machine differences through template data and ignore rules.
Add this to your dotfiles repository's `.chezmoi.toml.tmpl`, merging it with any
existing template:

```gotemplate
{{- $profile := promptString "profile" "default" -}}
[data]
    profile = {{ $profile | quote }}
```

The restore script supplies the `profile` prompt and verifies the persisted
value before applying. You can then use `.profile` in templates and
`.chezmoiignore`, for example:

```gotemplate
{{ if ne .profile "personal" }}
.config/niri/**
{{ end }}
```

The stored value also works with later plain `chezmoi apply` calls. Switching
profiles reruns initialization; ignoring a previously managed file does not
necessarily delete it. Define intentional cleanup in your dotfiles repository.
Avoid package-installation scripts there: aconfmgr owns the package set.

For independent dotfiles repositories, set `CHEZMOI_REPO`, `CHEZMOI_SOURCE`, and
`CHEZMOI_CONFIG` together. For example, in your restoration config:

```bash
CHEZMOI_REPO=https://example.org/me/work-dotfiles.git
CHEZMOI_SOURCE="$HOME/.local/share/chezmoi-work"
CHEZMOI_CONFIG="$HOME/.config/chezmoi/work.toml"
```

Use the same `--source` and `--config` options with later direct chezmoi commands.
These configurations still target your home directory: coordinate overlapping
files. When setting these paths in the ISO's install config, use explicit paths
for the installed user; `$HOME` there refers to the ISO user.

References: [Arch installation guide](https://wiki.archlinux.org/title/Installation_guide),
[aconfmgr](https://github.com/CyberShadow/aconfmgr),
[chezmoi init](https://www.chezmoi.io/reference/commands/init/),
[chezmoi machine differences](https://www.chezmoi.io/user-guide/manage-machine-to-machine-differences/).
