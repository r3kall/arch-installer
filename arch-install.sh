#!/bin/bash
set -e
# Note: Arch Linux installation images do not support Secure Boot.
# You will need to disable Secure Boot to boot the installation medium.
# If desired, Secure Boot can be set up after completing the installation.


#### Variables
USERNAME="arch"
HOSTNAME="linux"

ROOT_PASSWORD="root"
USER_PASSWORD="admin"

TIMEZONE="Europe/Rome"
LOCALE="en_US.UTF-8 UTF-8"
KEYMAP="it"

#### Commands
PM="pacman -Sq --needed --noconfirm"
CH="arch-chroot /mnt"


function die() { local _message="${*}"; echo "${_message}"; exit; }


function init () {
  if ping -c 1 -W 5 google.com &> /dev/null; then
    echo "Arch Installer starting."
  else
    die "Arch Installer stopping: no connection."
  fi
  
  # Update the system clock
  timedatectl set-ntp true
  sleep 5
  
  # Generates a log file with all commands and outputs during installation
  exec &> >(tee -a "/var/log/install.log")  
  set -x
}

function partitioning () {
  read -p 'Continue with Disk Partitioning? [y/N]: ' fsok
  if ! [ $fsok = 'y' ] && ! [ $fsok = 'Y' ]; then
    die "Edit the script to continue. Exiting."
  else
    if [[ $(ls /sys/firmware/efi/efivars) ]]; then
      echo "Formatting partitions with parted."
      /bin/bash arch-parted.sh
    else
      die "Not EFI system. Exiting."
    fi
  fi
}

function system_install () {
  echo "Starting system installation."
  
  # Update mirrors
  # NOTE: '--sort rate' gives nb-errors, slow down entire installation process
  reflector -c Italy, Germany, France -l 10 -p https --save /etc/pacman.d/mirrorlist
  sleep 5
  
  # Install essential packages
  # NOTE: if virtual machine or container, 'linux-firmware' is not necessary
  pacstrap /mnt base base-devel linux-lts
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
  
  ## System upgrade
  $CH $PM archlinux-keyring
  $CH pacman -Syyuq --noconfirm
  $CH $PM linux-tools pacman-contrib man-db man-pages texinfo bash-completion dialog nano neovim htop git parted reflector

  # Install microcodes (if possible)
  !(hostnamectl | grep Virtualization) && grep GenuineIntel /proc/cpuinfo &>/dev/null && $CH $PM intel-ucode
  !(hostnamectl | grep Virtualization) && grep AuthenticAMD /proc/cpuinfo &>/dev/null && $CH $PM amd-ucode

  # Install NetworkManager
  $CH $PM networkmanager
  $CH systemctl enable NetworkManager.service
  
  # Install bluetooth (if possible)
  # NOTE: lsmod give errors ... post-installation
  # $ch lsmod | grep blue &>/dev/null && $ch $pm bluez bluez-utils && $ch systemctl enable bluetooth.service
}

# Initramfs
function initramfs() {  
  local _hooks="HOOKS=(base udev keyboard keymap consolefont autodetect modconf block filesystems)"
  $CH sed -i "s/^HOOKS.*/$_hooks/g" /etc/mkinitcpio.conf
  $CH mkinitcpio -P
}

# Boot loader - GRUB
function bootloader_grub() {
  $CH $PM dosfstools efibootmgr freetype2 fuse2 mtools os-prober grub
  $CH grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=arch
  $CH grub-mkconfig -o /boot/grub/grub.cfg  
}

# Boot loader - bootctl
function bootloader_bootctl() {

  if $CH bootctl is-installed > /dev/null
  then 
    echo "systemd already installed"
    $CH mkdir -p /boot/loader/entries
  else 
    $CH bootctl install
  fi
  
  printf "default arch.conf\ntimeout 4\n" > /mnt/boot/loader/loader.conf
  printf "title   Arch Linux\nlinux   /vmlinuz-linux-lts\ninitrd  /intel-ucode.img\ninitrd  /initramfs-linux-lts.img\noptions root=\"LABEL=root\" rw\n" > /mnt/boot/loader/entries/arch.conf
  printf "title   Arch Linux\nlinux   /vmlinuz-linux-lts\ninitrd  /intel-ucode.img\ninitrd  /initramfs-linux-lts-fallback.img\noptions root=\"LABEL=root\" rw\n" > /mnt/boot/loader/entries/arch-fallback.conf
  $CH bootctl status
}

# User configuration
function user_install() {
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
  hostnamectl | grep Virtualization | grep oracle && $CH $PM virtualbox-guest-utils
}


function main () {
  init
  partitioning
  system_install
  initramfs
  bootloader_grub
  user_install  
}

time main
cp /var/log/install.log /mnt/var/log
 
umount -R /mnt/boot
umount -R /mnt
sleep 5
reboot
