#!/usr/bin/env bash
set -euo pipefail

# --- Root requirement ---
if (( EUID != 0 )); then
  echo "[!] Re-exec with sudo please." >&2
  exit 1
fi

# --- Environment and Logging ---
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 027

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG="${LOG:-/var/log/${SCRIPT_NAME%.sh}-${RUN_ID}.log}"
exec > >(tee -a "$LOG") 2>&1

# --- Globals / Profiles ---
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  read -rp "Enter target username: " TARGET_USER
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
: "${TARGET_HOME:?User home not found}"

WINDOW_MANAGER="${WINDOW_MANAGER:-hyprland}"	# hyprland|wayfire|all|none
DISPLAY_MANAGER="${DISPLAY_MANAGER:-ly}"		# greetd|sddm|ly|none
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-0}"		# 1|0	
ENABLE_CUPS="${ENABLE_CUPS:-0}"					# 1|0

AUR_HELPER="${AUR_HELPER:-paru}"				# paru|yay
AUR_ARGS="${AUR_ARGS:---noconfirm --needed --skipreview}" # extra args

DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/r3kall/dotfiles}"
DOTFILES_DIR="${DOTFILES_DIR:-$TARGET_HOME/.dotfiles}"  # bare repo dir

SUDOERFILE="${SUDOERFILE:-/etc/sudoers.d/99-user-tmp-permissions}"

# --- Helpers ---
pac()			 { pacman --noconfirm --needed -S "$@"; }
sysen()			 { systemctl enable "$@"; }
run_as_user()	 { sudo -u "$TARGET_USER" -H -- bash -lc "$*"; }

# (Optional)
is_virtualized() { systemd-detect-virt -q; }
virt_what()		 { systemd-detect-virt 2>/dev/null || true; }
gpu_vendor()	 { lspci -nnk | awk '/VGA|3D|Display/{print tolower($0)}'; }

add_user_nopasswd() {
  echo "[i] Adding temp sudoers permission to user $TARGET_USER ..."
  echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" | tee "$SUDOERFILE"
  chmod 440 "$SUDOERFILE"
  chown root:root "$SUDOERFILE"

  if ! visudo -c >/dev/null; then
	echo "[!] Sudoers config invalid, reverting." >&2
	exit 1
  else
	echo "[✓] Sudoers config valid."
  fi
}

remove_user_nopasswd() {
  if [[ -f "$SUDOERFILE" ]]; then
    echo "[i] Removing temp sudoers permission for $TARGET_USER ..."
    rm -f "$SUDOERFILE" || true
  fi
}

