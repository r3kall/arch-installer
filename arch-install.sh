#!/usr/bin/env bash
set -euo pipefail

# Note: Arch Linux installation images do not support Secure Boot.
# You will need to disable Secure Boot to boot the installation medium.
# If desired, Secure Boot can be set up after completing the installation.


# ===== User variables =====
USERNAME="${USERNAME:-arch}"
HOSTNAME="${HOSTNAME:-linux}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
USER_PASSWORD="${USER_PASSWORD:-admin}"
TIMEZONE="${TIMEZONE:-Europe/Rome}"
LOCALE="${LOCALE:-en_US.UTF-8 UTF-8}"
KEYMAP="${KEYMAP:-it}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-0}"  # set >0 to create a swapfile of that size

#### Commands
PM="pacman -S --needed --noconfirm"
CH="arch-chroot /mnt"
SL="sleep 2"

die(){ echo "ERROR: $*" >&2; exit 1; }

init() {
  ping -c 1 -W 5 archlinux.org &>/dev/null || die "No network. Connect before running."
  timedatectl set-ntp true
  # Log everything
  exec &> >(tee -a "/var/log/install.log")
  set -x
}

partitioning () {
  [[ -x ./arch-parted.sh ]] || die "arch-parted.sh missing."
  ./arch-parted.sh
  $SL
}

system_install () {
  echo "== System Installation =="

  # Update mirrors
  # NOTE: '--sort rate' gives nb-errors, slow down entire installation process
  reflector --country Italy,Germany,France -l 20 -p https --save /etc/pacman.d/mirrorlist
  sleep 10

  # Install essential packages
  # NOTE: if virtual machine or container, 'linux-firmware' is not necessary
  pacstrap /mnt base base-devel linux-lts linux-lts-headers
  !(hostnamectl | grep Virtualization) && pacstrap /mnt linux-firmware

  sed -i 's/#Color/Color/' /mnt/etc/pacman.conf
  sed -i 's/#ParallelDownloads/ParallelDownloads/' /mnt/etc/pacman.conf

  # Generate an fstab file
  genfstab -U /mnt >> /mnt/etc/fstab

  # Set root password
  ( echo "${ROOT_PASSWORD}"; echo "${ROOT_PASSWORD}" ) | $CH passwd

  ## Timezone settings
  $CH ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
  echo ${TIMEZONE} > /mnt/etc/timezone
  $CH hwclock --systohc

  ## Locale settings
  # Uncomment needed locales with sed and generate them
  sed -i "s/^#$LOCALE/$LOCALE/" /mnt/etc/locale.gen
  # Create the locale.conf file, and set the LANG variable accordingly
  echo "LANG=$(echo $LOCALE | awk '{print $1}')" > /mnt/etc/locale.conf
  # Make the changes on keyboard layout persistent in vconsole.conf
  echo "KEYMAP=${KEYMAP}" > /mnt/etc/vconsole.conf
  $CH locale-gen

  # Create the hostname file
  echo $HOSTNAME > /mnt/etc/hostname
  # Add matching entries to hosts
  echo "# The following lines are desirable for IPv4 capable hosts" >> /mnt/etc/hosts
  echo "127.0.0.1         localhost" >> /mnt/etc/hosts
  echo "# The following lines are desirable for IPv6 capable hosts" >> /mnt/etc/hosts
  echo "::1               localhost ip6-localhost ip6-loopback" >> /mnt/etc/hosts
  echo "ff02::1           ip6-allnodes" >> /mnt/etc/hosts
  echo "ff02::2           ip6-allrouters" >> /mnt/etc/hosts

  ## Install tools
  $CH $PM archlinux-keyring
  $CH $PM linux-tools pacman-contrib man-db man-pages texinfo dialog nano git parted reflector rsync

  # Install microcodes (if possible)
  !(hostnamectl | grep Virtualization) && grep GenuineIntel /proc/cpuinfo &>/dev/null && $CH $PM intel-ucode
  !(hostnamectl | grep Virtualization) && grep AuthenticAMD /proc/cpuinfo &>/dev/null && $CH $PM amd-ucode

  # Install NetworkManager
  $CH $PM networkmanager
  $CH systemctl enable NetworkManager.service
  
  # GPU drivers
  if lspci | grep -E "VGA|3D|Display" | grep -qi nvidia; then
    $CH $PM nvidia-lts nvidia-utils
  elif lspci | grep -E "VGA|3D|Display" | grep -qi intel; then
    $CH $PM mesa vulkan-intel intel-media-driver
  elif lspci | grep -E "VGA|3D|Display" | grep -qi amd; then
    $CH $PM mesa vulkan-radeon libva-mesa-driver
  else
    $CH $PM mesa
  fi

  # Optional Swapfile
  if [[ "$SWAP_SIZE_GB" != "0" ]]; then
    $CH fallocate -l "${SWAP_SIZE_GB}G" /swapfile
    $CH chmod 600 /swapfile
    $CH mkswap /swapfile
    $CH swapon /swapfile
    echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
  fi

  $SL
}

