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
die(){ echo "ERROR: $*" >&2; exit 1; }
ch()  { arch-chroot /mnt "$@"; }
pac() { arch-chroot /mnt pacman --noconfirm --needed -S "$@"; }
sl()  { sleep 2; }
is_virtualized() { systemd-detect-virt -q; }
virt_what() { systemd-detect-virt 2>/dev/null || true; }
gpu_vendor() { lspci -nnk | awk '/VGA|3D|Display/{print tolower($0)}'; }


init() {
  ping -c 1 -W 5 archlinux.org &>/dev/null || die "No network. Connect before running."
  timedatectl set-ntp true
  # Log everything
  exec &> >(tee -a "/var/log/install.log")
  # set -x
}

partitioning () {
  [[ -x ./arch-parted.sh ]] || die "arch-parted.sh missing."
  ./arch-parted.sh
  sl
}

system_install () {
  # Update mirrors
  # NOTE: '--sort rate' gives nb-errors, slow down entire installation process
  reflector -c Italy,Germany,France -l 16 -p https --save /etc/pacman.d/mirrorlist
  sleep 8

  # Install essential packages
  # NOTE: if virtual machine or container, 'linux-firmware' is not necessary
  pacstrap /mnt base base-devel linux linux-headers
  # !(hostnamectl | grep Virtualization) && pacstrap /mnt linux-firmware
  if ! is_virtualized; then pacstrap /mnt linux-firmware; fi

  sed -i 's/#Color/Color/' /mnt/etc/pacman.conf
  sed -i 's/#ParallelDownloads/ParallelDownloads/' /mnt/etc/pacman.conf

  # Generate an fstab file
  # genfstab -U /mnt >> /mnt/etc/fstab

  # Set root password
  ( echo "${ROOT_PASSWORD}"; echo "${ROOT_PASSWORD}" ) | ch passwd

  ## Timezone settings
  ch ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
  echo ${TIMEZONE} > /mnt/etc/timezone
  ch hwclock --systohc

  ## Locale settings
  # Uncomment needed locales with sed and generate them
  sed -i "s/^#$LOCALE/$LOCALE/" /mnt/etc/locale.gen
  # Create the locale.conf file, and set the LANG variable accordingly
  echo "LANG=$(echo $LOCALE | awk '{print $1}')" > /mnt/etc/locale.conf
  # Make the changes on keyboard layout persistent in vconsole.conf
  echo "KEYMAP=${KEYMAP}" > /mnt/etc/vconsole.conf
  ch locale-gen

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
  pac archlinux-keyring
  pac linux-tools pacman-contrib man-db man-pages texinfo dialog nano git parted reflector rsync

  # Install microcodes (if possible)
  !(hostnamectl | grep Virtualization) && grep GenuineIntel /proc/cpuinfo &>/dev/null && pac intel-ucode
  !(hostnamectl | grep Virtualization) && grep AuthenticAMD /proc/cpuinfo &>/dev/null && pac amd-ucode

  # Install NetworkManager
  pac networkmanager
  ch systemctl enable NetworkManager.service
  
  # GPU drivers
  if lspci | grep -E "VGA|3D|Display" | grep -qi nvidia; then
    pac nvidia nvidia-utils
  elif lspci | grep -E "VGA|3D|Display" | grep -qi intel; then
    pac mesa vulkan-intel intel-media-driver
  elif lspci | grep -E "VGA|3D|Display" | grep -qi amd; then
    pac mesa vulkan-radeon libva-mesa-driver
  else
    pac mesa
  fi

  sl
}

# Initramfs
initramfs() {
  local _hooks="HOOKS=(base udev keyboard keymap consolefont autodetect modconf block filesystems)"
  ch sed -i "s/^HOOKS.*/$_hooks/g" /etc/mkinitcpio.conf
  ch mkinitcpio -P
  sl
}

# Boot loader - GRUB
bootloader_grub() {
  pac dosfstools efibootmgr freetype2 fuse2 mtools os-prober grub btrfs-progs
  ch grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=arch
  ch grub-mkconfig -o /boot/grub/grub.cfg
  sl
}

# Boot loader - bootctl
bootloader_bootctl() {

  if ch bootctl is-installed > /dev/null
  then
    echo "systemd already installed"
    ch mkdir -p /boot/loader/entries
  else
    ch bootctl install
  fi

  printf "default arch.conf\ntimeout 4\n" > /mnt/boot/loader/loader.conf
  # Change ucode if needed
  printf "title   Arch Linux\nlinux   /vmlinuz-linux\ninitrd  /intel-ucode.img\ninitrd  /initramfs-linux.img\noptions root=\"LABEL=root\" rw\n" > /mnt/boot/loader/entries/arch.conf
  printf "title   Arch Linux\nlinux   /vmlinuz-linux\ninitrd  /intel-ucode.img\ninitrd  /initramfs-linux-fallback.img\noptions root=\"LABEL=root\" rw\n" > /mnt/boot/loader/entries/arch-fallback.conf
  ch bootctl status
  sl
}

# User configuration
user_install() {
  echo "Starting user installation."
  # Add a new user, create its home directory and add it to the indicated groups
  ch useradd -mG wheel,uucp,input,optical,storage,network ${USERNAME}

  # Add sudoer privileges
  # sed -i 's/^#\s*\(%wheel\s\+ALL=(ALL)\s\+ALL\)/\1/' /mnt/etc/sudoers
  echo "%wheel ALL=(ALL) ALL" > /mnt/etc/sudoers.d/10-wheel
  ch chmod 440 /etc/sudoers.d/10-wheel
  # Set user password
  ( echo "${USER_PASSWORD}"; echo "${USER_PASSWORD}" ) | ch passwd ${USERNAME}

  pac xdg-user-dirs xdg-utils
  printf "DESKTOP=Desktop\nDOWNLOAD=Downloads\nDOCUMENTS=Documents\nMUSIC=Music\nPICTURES=Pictures\nVIDEOS=Videos\n" > /mnt/etc/xdg/user-dirs.defaults
  ch xdg-user-dirs-update

  # Set XDG env variables
  echo "" >> /mnt/etc/profile
  echo "# XDG Base Directory specification" >> /mnt/etc/profile
  echo "# https://wiki.archlinux.org/index.php/XDG_Base_Directory"  >> /mnt/etc/profile
  echo "export XDG_CONFIG_HOME=\$HOME/.config" >> /mnt/etc/profile
  echo "export XDG_CACHE_HOME=\$HOME/.cache" >> /mnt/etc/profile
  echo "export XDG_DATA_HOME=\$HOME/.local/share" >> /mnt/etc/profile

  # Install virtualbox addons (if needed)
  # hostnamectl | grep Virtualization | grep oracle && $CH $PM virtualbox-guest-utils
  local VIRT_KIND="$(virt_what)"
  if is_virtualized; then
	pac qemu-guest-agent spice-vdagent
	ch systemctl enable qemu-guest-agent
	echo "[i] Virtualization detected (${VIRT_KIND:-unknown})"
  else
	echo "[i] Bare-metal or guest agent disabled (${VIRT_KIND:-unknown})"
  fi
  sl
}

main () {
  init
  partitioning
  system_install
  initramfs
  bootloader_grub
  user_install
  
  # System update
  ch pacman -Syyuq --noconfirm
}

time main
cp /var/log/install.log /mnt/var/log

umount -R /mnt/boot
umount -R /mnt
echo "Installation complete. You can now reboot."
