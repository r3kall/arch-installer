#!/bin/bash
set -e
# Note: Arch Linux installation images do not support Secure Boot.
# You will need to disable Secure Boot to boot the installation medium.
# If desired, Secure Boot can be set up after completing the installation.


#### Variables
readonly USERNAME="arch"
readonly HOSTNAME="linux"

readonly ROOT_PASSWORD="root"
readonly USER_PASSWORD="admin"

readonly TIMEZONE="Europe/Rome"
readonly LOCALE="en_US.UTF-8 UTF-8"
readonly KEYMAP="it"

#### Commands
readonly pm="pacman -Sq --needed --noconfirm --color auto"
readonly ch="arch-chroot /mnt"


function die() { local _message="${*}"; echo "${_message}"; exit; }


function init () {
  if ping -c 1 -W 5 google.com &> /dev/null; then echo "Arch Installer" ; else die "Ping failed. Please check your connection."; fi
  
  # Update the system clock
  timedatectl set-ntp true
  sleep 5
  
  # Generates a log file with all commands and outputs during installation
  exec &> >(tee -a "/var/log/installation.log")  
  set -x
}

function partitioning () {
  read -p 'Continue with Disk Partitioning? [y/N]: ' fsok
  if ! [ $fsok = 'y' ] && ! [ $fsok = 'Y' ]; then
    die "Edit the script to continue. Exiting."
  else
    echo "Formatting partitions..."
    /bin/bash arch-parted.sh
  fi
}

function system_install () {
  echo "Starting system installation..."
  
  # Update mirrors
  # NOTE: '--sort rate' gives nb-errors, slow down entire installation process
  reflector --country Italy --country Germany --latest 25 --protocol https --save /etc/pacman.d/mirrorlist
  sleep 5
  
  # Install essential packages
  # NOTE: if virtual machine or container, 'linux-firmware' is not necessary
  sed -i 's/#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
  pacstrap /mnt base base-devel linux-lts linux-firmware
  
  sed -i 's/#Color/Color/' /mnt/etc/pacman.conf
  sed -i 's/#ParallelDownloads/ParallelDownloads/' /mnt/etc/pacman.conf   

  # Generate an fstab file
  genfstab -U /mnt >> /mnt/etc/fstab
  
  # Set root password
  ( echo "${ROOT_PASSWORD}"; echo "${ROOT_PASSWORD}" ) | $ch passwd
  sleep 1
  
  ## Timezone settings
  $ch ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
  echo ${TIMEZONE} > /mnt/etc/timezone
  $ch hwclock --systohc
  
  ## Locale settings
  # Uncomment needed locales with sed and generate them
  sed -i 's/^#'${LOCALE}'/'${LOCALE}'/' /mnt/etc/locale.gen && $ch locale-gen
  # Create the locale.conf file, and set the LANG variable accordingly
  echo "LANG=$(echo $LOCALE | awk '{print $1}')" > /mnt/etc/locale.conf
  # Make the changes on keyboard layout persistent in vconsole.conf
  # echo "KEYMAP=${KEYMAP}" > /mnt/etc/vconsole.conf  

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
  $ch pacman -Syyuq --noconfirm
  $ch $pm linux-tools pacman-contrib man-db man-pages texinfo bash-completion dialog nano neovim htop git parted

  # Install microcodes (if possible)
  grep GenuineIntel /proc/cpuinfo &>/dev/null && $ch $pm intel-ucode && echo "intel microcode installed.."
  grep AuthenticAMD /proc/cpuinfo &>/dev/null && $ch $pm amd-ucode && echo "amd microcode installed.."  

  # Install NetworkManager
  $ch $pm networkmanager
  $ch systemctl enable NetworkManager.service
  
  # Install bluetooth (if possible)
  $ch lsmod | grep blue &>/dev/null && $ch $pm bluez bluez-utils && $ch systemctl enable bluetooth.service
}

# Initramfs
function initramfs() {
  # echo 'HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt lvm2 resume filesystems)' >> /etc/mkinitcpio.conf
  mkinitcpio -P
}

# Boot loader
function bootloader() {
  $pm dosfstools efibootmgr freetype2 fuse2 mtools os-prober grub
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=arch
  grub-mkconfig -o /boot/grub/grub.cfg
}

# User configuration
function user_install() {
  echo "Starting user installation..."
  # Add a new user, create its home directory and add it to the indicated groups
  $ch useradd -mG wheel,uucp, input, optical, storage, network ${USERNAME}
  sleep 2
  # Uncomment wheel in sudoers
  sed -i 's/^#\s*\(%wheel\s\+ALL=(ALL)\s\+ALL\)/\1/' /mnt/etc/sudoers
  # Set user password
  ( echo "${USER_PASSWORD}"; echo "${USER_PASSWORD}" ) | $ch passwd ${USERNAME}
  sleep 1
  
  # Set XDG env variables
  echo "" >> /mnt/etc/profile
  echo "# XDG Base Directory specification" >> /mnt/etc/profile
  echo "# https://wiki.archlinux.org/index.php/XDG_Base_Directory"  >> /mnt/etc/profile
  echo "export XDG_CONFIG_HOME=\$HOME/.config" >> /mnt/etc/profile
  echo "export XDG_CACHE_HOME=\$HOME/.cache" >> /mnt/etc/profile
  echo "export XDG_DATA_HOME=\$HOME/.local/share" >> /mnt/etc/profile

  # Install xorg suite
  $ch $pm xorg xorg-xinit xterm
  sleep 3
  # Set x11 keyboard
  $ch localectl --no-convert set-x11-keymap ${KEYMAP} pc105
  
  # Install NVIDIA card drivers (if needed)
  $ch lspci -k | grep "VGA" | grep "NVIDIA" && $ch $pm nvidia-lts nvidia-utils xorg-server-devel opencl-nvidia
  
  # Install virtualbox addons (if needed)
  hostnamectl | grep Virtualization | grep oracle && $ch $pm virtualbox-guest-utils
  
  $ch $pm xdg-user-dirs xdg-utils
  nano /mnt/etc/xdg/user-dirs.defaults
  # $ch xdg-user-dirs-update  
}

function pkglist () {
  # expac -S -H M "%m: \t%n" $(sed -e '/^#/d' pkglist.txt) | sort -h

  # install from package list
  sed -e '/^#/d' ./pkglist.txt | $ch $pm -
  sleep 2
  
  if $ch pacman -Qs lightdm > /dev/null; then $ch systemctl enable lightdm.service; fi

  # Install AUR helper 'paru'
  # $ch git clone https://aur.archlinux.org/paru.git
  # $ch cd paru && makepkg -si
}

function main () {
  init
  partitioning
  system_install
}

main
# shutdown now
