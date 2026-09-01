#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/src/xfer"

TESTS_RUN=0
TESTS_FAILED=0

run_test() {
  local name="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@"; then
    printf 'PASS %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL %s\n' "$name" >&2
  fi
}

assert_eq() {
  local got="$1"
  local expected="$2"
  [[ "$got" == "$expected" ]]
}

contains_arg() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

test_parse_endpoint_basics() {
  MACHINES=(workstation laptop server)
  THIS_MACHINE="workstation"
  CAN_SSH_TO="laptop server"
  CAN_SSH_TO_ARR=(laptop server)

  parse_endpoint "./file:2024.txt"
  assert_eq "$PARSED_KIND" "local" || return 1

  parse_endpoint "laptop:~/notes"
  assert_eq "$PARSED_KIND" "remote" || return 1
  assert_eq "$PARSED_MACHINE" "laptop" || return 1

  parse_endpoint "all:~/dotfiles"
  assert_eq "$PARSED_KIND" "multi" || return 1
  assert_eq "${#PARSED_TARGETS[@]}" "2" || return 1
  [[ " ${PARSED_TARGETS[*]} " == *" laptop "* ]] || return 1
  [[ " ${PARSED_TARGETS[*]} " == *" server "* ]] || return 1
}

test_all_expands_to_reachable_only() {
  MACHINES=(workstation laptop server)
  THIS_MACHINE="laptop"
  CAN_SSH_TO="server"
  CAN_SSH_TO_ARR=(server)

  parse_endpoint "all:~/backup"
  assert_eq "$PARSED_KIND" "multi" || return 1
  assert_eq "${#PARSED_TARGETS[@]}" "1" || return 1
  assert_eq "${PARSED_TARGETS[0]}" "server" || return 1
}

test_parse_endpoint_unknown_prefix_fails() {
  local rc=0

  bash -c '
    set -euo pipefail
    source "$1"
    MACHINES=(workstation laptop server)
    THIS_MACHINE="workstation"
    parse_endpoint "lapto:/tmp"
  ' _ "$REPO_ROOT/src/xfer" >/dev/null 2>&1 || rc=$?

  [[ "$rc" -ne 0 ]]
}

test_flag_b64_roundtrip() {
  local encoded=""

  encoded="$(encode_flags_b64 --exclude "node modules" -ep dev --progress)"
  decode_flags_b64_to_array "$encoded" || return 1

  assert_eq "${#DECODED_FLAGS[@]}" "5" || return 1
  assert_eq "${DECODED_FLAGS[0]}" "--exclude" || return 1
  assert_eq "${DECODED_FLAGS[1]}" "node modules" || return 1
  assert_eq "${DECODED_FLAGS[2]}" "-ep" || return 1
  assert_eq "${DECODED_FLAGS[3]}" "dev" || return 1
  assert_eq "${DECODED_FLAGS[4]}" "--progress" || return 1
}

test_resolve_ssh_key_normalizes_home_tilde_segment() {
  local machine="laptop"
  laptop_ssh_key="$HOME/~/.ssh/laptop"
  local resolved=""

  resolved="$(resolve_ssh_key "$machine")"
  assert_eq "$resolved" "$HOME/.ssh/laptop" || return 1
}

test_resolve_ssh_key_expands_tilde_home() {
  local machine="laptop"
  laptop_ssh_key="~/.ssh/laptop"
  local resolved=""

  resolved="$(resolve_ssh_key "$machine")"
  assert_eq "$resolved" "$HOME/.ssh/laptop" || return 1
}

test_map_rsync_exit() {
  map_rsync_exit 0
  assert_eq "$MAPPED_STATUS" "OK" || return 1
  assert_eq "$MAPPED_EXIT" "0" || return 1

  map_rsync_exit 24
  assert_eq "$MAPPED_STATUS" "OK" || return 1
  assert_eq "$MAPPED_EXIT" "0" || return 1

  map_rsync_exit 23
  assert_eq "$MAPPED_STATUS" "PARTIAL" || return 1
  assert_eq "$MAPPED_EXIT" "23" || return 1

  map_rsync_exit 5
  assert_eq "$MAPPED_STATUS" "FAIL" || return 1
  assert_eq "$MAPPED_EXIT" "1" || return 1
}

test_parse_transfer_update_flag() {
  parse_transfer_args --update --exclude '*.tmp' ./src server:~/dst

  assert_eq "$UPDATE" "true" || return 1
  assert_eq "$SOURCE_ENDPOINT" "./src" || return 1
  assert_eq "$DEST_ENDPOINT" "server:~/dst" || return 1
  assert_eq "${#TRANSFER_RAW_FLAGS[@]}" "3" || return 1
  assert_eq "${TRANSFER_RAW_FLAGS[0]}" "--update" || return 1
}

