#!/bin/bash
set -e

####
FULL=true
DE="hyprland"
####

## Commands
AUR="paru -Sq --needed --noconfirm --color auto"
SL="sleep 3"


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
    kitty \
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
    noto-fonts \
    ttf-dejavu \
    ttf-ubuntu-mono-nerd \
    ttf-hack \
    ttf-hack-nerd

  fc-cache
  $SL
}


function xserver() {
  $AUR xorg xorg-xinit xterm
  $SL
}


function install_display_manager() {
  local DM=$1

  case $DM in
    "sddm")
      echo -n "Installing SDDM ..."
      # Check sddm them at https://framagit.org/MarianArlt/sddm-sugar-candy
      $AUR qt6-base qt6-declarative qt5-base qt5-declarative \
        qt5-graphicaleffects qt5-quickcontrols2 qt5-svg \
        sddm sddm-sugar-dark
      sudo systemctl enable sddm.service
      ;;
    "ly")
      echo -n "Installing ly ..."
      $AUR ly
      sudo systemctl enable ly.service
      ;;
    *)
      echo -n "Invalid variable name."
      exit 1
      ;;
  esac 
  
  $SL
}


function install_gnome() {
  xserver
  $AUR gnome gnome-shell-extensions gnome-tweaks
  sudo systemctl enable gdm.service

  # themes
  $AUR matcha-gtk-theme qogir-icon-theme
  $SL
}


function install_hyprpanel() {
  paru -Sq \
    --needed brightnessctl ags-hyprpanel-git \
    --asdeps btop grimblast-git python-pywal power-profiles-daemon swww wf-recorder matugen-bin
  $SL
}

function install_hyprland() {
  # Common
  $AUR wayland gtk4 qt5-base qt5-declarative qt5-wayland qt6-base qt6-declarative qt6-wayland

  # UWSM
  $AUR uwsm libnewt

  # Install Hyprland Libraries
  $AUR \
    hyprutils \
    hyprlang \
    hyprcursor \
    hyprwayland-scanner \
    aquamarine \
    hyprgraphics \
    hyprland-qt-support \
    hyprland-qtutils

  # Install Hyprland Utils
  $AUR \
    hyprpaper \
    hyprpicker \
    hypridle \
    hyprlock \
    hyprsunset \
    xdg-desktop-portal-hyprland \
    hyprsysteminfo \
    hyprpolkitagent

  # hyprland
  $AUR hyprland

  # display manager
  install_display_manager "ly"

  # hyprpanel
  install_hyprpanel

  $SL
}


function extra() {
  # Extras
  $AUR \
    bat \
    eza

  #flatpak install flathub com.google.Chrome
  #flatpak install -y --noninteractive flathub com.spotify.Client
  #flatpak install -y --noninteractive flathub com.visualstudio.code
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
  core
  aur_helper
  fonts
  terminal
  $SL

  # if $FULL; then
  #   case $DE in
  #     "gnome")
  #       echo -n "Installing GNOME desktop environment."
  #       install_gnome
  #       extra
  #       dotfiles
  #       ;;
  #     "hyprland")
  #       echo -n "Installing QTILE desktop environment."
  #       install_hyprland
  #       extra
  #       dotfiles
  #       ;;
  #     *)
  #       echo -n "Invalid variiable name."
  #       exit 1
  #       ;;
  #   esac

  #   dotfiles
  # fi

  install_hyprland

  $SL
}


time main
$SL
sudo reboot

