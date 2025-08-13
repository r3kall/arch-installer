#!/usr/bin/env bash
set -euo pipefail

# Set unambigous PATH for root
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 027

echo "==== Post Install Script ===="

# Script Directory
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
echo "[i] Script dir: $DIR"

# Log
LOG="${LOG:-/var/log/arch-post.log}"
exec > >(tee -a "$LOG") 2>&1
set -x

if (( EUID != 0 )); then
  echo "[!] Re-exec with sudo please"
  # exec sudo -H bash "$0" "$@"
  exit 1
fi

trap 'echo "[!] Error on line ${LINENO}. See $LOG"; exit 1' ERR

# Target User
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  read -rp "Enter target username: " TARGET_USER
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
: "${TARGET_HOME:?User home not found}"

# Profiles
WINDOW_MANAGER="${WINDOW_MANAGER:-hyprland}"	# hyprland|wayfire|all|none
DISPLAY_MANAGER="${DISPLAY_MANAGER:-ly}"		# greetd|sddm|ly|none
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-0}"		# 1|0	
ENABLE_CUPS="${ENABLE_CUPS:-0}"					# 1|0
AUR_HELPER="${AUR_HELPER:-paru}"				# paru|yay
AUR_ARGS="${AUR_ARGS:---noconfirm --needed}"	# extra args

DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/r3kall/dotfiles}"
DOTFILES_DIR="${DOTFILES_DIR:-$TARGET_HOME/.dotfiles}"     # bare repo dir
DOTFILES_BACKUP_DIR="${DOTFILES_BACKUP_DIR:-$TARGET_HOME/.config-backup-$(date +%Y%m%d-%H%M%S)}"

# -------- Helpers --------
pac()			 { pacman --noconfirm --needed -S "$@"; }
sysen()			 { systemctl enable "$@"; }
is_virtualized() { systemd-detect-virt -q; }
virt_what()		 { systemd-detect-virt 2>/dev/null || true; }
gpu_vendor()	 { lspci -nnk | awk '/VGA|3D|Display/{print tolower($0)}'; }
run_as_user()	 { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

install_aur_packages() {
  if [[ -n "$AUR_LIST" && -f "$AUR_LIST" ]]; then
	echo "[i] Installing AUR packages from $AUR_LIST ..."
    run_as_user "${AUR_HELPER} -Syu ${PARU_ARGS} $(grep -vE '^\s*#' \"$AUR_LIST\" | sed '/^\s*$/d' | tr '\n' ' ')"
  else
	echo "[i] No AUR_LIST provided or file not found."
	exit 1
  fi
}

# -------- Mirrors quick tune --------
echo "[i] Test Internet Connection and Mirrolist. It may take few seconds..."
ping -c 1 -W 5 google.com >/dev/null
if ! command -v reflector >/dev/null 2>&1; then pac reflector; fi
reflector -c Italy,Switzerland,Germany,France -p https -l 16 --sort rate \
	--save /etc/pacman.d/mirrorlist || true
echo "[i] Full System Upgrade"
pacman -Syyuq --noconfirm

# -------- Core Packages --------
echo "[i] Install Core Packages"
pac		\
  gcc     \
  python  \
  rustup  \
  go      \
  nvm     \
  flatpak \
  bat     \
  eza     \
  fd      \
  fzf

run_as_user 'rustup default stable'

if ! command -v docker >/dev/null 2>&1; then
  # Install Docker
  pac docker
  groupadd -f docker
  usermod -aG docker $TARGET_USER

  # Enable native overlay diff engine
  echo "options overlay metacopy=off redirect_dir=off" | sudo tee /etc/modprobe.d/disable-overlay-redirect-dir.conf
  modprobe -r overlay
  modprobe overlay
  sysen docker
fi

# -------- Install AUR helper --------
if ! command -v ${AUR_HELPER} >/dev/null 2>&1; then
  echo "[i] Installing ${AUR_HELPER} as ${TARGET_USER}..."
  run_as_user "
	set -euo pipefail
	tmpdir=\$(mktemp -d)
	cd \$tmpdir
	git clone https://aur.archlinux.org/$AUR_HELPER.git
	cd $AUR_HELPER
	makepkg -si --noconfirm
  "
  sed -i 's/#BottomUp/BottomUp/' /etc/$AUR_HELPER.conf
else
  echo "[i] ${AUR_HELPER} already present."
fi

# -------- Install Commons --------
AUR_LIST="$DIR/aur-packages.txt" install_aur_packages
run_as_user '
  fc-cache -f
  mkdir -p "$XDG_CACHE_HOME/zsh" || true
  chsh -s "$(command -v zsh)"
'

# -------- Bluetooth --------
if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
  pac bluez bluez-utils blueman
  sysen bluetooth
fi

# -------- Printing --------
if [[ "$ENABLE_CUPS" == "1" ]]; then
  pac cups cups-pdf system-config-printer
  sysen cups
fi

case "$WINDOW_MANAGER" in
  "hyprland")
	AUR_LIST="$DIR/hyprland-packages.txt" install_aur_packages
	;;
  "none")
	echo "[i] Skip Window Manager installation ..."
  *)
	echo "[!] Invalid Window Manager"
	exit 1
	;;
