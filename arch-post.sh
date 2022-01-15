#!/bin/bash
set -e

#### Commands
aur="paru -Sq --needed --noconfirm --color auto"

function die() { local _message="${*}"; echo "${_message}"; exit; }


function init () {
  if ping -c 1 -W 5 google.com &> /dev/null; then
    echo "Arch Post-Install"
  else
    die "Ping failed, Install interrupted. Please check your connection."
  fi
  
  # Generates a log file with all commands and outputs during installation
  exec &> >(tee -a "/var/log/post.log")  
  set -x
  
  # Update system
  sudo pacman -Syyuq --noconfirm
}


function install_aur_helper() {
  git -C /home/$USER clone https://aur.archlinux.org/paru.git
  (cd /home/$USER/paru makepkg -si)
  # uncomment "bottomup" in /etc/paru.conf
}

function install_desktop_env() {
  # Install xorg suite
  $aur xorg xorg-xinit xterm
  
  # Install NVIDIA card drivers (if needed)
  lspci -k | grep "VGA" | grep "NVIDIA" && $aur nvidia-lts nvidia-utils xorg-server-devel opencl-nvidia
}


function install_shell() {
  $aur zsh zsh-completions zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search zsh-theme-powerlevel10k
  
  chsh -s /usr/bin/zsh
}

sed -e '/^#/d' pkglist.txt | paru -Sq --needed -

  
