#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG="${LOG:-/var/log/${SCRIPT_NAME%.sh}-${RUN_ID}.log}"
exec > >(tee -a "$LOG") 2>&1

# --- Globals / Profiles ---
TARGET_USER="${TARGET_USER:-${USER:-}}"
TARGET_HOME="${TARGET_HOME:-${HOME:-}}"
WINDOW_MANAGER="${WINDOW_MANAGER:-hyprland}"	# hyprland|wayfire|all|none
DISPLAY_MANAGER="${DISPLAY_MANAGER:-ly}"		# greetd|sddm|ly|none
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-0}"		# 1|0
ENABLE_CUPS="${ENABLE_CUPS:-0}"					# 1|0

AUR_HELPER="${AUR_HELPER:-paru}"				# paru|yay
AUR_ARGS="${AUR_ARGS:---noconfirm --needed --skipreview}" # extra args

DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/r3kall/dotfiles}"
DOTFILES_DIR="${DOTFILES_DIR:-$TARGET_HOME/.dotfiles}"  # bare repo dir

# --- Helpers ---
pac()		{ sudo pacman --noconfirm --needed -S "$@"; }
sysen()	{ sudo systemctl enable "$@"; }

# (Optional)
is_virtualized() { systemd-detect-virt -q; }
virt_what()		   { systemd-detect-virt 2>/dev/null || true; }
gpu_vendor()	   { lspci -nnk | awk '/VGA|3D|Display/{print tolower($0)}'; }

install_aur_packages() {
  if [[ -n "$AUR_LIST" && -f "$AUR_LIST" ]]; then
    echo "[i] Installing AUR packages from $AUR_LIST ..."
    AUR_HELPER $AUR_ARGS -S \$(cat $AUR_LIST | grep -vE '^\s*#' | sed '/^\s*$/d' | tr '\n' ' ')
    echo "[✓] Packages from $AUR_LIST installed."
  else
    echo "[!] AUR_LIST not provided or file not found."
    exit 1
  fi
}

# --- Cleanup & traps ---------------------------------------------------------
_cleanup_ran=0
cleanup() {
  local reason="${1:-EXIT}"
  local code="${2:-0}"
  local cmd="${3:-}"
  local line="${4:-}"

  [[ $_cleanup_ran -eq 1 ]] && return 0

  _cleanup_ran=1
  if [[ "$reason" == "ERR" ]]; then
    echo "[!] Error (exit $code) at line $line: $cmd"
    echo "[!] See log: $LOG"
  else
    echo "[✓] Post Install finished with code $code."
    echo "[i] Log: $LOG"
  fi
}

trap 'cleanup ERR "$?" "$BASH_COMMAND" "$LINENO"' ERR
trap 'cleanup TERM "$?"' TERM
trap 'cleanup EXIT "$?"' EXIT

# --- Begin ---

echo "[i] Starting Post Install ..."
timedatectl set-ntp true

# Network probe
ping -c 1 -W 5 www.google.com >/dev/null

# Mirror refresh (best effort)
if ! command -v reflector >/dev/null; then pac reflector; fi
reflector -c Italy,Germany -p https -l 16 --sort rate --verbose | sudo tee /etc/pacman.d/mirrorlist

echo "[i] Upgrading full system ..."
sudo pacman -Syu --noconfirm

# --- Dotfiles --------
bootstrap_dotfiles() {
  echo "[i] Bootstrapping dotfiles for ${TARGET_USER} from ${DOTFILES_REPO} ..."
  if [[ ! -d "$DOT_DIR" ]]; then
    git clone --bare "$DOTFILES_REPO" "$DOTFILES_DIR"
    git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" config status.showUntrackedFiles no
  else
    echo "[i] Dotfiles bare repo already exists at $DOTFILES_DIR"
    git --git-dir="$DOTFILES_DIR" remote set-url origin "$DOTFILES_REPO" || true
    git --git-dir="$DOTFILES_DIR" fetch --all --prune
  fi
  echo "[✓] Dotfiles deployed."
}
bootstrap_dotfiles

