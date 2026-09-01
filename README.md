# xfer

A bash CLI tool that wraps rsync to transfer files between machines over Tailscale, with smart SSH routing, multi-target broadcast, bookmarks, and transfer history.

## Features

- **Push & pull** files between machines with a simple `machine:path` syntax
- **Multi-target broadcast** — send to all machines at once with `all:path`
- **Transfer history** — view, replay (`last`), or reverse (`undo`) past transfers
- **Bookmarks** — save and re-run frequent transfers by name
- **Remote ls** — list files on remote machines without leaving the terminal
- **Diff mode** — compare local and remote directories before syncing
- **Exclude profiles** — named exclude lists (`dev`, `media`) for common patterns
- **Safe by design** — array-based command construction, `--protect-args`, no `eval`, no `source` on user data

## Quick Start

```bash
git clone https://github.com/cheesecake-mainframe/xfer.git
cd xfer
./install.sh
```

The installer prompts for your machine names and SSH targets, then auto-detects SSH config (`ssh -G`) to pre-fill IPs, users, and keys.

## Usage

```bash
# Push to a remote machine
xfer ./project server:~/projects/

# Pull from a remote machine
xfer laptop:~/notes/ ./notes/

# Broadcast to all reachable machines
xfer ./dotfiles all:~/dotfiles

# Broadcast to specific machines
xfer ./config laptop,server:~/config

# Dry run
xfer --dry-run ./project server:~/projects/

# Exclude common dev artifacts
xfer --exclude-profile dev ./repo server:~/repo

# Combine exclude profiles
xfer -ep dev -ep media ./mixed laptop:~/mixed
```

## Subcommands

| Command | Description |
|---------|-------------|
| `xfer ls server:~/path` | List files on a remote machine |
| `xfer diff ./local server:~/remote` | Compare two locations (shows what would sync) |
| `xfer history [N]` | Show last N transfers (default: 10) |
| `xfer last` | Replay the most recent transfer |
| `xfer undo` | Reverse sync the most recent successful transfer |
| `xfer bookmark save <name> <src> <dst>` | Save a transfer as a bookmark |
| `xfer bookmark run <name>` | Run a saved bookmark |
| `xfer bookmark list` | List all bookmarks |
| `xfer bookmark delete <name>` | Delete a bookmark |

## Flags

| Flag | Short | Description |
|------|-------|-------------|
| `--dry-run` | `-n` | Show what would transfer without doing it |
| `--git` | | Exclude patterns from top-level `.gitignore` only (no nested; `!` errors) |
| `--exclude <pattern>` | | Exclude matching files (repeatable) |
| `--exclude-profile <name>` | `-ep` | Use a named exclude profile |
| `--progress` / `--no-progress` | | Toggle progress display (default: on for TTY) |
| `--verbose` | `-v` | Show the rsync command being executed |
| `--quiet` | `-q` | Suppress output except errors |
| `--help` | `-h` | Show usage |
| `--version` | | Print version |
| `--config <path>` | | Use an alternate config file |

## Network Topology Example

```
workstation ──SSH──> laptop    (tailscale)
workstation ──SSH──> server    (tailscale)
laptop      <-SSH--> server   (tailscale, bidirectional)
laptop      --X--> workstation (blocked)
server      --X--> workstation (blocked)
```

xfer is installed on each machine with its own config. Each machine can only push/pull to machines it can SSH into. Remote-to-remote transfers are not supported.

## Prerequisites

- Linux on all hosts
- bash 4+
- rsync 3.x
- SSH with key-based auth (no password prompts)
- Tailscale with stable IPs
- flock, base64

## Configuration

Config lives at `~/.config/xfer/config` (created by the installer):

```bash
MACHINES=(workstation laptop server)

laptop_user="alice"
laptop_ip="100.64.0.2"
laptop_ssh_key="~/.ssh/id_ed25519"

server_user="bob"
server_ip="100.64.0.3"
server_ssh_key="~/.ssh/id_ed25519"

THIS_MACHINE="workstation"
CAN_SSH_TO="laptop server"
RSYNC_DEFAULT_FLAGS="-a -v -z --progress --partial --human-readable --protect-args"
```

## Built-in Exclude Profiles

**dev** — `node_modules`, `.git`, `__pycache__`, `.venv`, `*.pyc`, `dist`, `build`, `.next`, `.cache`, `.tox`, `*.egg-info`

**media** — `*.mp4`, `*.mkv`, `*.avi`, `*.mov`, `*.iso`, `*.zip`, `*.tar.gz`, `*.rar`

Custom profiles can be added as plain text files in `~/.config/xfer/exclude-profiles/`.

## Uninstall

```bash
./uninstall.sh          # removes binary, keeps config/history
./uninstall.sh --purge  # removes everything
```

## License

[MIT](LICENSE)
