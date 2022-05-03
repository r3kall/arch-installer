#!/bin/bash
set -e

## Commands
AUR="paru -Sq --needed --noconfirm --color auto"
SL=3


function die() { local _message="${*}"; echo "${_message}"; exit 1; }


function init () {
  if ping -c 1 -W 5 google.com &> /dev/null; then
    echo "Arch Post-Install."
  else
    die "Arch Post-Install: no connection."
  fi
  
  exec &> >(sudo tee -a "/var/log/post.log")  
  set -x

  sleep $SL
}


function core() {
  sudo pacman -Syyuq --noconfirm

  sudo pacman -Sq --noconfirm --needed \
    gcc \
    python \
    rust \
    go

  # Install Docker
  sudo pacman -Sq --noconfirm docker
  sudo groupadd -f docker
  sudo usermod -aG docker $USER
  
  # Enable native overlay diff engine
  echo "options overlay metacopy=off redirect_dir=off" | sudo tee /etc/modprobe.d/disable-overlay-redirect-dir.conf
  sudo modprobe -r overlay
  sudo modprobe overlay
  sudo systemctl enable docker

}


function aur_helper() {
  local aur_helper="paru"
  local aur_home="/home/$USER/$aur_helper"
  [ ! -d $aur_home ] && git -C /home/$USER clone https://aur.archlinux.org/paru.git
  (cd $aur_home && makepkg -si --needed --noconfirm)
  sudo sed -i 's/#BottomUp/BottomUp/' /etc/paru.conf
  rm -Rf ${aur_home}
  sleep $SL
}


function terminal() {
  $AUR \
    alacritty \
    zsh \
    starship \
    zsh-completions \
    zsh-autosuggestions \
    zsh-syntax-highlighting \
    zsh-history-substring-search
  
  chsh -s /usr/bin/zsh
}


function fonts() {
  $AUR \
    ttf-dejavu \
    nerd-fonts-ubuntu-mono \
    nerd-fonts-hack
  
  fc-cache
}


function icons() {
  $AUR \
    hicolor-icon-theme
}


function xserver() {
  $AUR xorg xorg-xinit xterm
}


function dm() {
  # Install SDDM display manager 
  # Check sddm them at https://framagit.org/MarianArlt/sddm-sugar-candy
  $AUR sddm # qt5-graphicaleffects qt5-quickcontrols2 qt5-svg sddm-sugar-dark
  sudo systemctl enable sddm
}


function de() {
  $AUR \
    qtile \
    rofi \
    network-manager-applet \
    alsa-utils \
    dunst \
    lxsession-gtk3 \
    feh \
    volumeicon \
    lxappearance-gtk3
}


function dotfiles() {
  git clone --bare https://github.com/r3kall/dotfiles $HOME/.dotfiles
  local config="/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME"
  $config checkout
  $config config --local status.showUntrackedFiles no
}

function extra() {
  # Extras
  $AUR   \
    bat  \
    exa  \
    fd   \
    dust
  
  # Spacevim
  curl -sLf https://spacevim.org/install.sh | bash
  
  # Heavy Extras
  $AUR \
    google-chrome \
    spotify \
    vscodium-bin
}


function main() {
  init
  core
  aur_helper
  
  terminal
  fonts
  icons
  xserver
  dm
  de
  dotfiles
  extra
}

time main

sudo reboot

