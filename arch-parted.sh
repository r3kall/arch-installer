#!/usr/bin/env bash
set -euo pipefail

# Arch disk partitioner
# - Creates GPT with an EFI System Partition and a single root partition (ext4)
# - Swap is expected to be a swapfile created later (recommended).
# - Interactive disk selection; safe for /dev/sdX, /dev/nvmeXnY, /dev/vdX.

DISK=""
ESP_LABEL="EFI"
ROOT_LABEL="root"

die(){ echo "ERROR: $*" >&2; exit 1; }

check_uefi() {
  if ! test -f /sys/firmware/efi/fw_platform_size; then
	  die "System does not support UEFI partitioning"
  fi
}

ask_disk() {
  echo "=== Available disks ==="
  lsblk -dno NAME,SIZE,MODEL | awk '{printf "  /dev/%s  %s  %s\n",$1,$2,$3}'
  echo
  read -rp "Select target disk (e.g., /dev/nvme0n1 or /dev/sda): " DISK
  [[ -b "$DISK" ]] || { echo "Invalid disk: $DISK"; exit 1; }
  echo
  read -rp "This will WIPE $DISK. Type 'YES' to continue: " confirm
  [[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }
}

partnum() {
  # Echo partition path for number $1 considering nvme 'p' suffix
  local n="$1"
  if [[ "$DISK" =~ [0-9]$ ]]; then
	  echo "${DISK}p${n}"
  else
	  echo "${DISK}${n}"
  fi
}

main() {
  check_uefi
  ask_disk

  echo "== Partitioning $DISK =="
  wipefs -a "$DISK"
  sgdisk --zap-all "$DISK"
  parted -s "$DISK" mklabel gpt \
	  mkpart "efi" fat32 1MiB 513MiB \
	  set 1 esp on \
	  mkpart "root" ext4 513MiB 100%

  ESP="$(partnum 1)"
  ROOT="$(partnum 2)"

  echo "== Creating filesystems =="
  mkfs.fat -F32 "$ESP" -n "$ESP_LABEL"
  mkfs.ext4 -F "$ROOT" -L "$ROOT_LABEL"

  echo "== Mounting =="
  mount "$ROOT" /mnt
  mkdir -p /mnt/boot
  mount "$ESP" /mnt/boot

  echo "Done. Partitions:"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
}

main "$@"
