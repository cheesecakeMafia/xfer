#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/xfer"
DATA_DIR="$HOME/.local/share/xfer"
HISTORY_FILE="$DATA_DIR/history.log"
CONFIG_FILE="$CONFIG_DIR/config"
BOOKMARKS_DIR="$CONFIG_DIR/bookmarks"
PROFILES_DIR="$CONFIG_DIR/exclude-profiles"

MACHINES=()
THIS_MACHINE=""
CAN_SSH_TO=""

declare -A USERS
declare -A IPS
declare -A KEYS

usage() {
  cat <<'HELP'
Usage:
  ./install.sh [options]

Options:
  -h, --help   Show this help
HELP
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'xfer install: unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    printf 'xfer install: missing required command: %s\n' "$cmd" >&2
    exit 1
  }
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " value
    printf '%s\n' "${value:-$default_value}"
  else
    read -r -p "$prompt: " value
    printf '%s\n' "$value"
  fi
}

machine_exists() {
  local candidate="$1"
  local machine
  for machine in "${MACHINES[@]}"; do
    if [[ "$machine" == "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

detect_default_machine() {
  local host_name=""
  host_name="${HOSTNAME:-}"
  if [[ -z "$host_name" ]]; then
    host_name="$(hostname 2>/dev/null || true)"
  fi
  host_name="${host_name%%.*}"

  if machine_exists "$host_name"; then
    printf '%s\n' "$host_name"
    return
  fi

  printf '\n'
}

parse_ssh_config() {
  local host="$1"
  local line_key=""
  local line_value=""
  local detected_ip=""
  local detected_user=""
  local detected_key=""

  while read -r line_key line_value _; do
    case "$line_key" in
      hostname)
        if [[ -z "$detected_ip" ]]; then
          detected_ip="$line_value"
        fi
        ;;
      user)
        if [[ -z "$detected_user" ]]; then
          detected_user="$line_value"
        fi
        ;;
      identityfile)
        if [[ -z "$detected_key" ]]; then
          detected_key="$line_value"
        fi
        ;;
    esac
  done < <(ssh -G "$host" 2>/dev/null || true)

  printf '%s\t%s\t%s\n' "$detected_ip" "$detected_user" "$detected_key"
}

choose_machines() {
  local input=""
  local detected_default=""

  printf 'Enter the names of all machines in your network (space-separated).\n'
  printf 'Example: workstation laptop server\n'
  read -r -p "Machine names: " input

  if [[ -z "$(printf '%s' "$input" | tr -d '[:space:]')" ]]; then
    printf 'xfer install: at least one machine name is required\n' >&2
    exit 1
  fi

  read -r -a MACHINES <<< "$input"

  detected_default="$(detect_default_machine)"

  while true; do
    if [[ -n "$detected_default" ]]; then
      THIS_MACHINE="$(prompt_with_default "Which is this machine?" "$detected_default")"
    else
      read -r -p "Which is this machine? (${MACHINES[*]}): " THIS_MACHINE
    fi
    if machine_exists "$THIS_MACHINE"; then
      break
    fi
    printf 'Invalid. Choose one of: %s\n' "${MACHINES[*]}"
  done

  local others=()
  local machine
  for machine in "${MACHINES[@]}"; do
    [[ "$machine" != "$THIS_MACHINE" ]] && others+=("$machine")
  done

  if [[ "${#others[@]}" -eq 0 ]]; then
    CAN_SSH_TO=""
    return
  fi

  read -r -p "Which machines can this one SSH into? (from: ${others[*]}): " CAN_SSH_TO
}

collect_machine_values() {
  local machine=""
  local detected=""
  local detected_ip=""
  local detected_user=""
  local detected_key=""

  for machine in "${MACHINES[@]}"; do
    if [[ "$machine" == "$THIS_MACHINE" ]]; then
      USERS[$machine]="$USER"
      IPS[$machine]=""
      KEYS[$machine]=""
      continue
    fi

    detected="$(parse_ssh_config "$machine")"
    IFS=$'\t' read -r detected_ip detected_user detected_key <<< "$detected"

    printf '\nMachine: %s\n' "$machine"
    USERS[$machine]="$(prompt_with_default "  SSH user" "$detected_user")"
    IPS[$machine]="$(prompt_with_default "  Tailscale IP / HostName" "$detected_ip")"
    KEYS[$machine]="$(prompt_with_default "  SSH key path (optional)" "$detected_key")"

    if [[ -z "${USERS[$machine]}" || -z "${IPS[$machine]}" ]]; then
      printf 'xfer install: user and host are required for %s\n' "$machine" >&2
      exit 1
    fi
  done
}

write_default_profiles() {
  cat > "$PROFILES_DIR/dev" <<'PROFILE'
node_modules
.git
__pycache__
.venv
*.pyc
dist
build
.next
.cache
.tox
*.egg-info
PROFILE

  cat > "$PROFILES_DIR/media" <<'PROFILE'
*.mp4
*.mkv
*.avi
*.mov
*.iso
*.zip
*.tar.gz
*.rar
PROFILE
}

write_config() {
  local machine

  {
    printf 'MACHINES=(%s)\n\n' "${MACHINES[*]}"

    for machine in "${MACHINES[@]}"; do
      printf '%s_user="%s"\n' "$machine" "${USERS[$machine]:-}"
      printf '%s_ip="%s"\n' "$machine" "${IPS[$machine]:-}"
      printf '%s_ssh_key="%s"\n\n' "$machine" "${KEYS[$machine]:-}"
    done

    printf 'THIS_MACHINE="%s"\n' "$THIS_MACHINE"
    printf 'CAN_SSH_TO="%s"\n' "$CAN_SSH_TO"
    printf 'RSYNC_DEFAULT_FLAGS="-a -v -z --progress --partial --human-readable --protect-args"\n'
  } > "$CONFIG_FILE"

  chmod 600 "$CONFIG_FILE"
}

main() {
  parse_args "$@"

  require_cmd bash
  require_cmd rsync
  require_cmd ssh
  require_cmd flock
  require_cmd base64

  mkdir -p "$BIN_DIR" "$BOOKMARKS_DIR" "$PROFILES_DIR" "$DATA_DIR"
  touch "$HISTORY_FILE"

  choose_machines
  collect_machine_values

  install -m 0755 "$SCRIPT_DIR/src/xfer" "$BIN_DIR/xfer"
  write_default_profiles
  write_config

  printf '\nInstall complete.\n'
  printf '  Binary: %s\n' "$BIN_DIR/xfer"
  printf '  Config: %s\n' "$CONFIG_FILE"
  printf '  This machine: %s\n' "$THIS_MACHINE"
  printf '  Reachable machines: %s\n' "$CAN_SSH_TO"
  printf '\nAdd %s to PATH if needed.\n' "$BIN_DIR"
}

main "$@"
