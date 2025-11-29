#!/usr/bin/env bash
set -euo pipefail

# Arch disk partitioner + (optional) Btrfs layout
#
# Features:
# - GPT with EFI System Partition (1GiB) + single Linux partition
# - Keeps a fraction of disk unallocated (default 15%)
# - ext4 or Btrfs root (flag: --fs ext4|btrfs)
# - Btrfs layout:
#     @           -> /
#     @home       -> /home
#     @pkg        -> /var/cache/pacman/pkg        (no snapshots)
#     @log        -> /var/log                     (no snapshots)
#     @cache      -> /var/cache                   (no snapshots)
#     @tmp        -> /var/tmp                     (ephemeral)
#     @vm         -> /var/lib/vm                  (no-COW)
#     @containers -> /var/lib/containers          (no-COW)
#     @snapshots  -> /.snapshots
#
# Mount options (Btrfs):
#   - global:      noatime,space_cache=v2,discard=async
#   - root/home:   + compress=zstd:3,autodefrag,ssd
#   - pkg/log/cache/tmp: + ssd (no autodefrag, no compression)
#   - vm/containers: noatime,space_cache=v2,discard=async,ssd,nodatacow
#
# Swap is expected to be a swapfile created later.

SCRIPT_NAME="${0##*/}"

DISK=""
ESP_LABEL="EFI"
ROOT_LABEL="root"
FS_TYPE="btrfs"         # default filesystem
RESERVE_PERCENT=15      # % of disk left unallocated at the end

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME - Partition disk for Arch (ext4 or Btrfs)

Usage:
  sudo $SCRIPT_NAME [options]

Options:
  -d, --disk DEVICE        Target disk, e.g. /dev/nvme0n1, /dev/sda
  -f, --fs TYPE            Filesystem: ext4 or btrfs (default: btrfs)
  -r, --reserve PERCENT    Percent of disk to leave unallocated (default: 15)
  -y, --yes                Do not prompt for confirmation
  -h, --help               Show this help

Notes:
  - Creates 1GiB EFI System Partition.
  - No swap partition (use a swapfile later if desired).
  - For Btrfs, creates subvolume layout optimized for SSD and snapshots.
EOF
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run as root."
  fi
}

check_uefi() {
  if ! [[ -f /sys/firmware/efi/fw_platform_size ]]; then
    die "UEFI firmware not detected. This script assumes UEFI boot."
  fi
}

select_disk() {
  if [[ -n "$DISK" ]]; then
    [[ -b "$DISK" ]] || die "Disk $DISK does not exist."
    return
  fi

  echo "Available disks:"
  lsblk -d -o NAME,SIZE,TYPE,MODEL | awk '$3 == "disk"'
  echo
  read -rp "Enter target disk (e.g. /dev/nvme0n1 or /dev/sda): " DISK
  [[ -b "$DISK" ]] || die "Disk $DISK does not exist."
}

part_prefix() {
  # Handle /dev/sdX vs /dev/nvme0n1 vs /dev/vdX
  local d="$1"
  if [[ "$d" =~ nvme || "$d" =~ mmcblk ]]; then
    echo "${d}p"
  else
    echo "${d}"
  fi
}

confirm() {
  local auto_yes="$1"
  if [[ "$auto_yes" == "yes" ]]; then
    return
  fi

  echo "About to DESTROY all data on $DISK"
  echo "Filesystem: $FS_TYPE"
  echo "Reserved unallocated space: ${RESERVE_PERCENT}%"
  read -rp "Continue? [y/N]: " ans
  case "$ans" in
    y|Y) ;;
    *) die "Aborted by user." ;;
  esac
}

partition_disk() {
  local alloc_percent=$((100 - RESERVE_PERCENT))
  (( alloc_percent > 0 && alloc_percent < 100 )) \
    || die "Invalid reserve percent: $RESERVE_PERCENT"

  echo "== Creating GPT and partitions on $DISK =="
  # Wipe and create new GPT
  parted -s "$DISK" mklabel gpt

  # 1MiB alignment, 1GiB EFI
  parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
  parted -s "$DISK" set 1 esp on

  # Root from 1GiB to alloc_percent% of disk
  parted -s "$DISK" mkpart ROOT "${FS_TYPE}" 1025MiB "${alloc_percent}%"

  partpref="$(part_prefix "$DISK")"
  ESP="${partpref}1"
  ROOT="${partpref}2"
}

mkfs_ext4() {
  echo "== Creating filesystems (ext4) =="
  mkfs.fat -F32 "$ESP" -n "$ESP_LABEL"
  mkfs.ext4 -F "$ROOT" -L "$ROOT_LABEL"
}

mkfs_btrfs() {
  echo "== Creating filesystems (Btrfs) =="
  mkfs.fat -F32 "$ESP" -n "$ESP_LABEL"
  mkfs.btrfs -f -L "$ROOT_LABEL" "$ROOT"
}

