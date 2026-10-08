#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<HELP
Usage: ${0##*/} [--config FILE]
Run as your normal user after first boot. Restore aconfmgr, then chezmoi.
Set ACONFMGR_REPO (or an existing ACONFMGR_DIR) and CHEZMOI_REPO.
INSTALL_PROFILE defaults to default; ACONFMGR_PROFILE and CHEZMOI_PROFILE override it.
Configuration is trusted Bash; see README.md. --config must come first.
HELP
}

main() {
  if [[ ${1:-} == --config ]]; then
    (($# >= 2)) && [[ -f $2 ]] || die "--config requires a readable file"
    # shellcheck disable=SC1090
    source "$2"
    shift 2
  fi
  if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; return; fi
  (($# == 0)) || die "Unknown argument: $1"
  [[ $EUID != 0 ]] || die "Run as your normal user, without sudo"
  INSTALL_PROFILE=${INSTALL_PROFILE:-default}
  export ACONFMGR_PROFILE=${ACONFMGR_PROFILE:-$INSTALL_PROFILE}
  CHEZMOI_PROFILE=${CHEZMOI_PROFILE:-$INSTALL_PROFILE}
  [[ $ACONFMGR_PROFILE =~ ^[a-zA-Z0-9_-]+$ && $CHEZMOI_PROFILE =~ ^[a-zA-Z0-9_-]+$ ]] || die "Profiles must contain only letters, numbers, _ or -"
  ACONFMGR_DIR=${ACONFMGR_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aconfmgr}
  ACONFMGR_CONFIG_SUBDIR=${ACONFMGR_CONFIG_SUBDIR:-.}
  local config_dir="$ACONFMGR_DIR/$ACONFMGR_CONFIG_SUBDIR"
  [[ -n ${CHEZMOI_REPO:-} ]] || die "Set CHEZMOI_REPO to your chezmoi repository"
  [[ -d $ACONFMGR_DIR || -n ${ACONFMGR_REPO:-} ]] || die "Set ACONFMGR_REPO or provide an existing ACONFMGR_DIR"
  sudo pacman -Syu --needed git chezmoi base-devel
  if [[ ! -d $ACONFMGR_DIR ]]; then
    mkdir -p "$(dirname -- "$ACONFMGR_DIR")"
    git clone -- "$ACONFMGR_REPO" "$ACONFMGR_DIR"
  fi
  [[ -d $config_dir ]] || die "Missing aconfmgr configuration: $config_dir"
  compgen -G "$config_dir/*.sh" >/dev/null || die "No aconfmgr configuration scripts in $config_dir"
  local aconfmgr_bin
  if command -v aconfmgr >/dev/null; then
    aconfmgr_bin=$(command -v aconfmgr)
  else
    local tool_dir="${XDG_DATA_HOME:-$HOME/.local/share}/aconfmgr-tool"
    if [[ ! -d $tool_dir ]]; then
      mkdir -p "$(dirname -- "$tool_dir")"
      git clone -- https://github.com/CyberShadow/aconfmgr.git "$tool_dir"
    fi
    aconfmgr_bin="$tool_dir/aconfmgr"
    [[ -x $aconfmgr_bin ]] || die "Missing aconfmgr executable: $aconfmgr_bin"
  fi
  echo "Applying aconfmgr profile $ACONFMGR_PROFILE from $config_dir"
  "$aconfmgr_bin" -c "$config_dir" --aur-helper makepkg --paranoid apply
  # Separate source/config paths allow independent dotfiles repositories too.
  local -a chezmoi_cmd=(chezmoi)
  [[ -z ${CHEZMOI_SOURCE:-} ]] || chezmoi_cmd+=(--source "$CHEZMOI_SOURCE")
  [[ -z ${CHEZMOI_CONFIG:-} ]] || chezmoi_cmd+=(--config "$CHEZMOI_CONFIG")
  # init persists data.profile through the repository's config template.
  "${chezmoi_cmd[@]}" init --prompt --promptString "profile=$CHEZMOI_PROFILE" -- "$CHEZMOI_REPO"
  local selected
  selected=$("${chezmoi_cmd[@]}" execute-template '{{ .profile }}')
  [[ $selected == "$CHEZMOI_PROFILE" ]] || die "Your .chezmoi.toml.tmpl must store the profile prompt in [data].profile; see README.md"
  "${chezmoi_cmd[@]}" diff
  "${chezmoi_cmd[@]}" --interactive apply
  echo "Restored system profile $ACONFMGR_PROFILE and dotfiles profile $CHEZMOI_PROFILE."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