test_parse_transfer_git_flag() {
  parse_transfer_args --git ./src server:~/dst

  assert_eq "$GIT_IGNORE" "true" || return 1
  assert_eq "$SOURCE_ENDPOINT" "./src" || return 1
  assert_eq "$DEST_ENDPOINT" "server:~/dst" || return 1
  contains_arg "--git" "${TRANSFER_RAW_FLAGS[@]}" || return 1
}

test_parse_transfer_git_flag_resets() {
  parse_transfer_args --git ./src server:~/dst
  assert_eq "$GIT_IGNORE" "true" || return 1

  parse_transfer_args ./src server:~/dst
  assert_eq "$GIT_IGNORE" "false" || return 1
  contains_arg "--git" "${TRANSFER_RAW_FLAGS[@]}" && return 1
  return 0
}

test_gitignore_negation_errors() {
  local rc=0
  bash -c '
    set -euo pipefail
    source "$1"
    printf "!keep.txt\n" | gitignore_write_exclude_file_from_stdin >/dev/null
  ' _ "$REPO_ROOT/src/xfer" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]]
}

test_gitignore_escaped_bang_allowed() {
  local out=""
  out="$(bash -c '
    set -euo pipefail
    source "$1"
    printf "\\\\!keep.txt\n" | gitignore_write_exclude_file_from_stdin
  ' _ "$REPO_ROOT/src/xfer")"
  [[ -n "$out" ]] || return 1
  [[ -f "$out" ]] || return 1
  grep -q '^\\!keep.txt$' "$out" || return 1
}

test_gitignore_hash_comment_and_escaped_hash() {
  local out=""
  out="$(bash -c '
    set -euo pipefail
    source "$1"
    printf "# comment\\n\\\\#literal\\n" | gitignore_write_exclude_file_from_stdin
  ' _ "$REPO_ROOT/src/xfer")"
  [[ -n "$out" ]] || return 1
  [[ -f "$out" ]] || return 1
  grep -q '^\\#literal$' "$out" || return 1
  if grep -q '^# comment$' "$out"; then
    return 1
  fi
}

test_gitignore_crlf_negation_errors() {
  local rc=0
  bash -c '
    set -euo pipefail
    source "$1"
    printf "!keep.txt\\r\\n" | gitignore_write_exclude_file_from_stdin >/dev/null
  ' _ "$REPO_ROOT/src/xfer" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]]
}

test_build_rsync_cmd_git_exclude_from() {
  local tmp_dir=""
  local git_exclude=""

  tmp_dir="$(mktemp -d)"
  EXCLUDE_PROFILES_DIR="$tmp_dir/exclude-profiles"
  mkdir -p "$EXCLUDE_PROFILES_DIR"

  MACHINES=(workstation laptop server)
  laptop_user="u"
  laptop_ip="100.0.0.2"
  laptop_ssh_key=""

  RSYNC_DEFAULT_FLAGS="-a --protect-args"
  DRY_RUN=true
  QUIET=false
  NO_PROGRESS=false
  UPDATE=false
  GIT_IGNORE=true
  EXCLUDES=()
  EXCLUDE_PROFILES=()

  printf '*.tmp\n' > "$tmp_dir/.gitignore"
  git_exclude="$(gitignore_prepare_exclude_file_local "$tmp_dir/.gitignore")" || { rm -rf "$tmp_dir"; return 1; }
  [[ -n "$git_exclude" ]] || { rm -rf "$tmp_dir"; return 1; }
  GIT_EXCLUDE_FROM_FILE="$git_exclude"

  build_rsync_cmd "laptop" "/tmp/src" "u@100.0.0.2:/tmp/dst"

  contains_arg "--exclude-from=$git_exclude" "${BUILT_CMD[@]}" || { rm -rf "$tmp_dir"; return 1; }
  contains_arg "--filter=:- .gitignore" "${BUILT_CMD[@]}" && { rm -rf "$tmp_dir"; return 1; }
  contains_arg "--exclude=.git" "${BUILT_CMD[@]}" && { rm -rf "$tmp_dir"; return 1; }

  rm -rf "$tmp_dir"
}

