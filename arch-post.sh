#!/bin/bash
set -e

####
DE="gnome"
####

## Commands
AUR="paru -Sq --needed --noconfirm --color auto"
SL="sleep 2"


function die() { local _message="${*}"; echo "${_message}"; exit 1; }


function init () {
  if ping -c 1 -W 5 google.com &> /dev/null; then
    echo "Arch Post-Install."
  else
    die "Arch Post-Install: no connection."
  fi

  exec &> >(sudo tee -a "/var/log/post.log")
  set -x

  $SL
}


function core() {
  sudo pacman -Syyuq --noconfirm

  sudo pacman -Sq --noconfirm --needed \
    gcc     \
    python  \
    rustup  \
    go      \
    flatpak \

  rustup default stable

  # Install Docker
  sudo pacman -Sq --noconfirm docker
  sudo groupadd -f docker
  sudo usermod -aG docker $USER

  # Enable native overlay diff engine
  echo "options overlay metacopy=off redirect_dir=off" | sudo tee /etc/modprobe.d/disable-overlay-redirect-dir.conf
  sudo modprobe -r overlay
  sudo modprobe overlay
  sudo systemctl enable docker
  $SL
}


function aur_helper() {
  local aur_helper="paru"
  local aur_home="/home/$USER/$aur_helper"
  if ! hash $aur_helper; then
    [ ! -d $aur_home ] && git -C /home/$USER clone https://aur.archlinux.org/paru.git
    (cd $aur_home && makepkg -si --needed --noconfirm)
    sudo sed -i 's/#BottomUp/BottomUp/' /etc/paru.conf
    rm -Rf ${aur_home}
  fi
  $SL
}


function terminal() {
  $AUR        \
    alacritty \
    vivid     \
    zsh       \
    starship  \
    zsh-completions \
    zsh-autosuggestions \
    zsh-syntax-highlighting \
    zsh-history-substring-search

  sudo chsh -s /bin/zsh
  $SL
}


function fonts() {
  $AUR \
    ttf-dejavu \
    ttf-ubuntu-mono-nerd \
    ttf-hack-nerd

  fc-cache
  $SL
}


function icons() {
  $AUR \
    hicolor-icon-theme
  $SL
}


function xserver() {
  $AUR xorg xorg-xinit xterm
  $SL
}

function common() {
  core
  aur_helper
  terminal
  fonts
  icons
  xserver
  $SL
}


function install_sddm() {
  # Install SDDM display manager
  # Check sddm them at https://framagit.org/MarianArlt/sddm-sugar-candy
  $AUR sddm # qt5-graphicaleffects qt5-quickcontrols2 qt5-svg sddm-sugar-dark
  sudo systemctl enable sddm
  $SL
}


function install_qtile() {
  $AUR    \
    qtile \
    rofi  \
    dunst \
    feh   \
    alsa-utils \
    volumeicon \
    lxsession-gtk3 \
    lxappearance-gtk3 \
    network-manager-applet
  $SL
}


function install_gnome() {
  $AUR gnome gnome-shell-extensions gnome-tweaks
  sudo systemctl enable gdm.service

  # themes
  $AUR matcha-gtk-theme qogir-icon-theme
  $SL
}

function extra() {
  # Extras
  $AUR   \
    bat  \
    exa  \
    fd   \
    dust \
    neovim

  # flatpak install flathub com.google.Chrome
  flatpak install flathub com.brave.Browser
  flatpak install flathub com.spotify.Client
  flatpak install flathub com.visualstudio.code
  $SL
}


function dotfiles() {
  git clone --bare https://github.com/r3kall/dotfiles $HOME/.dotfiles
  local config="/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME"
  $config checkout
  $config config --local status.showUntrackedFiles no
  $SL
}

function main() {
  init
  common

  case $DE in
    "gnome")
      echo -n "Installing GNOME desktop environment."
      install_gnome
      ;;
    *)
      echo -n "Invalid variiable name."
      exit 1
      ;;
  esac

  extra
  dotfiles
  $SL
}

time main
$SL
sudo reboot

