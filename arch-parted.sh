#!/usr/bin/env bash
set -euo pipefail

DISK=""
FS_TYPE=ext4
RESERVE_PERCENT=0
AUTO_YES=no
TARGET=/mnt

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<HELP
Usage: ${0##*/} --disk DEVICE [options]
Erase one disk, create GPT with a 1 GiB ESP, and mount it for installation.
  -d, --disk DEVICE       Required whole disk (all data will be erased)
  -f, --fs TYPE           ext4 (default) or btrfs (@ and @home)
  -r, --reserve PERCENT   Leave 0..90 percent unallocated (default: 0)
      --target PATH      Mount directory (default: /mnt)
  -y, --yes               Skip the erase confirmation
  -h, --help              Show this help
HELP
}

parse_args() {
  while (($#)); do
    case "$1" in
      -d|--disk|-f|--fs|-r|--reserve|--target)
        (($# >= 2)) && [[ -n $2 && $2 != -* ]] || die "Missing value for $1"
        case "$1" in
          -d|--disk) DISK=$2;;
          -f|--fs) FS_TYPE=$2;;
          -r|--reserve) RESERVE_PERCENT=$2;;
          --target) TARGET=$2;;
        esac
        shift 2;;
      -y|--yes) AUTO_YES=yes; shift;;
      -h|--help) usage; exit 0;;
      *) die "Unknown argument: $1";;
    esac
  done
  [[ -n $DISK ]] || die "--disk is required"
  [[ $FS_TYPE == ext4 || $FS_TYPE == btrfs ]] || die "Use ext4 or btrfs"
  [[ $RESERVE_PERCENT =~ ^[0-9]{1,2}$ ]] || die "Reserve must be an integer from 0 to 90"
  RESERVE_PERCENT=$((10#$RESERVE_PERCENT))
  ((RESERVE_PERCENT <= 90)) || die "Reserve must be from 0 to 90"
  [[ $TARGET == /* && $TARGET != / ]] || die "Target must be an absolute directory other than /"
}

check_disk() {
  [[ $EUID == 0 ]] || die "Run as root"
  [[ -d /sys/firmware/efi ]] || die "Boot the installation medium in UEFI mode"
  DISK=$(readlink -f -- "$DISK")
  [[ -b $DISK && $(lsblk -dnro TYPE "$DISK") == disk ]] || die "Not a whole disk: $DISK"
  [[ -z $(lsblk -nrpo MOUNTPOINTS "$DISK" | tr -d '[:space:]') ]] || die "Disk has mounted filesystems or active swap"
  [[ -z $(lsblk -nrpo TYPE "$DISK" | sed '1d' | sed '/^part$/d') ]] || die "Disk has active device-mapper/RAID users"
  ! mountpoint -q "$TARGET" || die "Target is already mounted: $TARGET"
  [[ ! -d $TARGET || -z $(ls -A -- "$TARGET") ]] || die "Target directory is not empty"
  local bytes command
  bytes=$(lsblk -bdnro SIZE "$DISK")
  ((bytes * (100 - RESERVE_PERCENT) / 100 > 5 * 1024 * 1024 * 1024)) || die "Allocated space must exceed 5 GiB"
  for command in wipefs parted partprobe udevadm mkfs.fat mount umount; do
    command -v "$command" >/dev/null || die "Missing command: $command"
  done
  command -v "mkfs.$FS_TYPE" >/dev/null || die "Missing mkfs.$FS_TYPE"
  if [[ $FS_TYPE == btrfs ]]; then command -v btrfs >/dev/null || die "Missing btrfs"; fi
}

confirm() {
  lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS "$DISK"
  echo "DESTROY all data on $DISK; filesystem=$FS_TYPE; reserve=$RESERVE_PERCENT%"
  if [[ $AUTO_YES != yes ]]; then
    local answer
    read -r -p "Type $DISK to erase it: " answer
    [[ $answer == "$DISK" ]] || die "Aborted"
  fi
}

partition_disk() {
  wipefs -a "$DISK"
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
  parted -s "$DISK" set 1 esp on
  # mkfs chooses the actual filesystem; ext4 is only parted's type hint.
  parted -s "$DISK" mkpart ROOT ext4 1025MiB "$((100 - RESERVE_PERCENT))%"
  partprobe "$DISK"
  udevadm settle
  local esp root
  esp=$(lsblk -nrpo NAME,PARTN "$DISK" | awk '$2 == 1 {print $1}')
  root=$(lsblk -nrpo NAME,PARTN "$DISK" | awk '$2 == 2 {print $1}')
  [[ -b $esp && -b $root ]] || die "Partition devices did not appear"
  mkfs.fat -F32 -n EFI "$esp"
  mkdir -p "$TARGET"
  if [[ $FS_TYPE == ext4 ]]; then
    mkfs.ext4 -F -L root "$root"
    mount "$root" "$TARGET"
  else
    mkfs.btrfs -f -L root "$root"
    mount "$root" "$TARGET"
    btrfs subvolume create "$TARGET/@"
    btrfs subvolume create "$TARGET/@home"
    umount "$TARGET"
    mount -o subvol=@,noatime,compress=zstd:3 "$root" "$TARGET"
    mkdir -p "$TARGET/home"
    mount -o subvol=@home,noatime,compress=zstd:3 "$root" "$TARGET/home"
  fi
  mkdir -p "$TARGET/boot"
  mount -o umask=0077 "$esp" "$TARGET/boot"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DISK"
  echo "Mounted at $TARGET. The installer generates fstab after pacstrap."
}

main() {
  # Parse in this shell so variables survive.
  parse_args "$@"
  check_disk
  confirm
  partition_disk
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