test_remote_pull_gitignore_fetch_and_exclude_from() {
  local tmp_dir=""
  local cfg=""
  local rc=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin" "$tmp_dir/conf" "$tmp_dir/data" "$tmp_dir/dst"

  cat > "$tmp_dir/bin/ssh" <<'SSH'
#!/usr/bin/env bash
printf "*.tmp\n"
exit 0
SSH
  chmod +x "$tmp_dir/bin/ssh"

  cat > "$tmp_dir/bin/rsync" <<'RSYNC'
#!/usr/bin/env bash
set -euo pipefail
capture="${RSYNC_CAPTURE:-/tmp/rsync_capture}"
printf '%s\n' "$@" > "${capture}.args"
for arg in "$@"; do
  case "$arg" in
    --exclude-from=*)
      f="${arg#--exclude-from=}"
      cp "$f" "${capture}.exclude"
      ;;
  esac
done
exit 0
RSYNC
  chmod +x "$tmp_dir/bin/rsync"

  cfg="$tmp_dir/conf/config"
  cat > "$cfg" <<CFG
MACHINES=(workstation laptop)
workstation_user="a"
workstation_ip="127.0.0.2"
workstation_ssh_key=""
laptop_user="l"
laptop_ip="127.0.0.3"
laptop_ssh_key=""
THIS_MACHINE="workstation"
CAN_SSH_TO="laptop"
DATA_DIR="$tmp_dir/data"
RSYNC_DEFAULT_FLAGS="-a --protect-args"
CFG
  chmod 600 "$cfg"

  PATH="$tmp_dir/bin:$PATH" RSYNC_CAPTURE="$tmp_dir/rsync" "$REPO_ROOT/src/xfer" --config "$cfg" --dry-run --git laptop:~/repo "$tmp_dir/dst" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || { rm -rf "$tmp_dir"; return 1; }

  grep -q -- "--exclude-from=" "$tmp_dir/rsync.args" || { rm -rf "$tmp_dir"; return 1; }
  grep -Fxq "*.tmp" "$tmp_dir/rsync.exclude" || { rm -rf "$tmp_dir"; return 1; }
  if grep -q -- "--exclude=.git" "$tmp_dir/rsync.args"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  rm -rf "$tmp_dir"
}

test_remote_pull_gitignore_negation_aborts_before_rsync() {
  local tmp_dir=""
  local cfg=""
  local rc=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin" "$tmp_dir/conf" "$tmp_dir/data" "$tmp_dir/dst"

  cat > "$tmp_dir/bin/ssh" <<'SSH'
#!/usr/bin/env bash
printf "!bad.txt\n"
exit 0
SSH
  chmod +x "$tmp_dir/bin/ssh"

  cat > "$tmp_dir/bin/rsync" <<'RSYNC'
#!/usr/bin/env bash
set -euo pipefail
capture="${RSYNC_CAPTURE:-/tmp/rsync_capture}"
printf '%s\n' "$@" > "${capture}.args"
exit 0
RSYNC
  chmod +x "$tmp_dir/bin/rsync"

  cfg="$tmp_dir/conf/config"
  cat > "$cfg" <<CFG
MACHINES=(workstation laptop)
workstation_user="a"
workstation_ip="127.0.0.2"
workstation_ssh_key=""
laptop_user="l"
laptop_ip="127.0.0.3"
laptop_ssh_key=""
THIS_MACHINE="workstation"
CAN_SSH_TO="laptop"
DATA_DIR="$tmp_dir/data"
RSYNC_DEFAULT_FLAGS="-a --protect-args"
CFG
  chmod 600 "$cfg"

  PATH="$tmp_dir/bin:$PATH" RSYNC_CAPTURE="$tmp_dir/rsync" "$REPO_ROOT/src/xfer" --config "$cfg" --dry-run --git laptop:~/repo "$tmp_dir/dst" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { rm -rf "$tmp_dir"; return 1; }
  [[ ! -f "$tmp_dir/rsync.args" ]] || { rm -rf "$tmp_dir"; return 1; }

  rm -rf "$tmp_dir"
}

test_help_handlers() {
  local out=""

  out="$(cmd_history --help)"
  [[ "$out" == *"xfer history"* ]] || return 1

  out="$(cmd_last --help)"
  [[ "$out" == *"xfer last"* ]] || return 1

  out="$(cmd_undo --help)"
  [[ "$out" == *"xfer undo"* ]] || return 1
}

