#!/bin/bash
set -e


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
    bat     \
    eza     \
    fd      \
    fzf

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


function wayland() {
  $AUR      \
    wayland \
    gtk4    \
    qt5-base qt5-declarative qt5-wayland \
    qt6-base qt6-declarative qt6-wayland \
    uwsm libnewt \
    xorg-xwayland
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


function terminal() {
  $AUR        \
    kitty     \
    foot      \
    zsh       \
    starship  \
    zsh-completions \
    zsh-autosuggestions \
    zsh-syntax-highlighting \
    zsh-history-substring-search

  sudo chsh -s $(which zsh)
  $SL
}


function display_manager() {
  local DM=$1

  case $DM in
    "sddm")
      echo -n "Installing SDDM ..."
      # Check sddm them at https://framagit.org/MarianArlt/sddm-sugar-candy
      $AUR \
        qt5-graphicaleffects \
        qt5-quickcontrols2 \
        qt5-svg \
        sddm \
        sddm-sugar-dark
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


function utils() {
  $AUR blueman bluez
  $AUR \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack \
    pavucontrol pulsemixer \
    wireplumber
  $AUR ffmpeg gstreamer gst-libav gst-plugin-pipewire
  $AUR vlc vlc-plugin-all

  # Install notification daemon
  # Swaync behave also as side panel
  $AUR libnotify gvfs swaync
  
  # Install pywal-like and swww
  $AUR hellwal swww

  # Install wofi and deps
  $AUR wl-clipboard wofi wofi-emoji
  
  # Install neovim and lsps
  $AUR neovim bash-language-server

  # Install pdf reader
  $AUR sqlite file zathura

  # Install file managers
  $AUR ffmpeg 7zip jq yq fd ripgrep fzf zoxide resvg imagemagick wl-clipboard yazi
  $SL

  systemctl --user enable pipewire.service
  systemctl --user enable pipewire-pulse.service
  systemctl enable bluetooth
  $SL
}

# function install_hyprpanel() {
#   paru -Sq \
#     --needed brightnessctl ags-hyprpanel-git \
#     --asdeps btop grimblast-git python-pywal power-profiles-daemon swww wf-recorder matugen-bin
#   $SL
# }

function install_hyprland() {

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
    hypridle \
    hyprlock \
    hyprpicker \
    hyprsunset \
    xdg-desktop-portal-hyprland \
    xdg-desktop-portal-gtk \
    hyprsysteminfo \
    hyprpolkitagent

  # hyprland
  $AUR hyprland waybar

  $SL
}

function extra() {
  # Extras

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
  wayland
  fonts
  terminal
  utils
  install_hyprland
  display_manager "ly"
  dotfiles
  $SL
}


time main
sudo reboot
