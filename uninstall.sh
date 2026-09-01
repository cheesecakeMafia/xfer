#!/usr/bin/env bash
set -euo pipefail

BIN_FILE="$HOME/.local/bin/xfer"
CONFIG_DIR="$HOME/.config/xfer"
DATA_DIR="$HOME/.local/share/xfer"

PURGE=false
YES=false

usage() {
  cat <<'HELP'
Usage:
  ./uninstall.sh [--purge] [--yes]

Options:
  --purge   Remove config, bookmarks, exclude profiles, and history data
  --yes     Skip confirmation prompt for --purge
  -h,--help Show this help
HELP
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge)
        PURGE=true
        ;;
      --yes)
        YES=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'xfer uninstall: unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

confirm_purge() {
  local response=""
  if [[ "$YES" == true ]]; then
    return 0
  fi

  printf 'Purge will remove %s and %s. Continue? [y/N] ' "$CONFIG_DIR" "$DATA_DIR"
  read -r response
  case "$response" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      printf 'Purge cancelled.\n'
      return 1
      ;;
  esac
}

main() {
  parse_args "$@"

  if [[ -f "$BIN_FILE" ]]; then
    rm -f "$BIN_FILE"
    printf 'Removed: %s\n' "$BIN_FILE"
  else
    printf 'Not present: %s\n' "$BIN_FILE"
  fi

  if [[ "$PURGE" == true ]]; then
    if confirm_purge; then
      rm -rf "$CONFIG_DIR" "$DATA_DIR"
      printf 'Removed: %s\n' "$CONFIG_DIR"
      printf 'Removed: %s\n' "$DATA_DIR"
    else
      printf 'Preserved: %s\n' "$CONFIG_DIR"
      printf 'Preserved: %s\n' "$DATA_DIR"
    fi
  else
    printf 'Preserved: %s\n' "$CONFIG_DIR"
    printf 'Preserved: %s\n' "$DATA_DIR"
  fi
}

main "$@"