test_missing_profile_lists_available() {
  local tmp_dir=""
  local rc=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/exclude-profiles"
  printf '.git\n' > "$tmp_dir/exclude-profiles/dev"
  printf '*.mp4\n' > "$tmp_dir/exclude-profiles/media"

  bash -c '
    set -euo pipefail
    source "$1"
    EXCLUDE_PROFILES_DIR="$2/exclude-profiles"
    EXCLUDE_PROFILES=(missing)
    EXCLUDES=()
    RSYNC_DEFAULT_FLAGS="-a --protect-args"
    DRY_RUN=true
    UPDATE=false
    QUIET=false
    NO_PROGRESS=false
    build_rsync_cmd "" "/tmp/src" "/tmp/dst"
  ' _ "$REPO_ROOT/src/xfer" "$tmp_dir" >"$tmp_dir/out" 2>&1 || rc=$?

  [[ "$rc" -ne 0 ]] || { rm -rf "$tmp_dir"; return 1; }
  grep -q "Available profiles: dev media" "$tmp_dir/out" || { rm -rf "$tmp_dir"; return 1; }

  rm -rf "$tmp_dir"
}

test_print_diff_item_line_colors() {
  local out=""

  C_GREEN="<g>"
  C_YELLOW="<y>"
  C_RED="<r>"
  C_RESET="</>"

  out="$(print_diff_item_line ">f+++++++ foo.txt")"
  assert_eq "$out" "<g>>f+++++++ foo.txt</>" || return 1

  out="$(print_diff_item_line ">f..t.... foo.txt")"
  assert_eq "$out" "<y>>f..t.... foo.txt</>" || return 1
}

test_doctor_help() {
  local out=""
  out="$(cmd_doctor --help)"
  [[ "$out" == *"xfer doctor"* ]] || return 1
}

test_docter_alias_help() {
  local out=""
  out="$("$REPO_ROOT/src/xfer" docter --help)"
  [[ "$out" == *"xfer doctor"* ]] || return 1
}

test_doc_alias_help() {
  local out=""
  out="$("$REPO_ROOT/src/xfer" doc --help)"
  [[ "$out" == *"xfer doctor"* ]] || return 1
}

test_doctor_fix_yes_creates_local_artifacts() {
  local tmp_dir=""
  local cfg=""
  local rc=0
  local mode=""

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin" "$tmp_dir/conf"

  cat > "$tmp_dir/bin/ssh" <<'SSH'
#!/usr/bin/env bash
exit 0
SSH
  chmod +x "$tmp_dir/bin/ssh"

  cfg="$tmp_dir/conf/config"
  cat > "$cfg" <<CFG
MACHINES=(workstation laptop server)
workstation_user="a"
workstation_ip="127.0.0.2"
workstation_ssh_key=""
laptop_user="l"
laptop_ip="127.0.0.3"
laptop_ssh_key=""
server_user="d"
server_ip="127.0.0.4"
server_ssh_key=""
THIS_MACHINE="laptop"
CAN_SSH_TO="server"
DATA_DIR="$tmp_dir/data"
RSYNC_DEFAULT_FLAGS="-a --protect-args"
CFG
  chmod 644 "$cfg"

  PATH="$tmp_dir/bin:$PATH" "$REPO_ROOT/src/xfer" --config "$cfg" doctor --fix --yes >"$tmp_dir/out" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || { rm -rf "$tmp_dir"; return 1; }

  [[ -d "$tmp_dir/conf/bookmarks" ]] || { rm -rf "$tmp_dir"; return 1; }
  [[ -d "$tmp_dir/conf/exclude-profiles" ]] || { rm -rf "$tmp_dir"; return 1; }
  [[ -f "$tmp_dir/conf/exclude-profiles/dev" ]] || { rm -rf "$tmp_dir"; return 1; }
  [[ -f "$tmp_dir/conf/exclude-profiles/media" ]] || { rm -rf "$tmp_dir"; return 1; }
  [[ -f "$tmp_dir/data/history.log" ]] || { rm -rf "$tmp_dir"; return 1; }

  mode="$(stat -c '%a' "$cfg")"
  [[ "$mode" == "600" ]] || { rm -rf "$tmp_dir"; return 1; }

  rm -rf "$tmp_dir"
}

