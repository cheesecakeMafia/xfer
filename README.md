# xfer

A bash CLI tool that wraps rsync to transfer files between machines over Tailscale, with smart SSH routing, multi-target broadcast, bookmarks, and transfer history.

## Features

- **Push & pull** files between machines with a simple `machine:path` syntax
- **Multi-target broadcast** — send to all machines at once with `all:path`
- **Transfer history** — view, replay (`last`), or reverse (`undo`) past transfers
- **Bookmarks** — save and re-run frequent transfers by name
- **Remote ls** — list files on remote machines without leaving the terminal
- **Diff mode** — compare local and remote directories before syncing
- **Mirror mode** — make a destination match its source exactly, behind four safety guards
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
| `--mirror` | | Make the destination match the source, deleting extras ([see below](#mirror-mode)) |
| `--max-delete <n>` | | Ceiling on `--mirror` deletions (default: `MIRROR_MAX_DELETE`, 5000) |
| `--delete-excluded` | | With `--mirror`, also delete destination paths matched by `--exclude`/`-ep` |
| `--yes` | `-y` | Skip the mirror confirmation prompt (required when not on a TTY) |
| `--verbose` | `-v` | Show the rsync command being executed |
| `--quiet` | `-q` | Suppress output except errors |
| `--help` | `-h` | Show usage |
| `--version` | | Print version |
| `--config <path>` | | Use an alternate config file |

## Mirror Mode

`--mirror` makes the destination match the source exactly. Files at the destination
that no longer exist at the source are **deleted outright** — there is no attic and
no undo. It is intended for backups, where drift between source and backup is the
problem being solved.

```bash
# Mirror a directory to a backup host
xfer --mirror ~/Documents server:~/backup/

# Preview first — --dry-run never deletes and never prompts
xfer --mirror --dry-run ~/Documents server:~/backup/

# Unattended (cron, systemd timer): --yes is required off a TTY
xfer --mirror --yes --no-progress ~/Documents server:~/backup/

# Raise the deletion ceiling for a run you know is a big cleanup
xfer --mirror --max-delete 20000 ~/Documents server:~/backup/
```

### Guards

Because a mirror can destroy data, `--mirror` refuses several things by default:

| Guard | Behaviour | Override |
|---|---|---|
| Contents-copy source | Refuses a source naming a directory's *contents* rather than the directory — `dir/`, `.`, `dir/.`, `machine:~`, `machine:` | `--yes` |
| Broadcast destination | Refuses `all:` and `m1,m2:` destinations | **none** |
| Preview and confirm | Lists what would be deleted and asks; refuses to run unattended | `--yes` |
| Deletion ceiling | Aborts if more than `--max-delete` items would go | `--max-delete <n>` |

The contents-copy guard exists because a single trailing slash changes the meaning
of a mirror completely:

```bash
xfer --mirror ~/Documents server:~/backup/    # -> server:~/backup/Documents
xfer --mirror ~/Documents/ server:~/backup/   # -> server:~/backup/ matches Documents
                                              #    DELETING everything else in backup/
```

The ceiling is the backstop for the cases no string check can catch — an unmounted
source, a mistyped path, a directory that is unexpectedly empty. When the preview
sees the ceiling would be reached, xfer refuses to start the run at all, so nothing
is deleted.

Be aware of what the ceiling does at the rsync level, though: `--max-delete=N` means
*delete up to N, then stop* — not *abort before deleting*. Only `--max-delete=0`
deletes nothing. That is why the preview, not the ceiling, is the guard that keeps a
mirror from over-deleting. If a real run ever does exit 25 (the preview and the run
disagreeing about the file list), xfer reports `status=ABORTED` and tells you that
some deletions may already have been applied.

To close that gap, once you confirm the preview xfer lowers the ceiling for the real
run to exactly the number of deletions it showed you. Files that become extraneous
between the preview and the run therefore cannot be deleted beyond what you approved.

### Replay safety

- `xfer undo` never mirrors. Undo reverse-syncs, so replaying a mirror backwards
  would delete the original source; the mirror flags are stripped first.
- `xfer last` and `xfer bookmark run` keep `--mirror` but drop a stored `--yes`,
  so a replayed mirror always previews and asks again.

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

# Ceiling on how many items a single --mirror run may delete before aborting.
# Optional; defaults to 5000 when absent.
MIRROR_MAX_DELETE="5000"
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
