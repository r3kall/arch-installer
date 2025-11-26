#!/usr/bin/env bash
set -euo pipefail

# Alias
AUR="paru -S --needed --noconfirm"

# Profiles
ENABLE_QEMU_GUEST=${ENABLE_QEMU_GUEST:-0}
ENABLE_CUPS=${ENABLE_CUPS:-0}
ENABLE_BLUETOOTH=${ENABLE_BLUETOOTH:-1}
DISPLAY_MANAGER="${DISPLAY_MANAGER:-ly}"


die(){ echo "ERROR: $*"; exit 1; }

init () {
  ping -c 1 -W 5 google.com >/dev/null || die "No Internet"

  exec &> >(sudo tee -a "/var/log/post.log")
  set -x
}

core() {
  sudo pacman -Syyuq --noconfirm
}

aur_helper() {
  local aur_home="/home/$USER/paru"
  if ! command -v paru >/dev/null; then
    [ ! -d $aur_home ] && git -C /home/$USER clone https://aur.archlinux.org/paru-bin.git
    (cd $aur_home && makepkg -mcsi --needed --noconfirm --noprogressbar)
    sudo sed -i 's/#BottomUp/BottomUp/' /etc/paru.conf
    rm -Rf ${aur_home}
  fi
}

docker() {
  if ! command -v docker >/dev/null; then
	  # Install Docker
	  sudo pacman -S --noconfirm docker
	  sudo groupadd -f docker
	  sudo usermod -aG docker $USER

	  # Enable native overlay diff engine
	  echo "options overlay metacopy=off redirect_dir=off" | sudo tee /etc/modprobe.d/disable-overlay-redirect-dir.conf
	  sudo modprobe -r overlay
	  sudo modprobe overlay
	  sudo systemctl enable docker
  fi
}

wayland() {
  $AUR      \
    wayland \
    gtk3 gtk4 \
    qt5-base qt5-declarative qt5-wayland \
    qt6-base qt6-declarative qt6-wayland \
    xdg-desktop-portal \
    uwsm libnewt \
    xorg-xwayland
}

fonts() {
  $AUR \
    noto-fonts \
	  noto-fonts-cjk \
	  noto-fonts-emoji \
    ttf-dejavu \
    ttf-ubuntu-mono-nerd \
    ttf-hack \
    ttf-hack-nerd

  fc-cache -f
}

terminal() {
  $AUR        \
    ghostty   \
    foot      \
    zsh       \
    starship  \
    fastfetch \
    zsh-completions \
    zsh-autosuggestions \
    zsh-syntax-highlighting \
    zsh-history-substring-search

  chsh -s "$(command -v zsh)"
  mkdir -p "$XDG_CACHE_HOME/zsh"
}

display_manager() {
  local DM=$DISPLAY_MANAGER

  case $DM in
    "sddm")
      echo -n "Installing SDDM ..."
      # Check sddm them at https://framagit.org/MarianArlt/sddm-sugar-candy
      $AUR sddm
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
}

utils() {
  # File utilities
  $AUR bat eza fd ripgrep fzf zoxide resvg imagemagick wl-clipboard yazi jq yq
  # Audio
  $AUR pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
  # Multimedia
  $AUR ffmpeg gstreamer gst-libav gst-plugin-pipewire vlc
  # Notifications
  $AUR libnotify gvfs swaync
  # Theming + wallpapers
  $AUR matugen-bin swww
  # Launcher
  $AUR rofi-wayland
  # Editors & LSPs
  # $AUR neovim bash-language-server lua-language-server pyright gopls rust-analyzer
  # PDF
  # $AUR sqlite file zathura zathura-pdf-mupdf
}

install_hyprland() {

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
    hyprpolkitagent

  # hyprland
  $AUR hyprland
}

waybar() {
  $AUR waybar
}

extra() {
  if [[ "$ENABLE_QEMU_GUEST" -eq 1 ]]; then
	  $AUR qemu-guest-agent
	  sudo systemctl enable qemu-guest-agent.service
  fi

  if [[ "$ENABLE_CUPS" -eq 1 ]]; then
	  $AUR cups cups-pdf system-config-printer
	  sudo systemctl enable cups.service
  fi

  if [[ "$ENABLE_BLUETOOTH" -eq 1 ]]; then
	  $AUR bluez bluez-utils blueman
	  sudo systemctl enable bluetooth.service
  fi

  #flatpak install -y --noninteractive flathub com.spotify.Client
  #flatpak install -y --noninteractive flathub com.visualstudio.code
}


dotfiles() {
  git clone --bare https://github.com/r3kall/dotfiles $HOME/.dotfiles
  local config="/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME"
  $config checkout
  $config config --local status.showUntrackedFiles no
  source $HOME/.zshenv
}

mise() {
  # Configure Runtimes/DevTools Env Variables
  $AUR mise
  mise use -g uv@latest pipx@latest python@latest
  mise use -g node@latest
  mise use -g go@latest
  mise use -g rust@latest
  mise use -g terraform@latest opentofu@latest terragrunt@latest
  mise use -g ansible@latest
  mise use -g helm@latest helmfile@latest
}


function main() {
  init
  core
  aur_helper
  docker
  wayland
  fonts
  terminal
  utils
  install_hyprland
  waybar
  display_manager
  extra
  dotfiles
  mise
}

time main "$@"
echo "Post Install Complete ! you can reboot."