for f in "$HOME"/.config/environment.d/*.conf; do
  [ -r "$f" ] || continue
  # shellcheck disable=SC2046
  export $(grep -vE '^\s*#' "$f" | xargs)
done
env | grep EDITOR

# --- Docker --------
if ! command -v docker >/dev/null 2>&1; then
  pac docker
  sudo groupadd -f docker
  sudo usermod -aG docker $TARGET_USER

  # Enable native overlay diff engine
  echo "options overlay metacopy=off redirect_dir=off" | sudo tee /etc/modprobe.d/disable-overlay-redirect-dir.conf >/dev/null
  sudo modprobe -r overlay
  sudo modprobe overlay
  sysen docker
fi
echo "[✓] Docker Installed."

# --- Install AUR helper --------
if ! command -v ${AUR_HELPER} >/dev/null 2>&1; then
  echo "[i] Installing ${AUR_HELPER} as ${TARGET_USER} ..."
  pac ccache
  sudo sed -i 's/^#\?MAKEFLAGS=.*/MAKEFLAGS="-j'$(nproc)'"/' /etc/makepkg.conf
  sudo sed -i 's/^#\?BUILDENV=.*/BUILDENV=(!distcc color ccache check !sign)/' /etc/makepkg.conf

  TMPDIR="${TMPDIR:-/var/tmp}"
  AUR_HELPER="'"$AUR_HELPER"'"
  tmp="$(mktemp -d -p $TMPDIR $AUR_HELPER.XXXXXX)"
  cd "$tmp"
  git clone --depth=1 https://aur.archlinux.org/$AUR_HELPER-bin.git
  cd "$AUR_HELPER-bin"
  makepkg -sri --noconfirm --needed

  [[ -f "/etc/${AUR_HELPER}.conf" ]] && \
    sudo sed -i -e 's/^#BottomUp/BottomUp/' -e 's/^#SudoLoop/SudoLoop/' "/etc/$AUR_HELPER.conf"
fi
echo "[✓] AUR Helper Installed."

# --- Install Common AUR packages list --------
AUR_LIST="$SCRIPT_DIR/aur-packages.txt" install_aur_packages

# --- SHELL config ---
# zsh as default shell for the user (no password prompt)
# TODO: parametric shell
# if command -v zsh >/dev/null 2>&1; then
# chsh -s "$(run_as_user 'command -v zsh')" "$TARGET_USER" || true

fc-cache -f
chsh -s $(command -v zsh) || true
mkdir -p "$XDG_CACHE_HOME/zsh" || true

# run_as_user '
#   eval "$(fnm env --shell bash)"
#   fnm install --lts
#   fnm default lts-latest
#   corepack enable || true
#   # optional: common global tools
#   # npm -g install typescript eslint yarn pnpm || true
# '

# --- Bluetooth --------
if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
  pac bluez bluez-utils blueman
  sysen bluetooth
fi

# --- Printing --------
if [[ "$ENABLE_CUPS" == "1" ]]; then
  pac cups cups-pdf system-config-printer
  sysen cups
fi

echo "WM: $WINDOW_MANAGER"
# --- Window Manager -------
case "$WINDOW_MANAGER" in
  "hyprland")
	echo "[i] Installing Hyprland ..."
	AUR_LIST="$SCRIPT_DIR/hyprland-packages.txt" install_aur_packages
	;;
  "wayfire")
	echo "[i] Installing Wayfire ..."
	AUR_LIST="$SCRIPT_DIR/wayfire-packages.txt" install_aur_packages
	;;
  "none")
	echo "[i] Skip Window Manager installation ..."
	;;
  *)
	echo "[!] Invalid Window Manager." >&2
	;;
esac

# --- Display Manager -----
case "$DISPLAY_MANAGER" in
  "sddm")
	# Check sddm them at https://framagit.org/MarianArlt/sddm-sugar-candy
	pac sddm
	sysen sddm
	;;
  "ly")
	pac ly
	sysen ly
	;;
  *)
	echo "[!] Invalid Display Manager." >&2
	;;
esac

# Configure Runtimes/DevTools Env Variables
mise use -g uv@latest pipx@latest python@latest
mise use -g node@latest
mise use -g go@latest
mise use -g rust@latest
mise use -g terraform@latest opentofu@latest terragrunt@latest
mise use -g ansible@latest
mise use -g helm@latest helmfile@latest
