#!/usr/bin/env bash
set -euo pipefail
# Never trace password input, including when invoked with bash -x.
set +x
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

die() {
  echo "ERROR: $*" >&2
  exit 1
}
ch() { arch-chroot "$TARGET" "$@"; }
usage() {
  cat <<HELP
Usage: ${0##*/} [--config FILE] --disk DEVICE [--fs ext4|btrfs] [--reserve N] [--yes]
       ${0##*/} [--config FILE] --mounted
Install a console-ready UEFI/GRUB system. --mounted uses existing mounts.
Configuration is trusted Bash; see install.conf.example. --config must come first.
HELP
}

install_system() {
  local fs=$1
  local -a packages=(base linux linux-firmware mkinitcpio networkmanager sudo git chezmoi grub efibootmgr)
  [[ $fs != btrfs ]] || packages+=(btrfs-progs)
  if grep -q GenuineIntel /proc/cpuinfo; then
    packages+=(intel-ucode)
  elif grep -q AuthenticAMD /proc/cpuinfo; then packages+=(amd-ucode); fi
  pacstrap -K "$TARGET" "${packages[@]}"
  genfstab -U "$TARGET" >"$TARGET/etc/fstab"
  ch ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  ch hwclock --systohc
  grep -Fxq "#${LOCALE}" "$TARGET/etc/locale.gen" || grep -Fxq "$LOCALE" "$TARGET/etc/locale.gen" || die "Locale not available: $LOCALE"
  # Exact matching avoids interpreting locale punctuation as regex syntax.
  awk -v locale="$LOCALE" '$0 == "#" locale {$0=locale} {print}' "$TARGET/etc/locale.gen" >"$TARGET/etc/locale.gen.new"
  mv "$TARGET/etc/locale.gen.new" "$TARGET/etc/locale.gen"
  printf 'LANG=%s\n' "${LOCALE%% *}" >"$TARGET/etc/locale.conf"
  printf 'KEYMAP=%s\n' "$KEYMAP" >"$TARGET/etc/vconsole.conf"
  printf '%s\n' "$HOST_NAME" >"$TARGET/etc/hostname"
  ch locale-gen
  ch useradd -m -G wheel -s /bin/bash "$USER_NAME"
  printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$TARGET/etc/sudoers.d/10-wheel"
  chmod 440 "$TARGET/etc/sudoers.d/10-wheel"
  ch visudo -cf /etc/sudoers
  printf 'root:%s\n%s:%s\n' "$ROOT_PASSWORD" "$USER_NAME" "$USER_PASSWORD" | ch chpasswd
  ch systemctl enable NetworkManager.service
  # Keep the package's default mkinitcpio hooks.
  ch mkinitcpio -P
  ch grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=arch
  ch grub-mkconfig -o /boot/grub/grub.cfg
  local handoff="$TARGET/home/$USER_NAME/arch-installer"
  mkdir -p "$handoff"
  install -m 755 "$SCRIPT_DIR/arch-post.sh" "$handoff/arch-post.sh"
  # Copy restoration settings only, never passwords or the input file.
  local variable
  : >"$handoff/restore.conf"
  for variable in INSTALL_PROFILE ACONFMGR_PROFILE CHEZMOI_PROFILE ACONFMGR_REPO ACONFMGR_CONFIG_SUBDIR CHEZMOI_REPO CHEZMOI_SOURCE CHEZMOI_CONFIG; do
    if [[ -v $variable ]]; then printf '%s=%q\n' "$variable" "${!variable}" >>"$handoff/restore.conf"; fi
  done
  ch chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/arch-installer"
  echo "Installation complete. Mounts remain available for inspection."
  echo "Unmount with: umount -R $TARGET; then reboot."
  echo "After login: cd ~/arch-installer && ./arch-post.sh --config restore.conf"
}

main() {
  if [[ ${1:-} == --config ]]; then
    (($# >= 2)) && [[ -f $2 ]] || die "--config requires a readable file"
    # shellcheck disable=SC1090
    source "$2"
    shift 2
  fi
  if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    return
  fi
  USER_NAME=${USER_NAME:-arch}
  HOST_NAME=${HOST_NAME:-linux}
  ROOT_PASSWORD=${ROOT_PASSWORD:-root}
  USER_PASSWORD=${USER_PASSWORD:-admin}
  TIMEZONE=${TIMEZONE:-Europe/Rome}
  LOCALE=${LOCALE:-en_US.UTF-8 UTF-8}
  KEYMAP=${KEYMAP:-it}
  TARGET=${TARGET:-/mnt}
  INSTALL_PROFILE=${INSTALL_PROFILE:-default}
  ACONFMGR_PROFILE=${ACONFMGR_PROFILE:-$INSTALL_PROFILE}
  CHEZMOI_PROFILE=${CHEZMOI_PROFILE:-$INSTALL_PROFILE}
  [[ $ACONFMGR_PROFILE =~ ^[a-zA-Z0-9_-]+$ && $CHEZMOI_PROFILE =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid profile name"
  local mounted=no
  if [[ ${1:-} == --mounted ]]; then
    mounted=yes
    shift
    (($# == 0)) || die "--mounted takes no partition options"
  fi
  [[ $EUID == 0 ]] || die "Run as root from the Arch ISO"
  [[ -d /run/archiso && -d /sys/firmware/efi ]] || die "Use an Arch ISO booted in UEFI mode"
  [[ $USER_NAME =~ ^[a-z_][a-z0-9_-]*$ && $USER_NAME != root ]] || die "Invalid user name"
  [[ $HOST_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "Invalid host name"
  [[ $TARGET == /* && $TARGET != / ]] || die "Invalid target directory"
  [[ $TIMEZONE != /* && $TIMEZONE != *..* && -f /usr/share/zoneinfo/$TIMEZONE ]] || die "Invalid timezone"
  [[ $LOCALE =~ ^[a-zA-Z0-9_.@-]+\ UTF-8$ ]] || die "Use a UTF-8 locale, e.g. en_US.UTF-8 UTF-8"
  [[ $KEYMAP =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid keymap"
  [[ $ROOT_PASSWORD != *$'\n'* && $USER_PASSWORD != *$'\n'* ]] || die "Passwords cannot contain newlines"
  local command
  for command in pacstrap genfstab arch-chroot findmnt timedatectl curl; do
    command -v "$command" >/dev/null || die "Missing command: $command"
  done
  curl -fsS --connect-timeout 10 --max-time 30 https://archlinux.org/ -o /dev/null
  timedatectl set-ntp true
  if [[ $mounted == no ]]; then
    "$SCRIPT_DIR/arch-parted.sh" "$@" --target "$TARGET"
  fi
  mountpoint -q "$TARGET" && mountpoint -q "$TARGET/boot" || die "Mount root at $TARGET and ESP at $TARGET/boot"
  [[ $(findmnt -nro FSTYPE -M "$TARGET/boot") == vfat ]] || die "ESP must be FAT32"
  local fs
  fs=$(findmnt -nro FSTYPE -M "$TARGET")
  [[ $fs == ext4 || $fs == btrfs ]] || die "Only ext4 and Btrfs root filesystems are supported"
  [[ ! -e $TARGET/etc/os-release ]] || die "Target already contains an OS; refusing to overwrite it"
  install_system "$fs"

}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
