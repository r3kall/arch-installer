#!/bin/bash
# set -x

# https://wiki.archlinux.org/index.php/EFI_system_partition
# To provide adequate space for storing boot loaders and other files required
# for booting and to prevent interoperability issues with other operating
# systems the partition should be at least 260 MiB. For early and/or buggy UEFI
# implementations the size of at least 512 MiB might be needed.

parted -s /dev/sda mklabel gpt \
    mkpart "efi" fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart "swap" linux-swap 513MiB 4GiB \
    mkpart "root" ext4 4GiB 95%

# create filesystems
mkfs.fat -F32 /dev/sda1 -n "boot"
mkswap /dev/sda2 -L "swap"
mkfs.ext4 /dev/sda3 -L "root"

# mount partitions
mount /dev/sda3 /mnt
mkdir /mnt/boot && mount /dev/sda1 /mnt/boot
swapon /dev/sda2
