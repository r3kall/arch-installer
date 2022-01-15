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
  
  exec &> >(sudo tee -a "/var/log/post.log")  
  set -x
  
  sudo pacman -Syyuq --noconfirm
}


function install_aur_helper() {
  local aur_helper="paru"
  local aur_home="/home/$USER/$aur_helper"
  [ ! -d $aur_home ] && git -C /home/$USER clone https://aur.archlinux.org/paru.git
  (cd $aur_home && makepkg -si  --needed --noconfirm && makepkg -c)
  # uncomment "bottomup" in /etc/paru.conf
  sudo sed -i 's/#BottomUp/BottomUp/' /etc/paru.conf
  sleep 3
}

function install_desktop_env() {
  # Install xorg suite
  $aur xorg xorg-xinit xterm
  sleep 3
  
  # Install NVIDIA card drivers (if needed)
  lspci -k | grep "VGA" | grep "NVIDIA" && $aur nvidia-lts nvidia-utils
  sleep 3
  
  $aur ttf-dejavu nerd-fonts-noto nerd-fonts-complete-starship
  fc-cache
  
  # Install SDDM display manager 
  # Check sddm them at https://framagit.org/MarianArlt/sddm-sugar-candy
  $aur sddm # qt5-graphicaleffects qt5-quickcontrols2 qt5-svg
  
  # Install Qtile window manager
  $aur qtile alacritty network-manager-applet alsa-utils dunst lxsession-gtk3 feh volumeicon rofi
}


function install_pkg() {  
  sed -e '/^#/d' pkglist.txt | $aur -
  sleep 5
}


function install_shell() {
  $aur zsh starship zsh-completions zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search #zsh-theme-powerlevel10k  
  chsh -s /usr/bin/zsh
}


function dotfiles() {
  git clone --bare https://github.com/r3kall/dotfiles $HOME/.dotfiles
  local config="/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME"
  $config checkout
  $config config --local status.showUntrackedFiles no
}


function main() {
  init
  install_aur_helper
  install_desktop_env
  # install_pkg
  install_shell
  dotfiles
}

time main

sudo reboot



  