setup_ext4_mounts() {
  echo "== Mounting ext4 root =="
  mount "$ROOT" /mnt
  mkdir -p /mnt/boot
  mount "$ESP" /mnt/boot
}

create_btrfs_subvolumes() {
  echo "== Creating Btrfs subvolumes =="
  # Mount the raw volume temporarily to create subvolumes
  mount "$ROOT" /mnt

  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@pkg
  btrfs subvolume create /mnt/@log
  btrfs subvolume create /mnt/@cache
  btrfs subvolume create /mnt/@tmp
  btrfs subvolume create /mnt/@vm
  btrfs subvolume create /mnt/@containers
  btrfs subvolume create /mnt/@snapshots

  umount /mnt
}

setup_btrfs_mounts() {
  echo "== Mounting Btrfs subvolumes =="

  local base_opts="noatime,space_cache=v2,discard=async"
  local ssd_opts="ssd"
  local comp_opts="compress=zstd:3"
  local adf_opts="autodefrag"

  # Root (@) with compression + autodefrag
  mount -o "subvol=@,$base_opts,$ssd_opts,$comp_opts,$adf_opts" "$ROOT" /mnt

  mkdir -p \
    /mnt/boot \
    /mnt/home \
    /mnt/var/cache/pacman/pkg \
    /mnt/var/log \
    /mnt/var/cache \
    /mnt/var/tmp \
    /mnt/var/lib/vm \
    /mnt/var/lib/containers \
    /mnt/.snapshots

  # Home: similar to root
  mount -o "subvol=@home,$base_opts,$ssd_opts,$comp_opts,$adf_opts" \
    "$ROOT" /mnt/home

  # pkg/log/cache/tmp: no compression, no autodefrag (lots of churn, big files)
  mount -o "subvol=@pkg,$base_opts,$ssd_opts" \
    "$ROOT" /mnt/var/cache/pacman/pkg
  mount -o "subvol=@log,$base_opts,$ssd_opts" \
    "$ROOT" /mnt/var/log
  mount -o "subvol=@cache,$base_opts,$ssd_opts" \
    "$ROOT" /mnt/var/cache
  mount -o "subvol=@tmp,$base_opts,$ssd_opts" \
    "$ROOT" /mnt/var/tmp

  # vm/containers: no-COW via nodatacow, and no compression
  mount -o "subvol=@vm,$base_opts,$ssd_opts,nodatacow" \
    "$ROOT" /mnt/var/lib/vm
  mount -o "subvol=@containers,$base_opts,$ssd_opts,nodatacow" \
    "$ROOT" /mnt/var/lib/containers

  # snapshots: compressed + autodefrag
  mount -o "subvol=@snapshots,$base_opts,$ssd_opts,$comp_opts,$adf_opts" \
    "$ROOT" /mnt/.snapshots

  # EFI
  mount "$ESP" /mnt/boot
}

print_summary() {
  echo
  echo "== Partition and mount summary =="
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DISK"

  echo
  echo "Remember to generate /etc/fstab after installing the base system, e.g.:"
  echo "  genfstab -U /mnt >> /mnt/etc/fstab"
  echo
  if [[ "$FS_TYPE" == "btrfs" ]]; then
    cat <<EOF
Recommended /etc/fstab Btrfs options (already used for initial mounts):

  root (@):      ${base_opts:-noatime,space_cache=v2,discard=async},ssd,compress=zstd:3,autodefrag
  /home (@home): same as root
  pkg/log/cache/tmp: noatime,space_cache=v2,discard=async,ssd
  vm/containers: noatime,space_cache=v2,discard=async,ssd,nodatacow

Note: nodatacow disables CoW and compression for these subvolumes,
which is ideal for VM images and container layers.
EOF
  fi
}

parse_args() {
  local auto_yes="no"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--disk)
        DISK="$2"; shift 2;;
      -f|--fs)
        FS_TYPE="$2"; shift 2;;
      -r|--reserve)
        RESERVE_PERCENT="$2"; shift 2;;
      -y|--yes)
        auto_yes="yes"; shift;;
      -h|--help)
        usage; exit 0;;
      *)
        die "Unknown argument: $1";;
    esac
  done

  case "$FS_TYPE" in
    ext4|btrfs) ;;
    *) die "Unsupported filesystem type: $FS_TYPE (use ext4 or btrfs)";;
  esac

  echo "$auto_yes"
}

main() {
  check_root
  check_uefi

  auto_yes="$(parse_args "$@")"

  select_disk
  confirm "$auto_yes"
  partition_disk

  if [[ "$FS_TYPE" == "ext4" ]]; then
    mkfs_ext4
    setup_ext4_mounts
  else
    mkfs_btrfs
    create_btrfs_subvolumes
    setup_btrfs_mounts
  fi

  print_summary
}

main "$@"