install_aur_packages() {
  if [[ -n "$AUR_LIST" && -f "$AUR_LIST" ]]; then
	echo "[i] Installing AUR packages from $AUR_LIST ..."
    run_as_user "
      export CARGO_HOME=\"\$XDG_DATA_HOME/cargo\"
      export RUSTUP_HOME=\"\$XDG_DATA_HOME/rustup\"
	  $AUR_HELPER $AUR_ARGS -S \$(cat $AUR_LIST | grep -vE '^\s*#' | sed '/^\s*$/d' | tr '\n' ' ')
	"
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

  remove_user_nopasswd || true

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
reflector -c Italy,Switzerland,Germany -p https -l 10 --save /etc/pacman.d/mirrorlist || true

echo "[i] Upgrading full system ..."
pacman -Syyu --noconfirm

# --- Core Packages --------
echo "[i] Installing Core Packages ..."
pac		\
  gcc     \
  python  \
  rustup  \
  go      \
  flatpak \
  bat     \
  eza     \
  fd      \
  fzf

run_as_user '
  export CARGO_HOME="$XDG_DATA_HOME/cargo"
  export RUSTUP_HOME="$XDG_DATA_HOME/rustup"
  rustup default stable
'

if ! command -v docker >/dev/null 2>&1; then
  pac docker
  groupadd -f docker
  usermod -aG docker $TARGET_USER

  # Enable native overlay diff engine
  echo "options overlay metacopy=off redirect_dir=off" | tee /etc/modprobe.d/disable-overlay-redirect-dir.conf >/dev/null
  modprobe -r overlay
  modprobe overlay
  sysen docker
fi

echo "[✓] Core Packages Installed."

# --- Add User to sudoers ---
add_user_nopasswd

# --- Install AUR helper --------
if ! command -v ${AUR_HELPER} >/dev/null 2>&1; then
  echo "[i] Installing ${AUR_HELPER} as ${TARGET_USER} ..."
  pac ccache
  sed -i 's/^#\?MAKEFLAGS=.*/MAKEFLAGS="-j'$(nproc)'"/' /etc/makepkg.conf
  sed -i 's/^#\?BUILDENV=.*/BUILDENV=(!distcc color ccache check !sign)/' /etc/makepkg.conf
  
  run_as_user '
	set -euo pipefail
    export CARGO_HOME="$XDG_DATA_HOME/cargo"
    export RUSTUP_HOME="$XDG_DATA_HOME/rustup"
	
	TMPDIR="${TMPDIR:-/var/tmp}"
	AUR_HELPER="'"$AUR_HELPER"'"
    tmp="$(mktemp -d -p $TMPDIR $AUR_HELPER.XXXXXX)"
	cd "$tmp"
	git clone --depth=1 https://aur.archlinux.org/$AUR_HELPER.git
	cd "$AUR_HELPER"
	makepkg -sri --noconfirm --needed 
  '
  [[ -f "/etc/${AUR_HELPER}.conf" ]] && \
    sed -i -e 's/^#BottomUp/BottomUp/' -e 's/^#SudoLoop/SudoLoop/' "/etc/$AUR_HELPER.conf"
  
  echo "[✓] AUR Helper Installed."
else
  echo "[i] ${AUR_HELPER} already present."
fi

# --- Install Common AUR packages list --------
AUR_LIST="$DIR/aur-packages.txt" install_aur_packages

# --- SHELL config ---
# zsh as default shell for the user (no password prompt)
# TODO: parametric shell
# if command -v zsh >/dev/null 2>&1; then
# chsh -s "$(run_as_user 'command -v zsh')" "$TARGET_USER" || true
run_as_user '
  fc-cache -f
  chsh -s $(command -v zsh) || true
  mkdir -p "$XDG_CACHE_HOME/zsh" || true
'

run_as_user '
  eval "$(fnm env --shell bash)"
  fnm install --lts
  fnm default lts-latest
  corepack enable || true
  # optional: common global tools
  # npm -g install typescript eslint yarn pnpm || true
'

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

# --- Window Manager -------
case "$WINDOW_MANAGER" in
  "hyprland")
	echo "[i] Installing Hyprland ..."
	AUR_LIST="$DIR/hyprland-packages.txt" install_aur_packages
	;;
  "wayfire")
	echo "[i] Installing Wayfire ..."
	AUR_LIST="$DIR/wayfire-packages.txt" install_aur_packages
	;;
  "none")
	echo "[i] Skip Window Manager installation ..."
	;;
  *)
	echo "[!] Invalid Window Manager." >&2
	exit 1
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
	exit 1
	;;
esac

#flatpak install -y --noninteractive flathub com.spotify.Client
#flatpak install -y --noninteractive flathub com.visualstudio.code

bootstrap_dotfiles() {
  echo "[i] Bootstrapping dotfiles for ${TARGET_USER} from ${DOTFILES_REPO} ..."
  run_as_user '
    set -euo pipefail
    REPO_URL="'"$DOTFILES_REPO"'"
    DOT_DIR="'"$DOTFILES_DIR"'"

    if [[ ! -d "$DOT_DIR" ]]; then
      git clone --bare "$REPO_URL" "$DOT_DIR"
      git --git-dir="$DOT_DIR" --work-tree="$HOME" config status.showUntrackedFiles no
    else
      echo "[i] Dotfiles bare repo already exists at $DOT_DIR"
      git --git-dir="$DOT_DIR" remote set-url origin "$REPO_URL" || true
      git --git-dir="$DOT_DIR" fetch --all --prune
    fi
  '
  echo "[✓] Dotfiles deployed."
}
bootstrap_dotfiles