test_doctor_fails_on_unreachable_ssh() {
  local tmp_dir=""
  local cfg=""
  local rc=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin" "$tmp_dir/conf/bookmarks" "$tmp_dir/conf/exclude-profiles" "$tmp_dir/data"

  printf '.git\n' > "$tmp_dir/conf/exclude-profiles/dev"
  printf '*.mp4\n' > "$tmp_dir/conf/exclude-profiles/media"
  : > "$tmp_dir/data/history.log"

  cat > "$tmp_dir/bin/ssh" <<'SSH'
#!/usr/bin/env bash
if [[ "$*" == *" true" ]]; then
  exit 255
fi
exit 0
SSH
  chmod +x "$tmp_dir/bin/ssh"

  cfg="$tmp_dir/conf/config"
  cat > "$cfg" <<CFG
MACHINES=(workstation laptop server)
workstation_user="a"
workstation_ip="127.0.0.2"
workstation_ssh_key=""
laptop_user="l"
laptop_ip="127.0.0.3"
laptop_ssh_key=""
server_user="d"
server_ip="127.0.0.4"
server_ssh_key=""
THIS_MACHINE="laptop"
CAN_SSH_TO="server"
DATA_DIR="$tmp_dir/data"
RSYNC_DEFAULT_FLAGS="-a --protect-args"
CFG
  chmod 600 "$cfg"

  PATH="$tmp_dir/bin:$PATH" "$REPO_ROOT/src/xfer" --config "$cfg" doctor >"$tmp_dir/out" 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { rm -rf "$tmp_dir"; return 1; }
  grep -q "ssh unreachable: server" "$tmp_dir/out" || { rm -rf "$tmp_dir"; return 1; }

  rm -rf "$tmp_dir"
}

test_build_rsync_cmd_filters_progress() {
  local tmp_dir=""

  tmp_dir="$(mktemp -d)"
  EXCLUDE_PROFILES_DIR="$tmp_dir/exclude-profiles"
  mkdir -p "$EXCLUDE_PROFILES_DIR"
  printf '.git\n' > "$EXCLUDE_PROFILES_DIR/dev"

  MACHINES=(workstation laptop server)
  laptop_user="u"
  laptop_ip="100.0.0.2"
  laptop_ssh_key=""

  RSYNC_DEFAULT_FLAGS="-a -v -z --progress --partial --human-readable --protect-args"
  DRY_RUN=true
  QUIET=false
  NO_PROGRESS=true
  UPDATE=false
  GIT_IGNORE=false
  GIT_EXCLUDE_FROM_FILE=""
  EXCLUDES=("node_modules")
  EXCLUDE_PROFILES=("dev")

  build_rsync_cmd "laptop" "/tmp/src" "u@100.0.0.2:/tmp/dst"

  contains_arg "--progress" "${BUILT_CMD[@]}" && return 1
  contains_arg "--dry-run" "${BUILT_CMD[@]}" || return 1
  contains_arg "--protect-args" "${BUILT_CMD[@]}" || return 1
  contains_arg "--exclude=node_modules" "${BUILT_CMD[@]}" || return 1
  contains_arg "--exclude-from=$EXCLUDE_PROFILES_DIR/dev" "${BUILT_CMD[@]}" || return 1

  rm -rf "$tmp_dir"
}

run_test "parse endpoint basics" test_parse_endpoint_basics
run_test "all expands to reachable machines only" test_all_expands_to_reachable_only
run_test "unknown machine prefix fails" test_parse_endpoint_unknown_prefix_fails
run_test "flags b64 roundtrip" test_flag_b64_roundtrip
run_test "ssh key path normalization" test_resolve_ssh_key_normalizes_home_tilde_segment
run_test "ssh key tilde expansion" test_resolve_ssh_key_expands_tilde_home
run_test "rsync exit mapping" test_map_rsync_exit
run_test "transfer --update parsing" test_parse_transfer_update_flag
run_test "transfer --git parsing" test_parse_transfer_git_flag
run_test "transfer --git resets" test_parse_transfer_git_flag_resets
run_test ".gitignore negation errors" test_gitignore_negation_errors
run_test ".gitignore escaped bang allowed" test_gitignore_escaped_bang_allowed
run_test ".gitignore hash comment and escaped hash" test_gitignore_hash_comment_and_escaped_hash
run_test ".gitignore CRLF negation errors" test_gitignore_crlf_negation_errors
run_test "build rsync cmd includes git exclude-from" test_build_rsync_cmd_git_exclude_from
run_test "remote pull gitignore fetch" test_remote_pull_gitignore_fetch_and_exclude_from
run_test "remote pull gitignore negation aborts" test_remote_pull_gitignore_negation_aborts_before_rsync
run_test "history/last/undo help handlers" test_help_handlers
run_test "exclude profile error lists available profiles" test_missing_profile_lists_available
run_test "diff item color mapping" test_print_diff_item_line_colors
run_test "doctor help" test_doctor_help
run_test "docter alias help" test_docter_alias_help
run_test "doc alias help" test_doc_alias_help
run_test "doctor --fix --yes creates local artifacts" test_doctor_fix_yes_creates_local_artifacts
run_test "doctor fails on unreachable ssh" test_doctor_fails_on_unreachable_ssh
run_test "build rsync cmd" test_build_rsync_cmd_filters_progress

printf '\nTests: %d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -ne 0 ]]; then
  exit 1
fi