# Initramfs
initramfs() {
  local _hooks="HOOKS=(base udev keyboard keymap consolefont autodetect modconf block filesystems)"
  $CH sed -i "s/^HOOKS.*/$_hooks/g" /etc/mkinitcpio.conf
  $CH mkinitcpio -P
  $SL
}

# Boot loader - GRUB
bootloader_grub() {
  $CH $PM dosfstools efibootmgr freetype2 fuse2 mtools os-prober grub
  $CH grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=arch
  $CH grub-mkconfig -o /boot/grub/grub.cfg
  $SL
}

# Boot loader - bootctl
bootloader_bootctl() {

  if $CH bootctl is-installed > /dev/null
  then
    echo "systemd already installed"
    $CH mkdir -p /boot/loader/entries
  else
    $CH bootctl install
  fi

  printf "default arch.conf\ntimeout 4\n" > /mnt/boot/loader/loader.conf
  # Change ucode if needed
  printf "title   Arch Linux\nlinux   /vmlinuz-linux-lts\ninitrd  /intel-ucode.img\ninitrd  /initramfs-linux-lts.img\noptions root=\"LABEL=root\" rw\n" > /mnt/boot/loader/entries/arch.conf
  printf "title   Arch Linux\nlinux   /vmlinuz-linux-lts\ninitrd  /intel-ucode.img\ninitrd  /initramfs-linux-lts-fallback.img\noptions root=\"LABEL=root\" rw\n" > /mnt/boot/loader/entries/arch-fallback.conf
  $CH bootctl status
  $SL
}

# User configuration
user_install() {
  echo "Starting user installation."
  # Add a new user, create its home directory and add it to the indicated groups
  $CH useradd -mG wheel,uucp,input,optical,storage,network ${USERNAME}

  # Add sudoer privileges
  # sed -i 's/^#\s*\(%wheel\s\+ALL=(ALL)\s\+ALL\)/\1/' /mnt/etc/sudoers
  echo "%wheel ALL=(ALL) ALL" > /mnt/etc/sudoers.d/wheel
  # Set user password
  ( echo "${USER_PASSWORD}"; echo "${USER_PASSWORD}" ) | $CH passwd ${USERNAME}

  $CH $PM xdg-user-dirs xdg-utils
  printf "DESKTOP=Desktop\nDOWNLOAD=Downloads\nDOCUMENTS=Documents\nMUSIC=Music\nPICTURES=Pictures\nVIDEOS=Videos\n" > /mnt/etc/xdg/user-dirs.defaults
  $CH xdg-user-dirs-update

  # Set XDG env variables
  echo "" >> /mnt/etc/profile
  echo "# XDG Base Directory specification" >> /mnt/etc/profile
  echo "# https://wiki.archlinux.org/index.php/XDG_Base_Directory"  >> /mnt/etc/profile
  echo "export XDG_CONFIG_HOME=\$HOME/.config" >> /mnt/etc/profile
  echo "export XDG_CACHE_HOME=\$HOME/.cache" >> /mnt/etc/profile
  echo "export XDG_DATA_HOME=\$HOME/.local/share" >> /mnt/etc/profile

  # Install virtualbox addons (if needed)
  # hostnamectl | grep Virtualization | grep oracle && $CH $PM virtualbox-guest-utils
  $SL
}

main () {
  init
  partitioning
  system_install
  initramfs
  bootloader_grub
  user_install
  
  # System update
  $CH pacman -Syyuq --noconfirm
}

time main
cp /var/log/install.log /mnt/var/log

umount -R /mnt/boot
umount -R /mnt
echo "Installation complete. You can now reboot."