esac

case "$DISPLAY_MANAGER" in
  "sddm")
	# Check sddm them at https://framagit.org/MarianArlt/sddm-sugar-candy
	pac sddm
	sysen sddm
	;;
  "ly")
	run_as_user "$AUR_HELPER $AUR_ARGS ly"
	sysen ly
	;;
  *)
	echo "[!] Invalid Display Manager"
	exit 1
	;;
esac

#flatpak install -y --noninteractive flathub com.spotify.Client
#flatpak install -y --noninteractive flathub com.visualstudio.code

bootstrap_dotfiles() {
  echo "[i] Bootstrapping dotfiles for ${TARGET_USER} from ${DOTFILES_REPO}"
  run_as_user '
    set -euo pipefail
    REPO_URL="'"$DOTFILES_REPO"'"
    DOT_DIR="'"$DOTFILES_DIR"'"
    BACKUP_DIR="'"$DOTFILES_BACKUP_DIR"'"
    mkdir -p "$BACKUP_DIR"

    if [[ ! -d "$DOT_DIR" ]]; then
      git clone --bare "$REPO_URL" "$DOT_DIR"
      git --git-dir="$DOT_DIR" --work-tree="$HOME" config status.showUntrackedFiles no
    else
      echo "[i] Dotfiles bare repo already exists at $DOT_DIR"
      git --git-dir="$DOT_DIR" remote set-url origin "$REPO_URL" || true
      git --git-dir="$DOT_DIR" fetch --all --prune
    fi

    # Try a checkout; if conflicts, back them up then retry
    if ! git --git-dir="$DOT_DIR" --work-tree="$HOME" checkout; then
      echo "[i] Backing up pre-existing files into $BACKUP_DIR"
      git --git-dir="$DOT_DIR" --work-tree="$HOME" ls-tree -r --name-only HEAD | while read -r path; do
        if [[ -f "$HOME/$path" || -d "$HOME/$path" ]] && [[ ! -L "$HOME/$path" ]]; then
          mkdir -p "$BACKUP_DIR/$(dirname "$path")"
          mv -f "$HOME/$path" "$BACKUP_DIR/$path" 2>/dev/null || true
        fi
      done
      git --git-dir="$DOT_DIR" --work-tree="$HOME" checkout
    fi

    git --git-dir="$DOT_DIR" --work-tree="$HOME" submodule update --init --recursive || true

    echo "[✓] Dotfiles deployed. Backup (if any): $BACKUP_DIR"
  '
}
bootstrap_dotfile

echo "Post Install Complete ! you can reboot."
