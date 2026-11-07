Readme · MD
# deploy-uno-q.sh
 
Post-flash provisioning script for Arduino UNO Q boards. Run it once after
flashing (or reflashing) a board and it brings the board up to a standard,
working lab image — display fixed, shortcuts sane, shell configured,
tools installed, sudo passwordless — instead of clicking through the same
manual setup every time. Two opt-in stages go further when you ask for
them: Home Assistant with a Matter server in Docker, and merging the
board's split eMMC partitions into one root filesystem.
 
Every stage checks its own work first and skips anything already applied,
so running the whole script again (or any subset of it) on an
already-provisioned board is always safe and fast.
 
## Contents
 
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Stages](#stages)
- [Options](#options)
- [Examples](#examples)
- [Home Assistant](#home-assistant)
- [Merging the partitions](#merging-the-partitions)
- [Why some of this exists](#why-some-of-this-exists)
- [Extending it](#extending-it)
- [Known things worth knowing](#known-things-worth-knowing)
## Requirements
 
- **Run as your normal desktop user — not root, not via `sudo`.** The
  script calls `sudo` itself wherever it needs privilege. Running the
  whole thing under `sudo` breaks the XFCE part of `display-fix`, which
  needs your real desktop session (DBus, `xfconf`) to seed display
  settings correctly.
- **Run it from a terminal inside the logged-in XFCE desktop**, not over
  SSH, so `display-fix` can seed the XFCE display profile as well as the
  greeter-level fix. Over SSH the greeter-level part still installs fine;
  re-run with `--only display-fix` from the desktop afterwards to finish
  the rest.
- `home-assistant` and `merge-partitions` don't need the desktop and run
  fine over SSH. `merge-partitions` does need an **interactive terminal**:
  it asks you to type `yes` before it deletes the userdata partition.
- `home-assistant` needs Docker Engine 23.0 or later with the compose
  plugin. The UNO Q image ships both (App Lab runs its bricks in
  containers); the stage checks for them but never installs Docker itself.
- Debian (this is written and tested against the UNO Q's Debian trixie
  image specifically).
## Quick start
 
```bash
git clone <this-repo-url>
cd <this-repo>
chmod +x deploy-uno-q.sh
./deploy-uno-q.sh
```
 
That runs every default stage, in order. The two opt-in stages are left
out unless you ask for them (`--ha`, `--part`). To see what's available
first:
 
```bash
./deploy-uno-q.sh --list
```
 
## Stages
 
Stages run in this order by default. Skip or select individual ones with
`--only`/`--skip`, or use the shorthand flags where available.
 
| # | Stage | Flag | What it does |
|---|-------|------|---------------|
| 1 | `display-fix` | `--screen` | Forces 1920×1080@60 on `DP-1`, both at the greeter (a polling `systemd` service) and inside the XFCE session (seeded `xfconf` display profile) — two independent fixes for the UNO Q's ANX7625 DSI-to-DisplayPort bridge, which doesn't always negotiate EDID reliably through a hub. |
| 2 | `xfce-shortcuts` | `--keyboard` | Migrates the window-tiling shortcuts from `Super`+*numpad arrow* to `Super`+*arrow*. Discovers whatever command is currently bound to each key live via `xfconf-query` and moves it, rather than hardcoding values — correct regardless of what's actually bound on a given flash. |
| 3 | `zsh` | — | Installs `zsh` + `zsh-autosuggestions` + `zsh-syntax-highlighting`, sets it as the login shell, deploys `.zshrc`. |
| 4 | `motd` | — | Installs the lab's `/etc/motd` banner. |
| 5 | `tools` | `--apps` | `apt update && full-upgrade` (kernel included — this board only tracks Arduino-provided repos, so a kernel bump here is an Arduino release, not an untested swap from a generic mirror), plus `fastfetch`, `sysbench`, `btop`, `flashrom`, and the Ookla Speedtest CLI. |
| 6 | `sudo` | — | Passwordless `sudo` for the invoking user, via a `/etc/sudoers.d/` drop-in that's syntax-validated with `visudo -c` *before* it's ever installed. |
| 7 | `github-ssh` | `--github-ssh` | Generates (or reuses) an `ed25519` SSH key for this board and prints the public key with the steps to add it to GitHub. Never touches GitHub itself — registering the key is always a manual step. Safe to re-run any time just to get the public key back on screen. |
 
### Opt-in stages
 
These never run as part of a plain run or a `--skip` run — only when
selected with their flag or named in `--only`.
 
| # | Stage | Flag | What it does |
|---|-------|------|---------------|
| 8 | `home-assistant` | `--ha` | Home Assistant Container plus the matter.js Matter server, as one Docker Compose project in `~/homeassistant`, with the Matter API reachable on loopback only. See [Home Assistant](#home-assistant). |
| 9 | `merge-partitions` | `--part` | Folds the separate `userdata` partition (`/home/arduino`) into `rootfs`, so the whole eMMC is one root filesystem. Destructive and spread over two reboots: each run works out where the board is and does the next phase. Always runs last. See [Merging the partitions](#merging-the-partitions). |
 
## Options
 
```
Usage: deploy-uno-q.sh [OPTIONS]
 
  -l, --list            List available stages and exit
  -o, --only LIST       Run only these stages, comma-separated ids
  -s, --skip LIST       Skip these stages, comma-separated ids
      --screen          Run just the display-fix stage
      --keyboard        Run just the xfce-shortcuts stage
      --apps            Run just the tools (package installation) stage
      --github-ssh      Run just the github-ssh stage
      --ha              Run just the home-assistant stage (opt-in)
      --part            Run the next phase of merge-partitions (opt-in,
                        destructive -- see stage_merge_partitions())
  -h, --help            Show this help and exit
```
 
`--screen`, `--keyboard`, `--apps`, `--github-ssh`, `--ha`, and `--part`
can be combined with each other (and with `--only`/`--skip`) to run more
than one stage in a single pass. Stages always run in the order of the
tables above, whatever order the flags are given in.
 
## Examples
 
```bash
./deploy-uno-q.sh                     # every default stage, in order
./deploy-uno-q.sh --list              # see what's available
./deploy-uno-q.sh --only zsh          # just one stage
./deploy-uno-q.sh --skip motd,tools   # every default stage except these
./deploy-uno-q.sh --screen --apps     # combine flags to run several stages
./deploy-uno-q.sh --only sudo         # one-time: passwordless sudo setup
./deploy-uno-q.sh --github-ssh        # generate/print this board's GitHub key
./deploy-uno-q.sh --ha                # install Home Assistant + the Matter server
./deploy-uno-q.sh --part              # next phase of the partition merge
```
 
## Home Assistant
 
`--ha` sets up Home Assistant Container and the Open Home Foundation's
Matter server (the matter.js one, `ghcr.io/matter-js/matterjs-server`) as
a single Docker Compose project:
 
```
~/homeassistant/
├── compose.yaml   # generated by the stage
├── config/        # Home Assistant's configuration and database
└── matter/        # Matter fabric data
```
 
What the stage does, in order:
 
1. Checks Docker Engine (23.0+) and the compose plugin are there.
2. Finds the LAN interface from the default route, and warns if it has no
   IPv6 link-local address (Matter needs IPv6). On a kernel with pages
   larger than 4K it also disables HA's jemalloc allocator, which fails
   there.
3. Writes `compose.yaml` (only if its content changed, keeping a
   timestamped backup) and validates it.
4. Before a first pull, checks there's about 4 GB free under Docker's data
   root — the two images came to roughly 3.3 GB on a 4 GB board.
5. Checks ports 8123 and 5580 are free or already held by these
   containers, then starts both with `docker compose up -d`.
6. Waits for the web UI to answer (first boot takes a few minutes on the
   A53 cores) and confirms the Matter server is listening on
   `127.0.0.1:5580` only — the stage fails if it's reachable from the LAN.
Then finish in the browser:
 
- Onboarding: `http://<board-ip>:8123`
- **Settings → Devices & services → Add integration → Matter**, with the
  URL `ws://127.0.0.1:5580/ws`. Use `127.0.0.1`, not `localhost`: inside
  the container `localhost` can resolve to `::1` first, which the
  IPv4-only listener won't answer.
- The Matter server's own dashboard isn't on the LAN any more. Reach it
  from your PC through an SSH tunnel:
  `ssh -L 5580:127.0.0.1:5580 arduino@<board-ip>`, then open
  `http://localhost:5580`.
Re-running `--ha` changes nothing once everything is up. It never updates
images on its own; to update:
 
```bash
cd ~/homeassistant && docker compose pull && docker compose up -d && docker image prune -f
```
 
`docker image prune -f` without `-a` removes only the untagged image the
update just replaced, so App Lab's brick images are left alone.
 
The time zone (`HA_TZ`, default `Europe/Kyiv` — the board's own clock
runs in UTC) and the interface override (`HA_IFACE`) are tunables at the
top of `stage_home_assistant()`.
 
## Merging the partitions
 
Arduino's image splits the eMMC into a fixed `rootfs` and a separate
`userdata` partition mounted at `/home/arduino`. Docker images live on
root, so root fills up while free space sits stranded on the other half.
`--part` merges the two: home moves onto root, `userdata` is deleted, and
`rootfs` grows over its space.
 
**The trade-off:** `arduino-flasher-cli --preserve-user` can't work on a
merged board, because there's no user partition left to preserve. Any
future reflash is a full wipe that restores Arduino's layout, so back up
`~/homeassistant` (and anything else in home) before reflashing.
 
Run `./deploy-uno-q.sh --part` three times, rebooting between runs. Each
run reads the partition table, works out where the board is, and does
only the next phase:
 
| Run | Board state it finds | What it does | Then |
|-----|----------------------|--------------|------|
| 1 | `userdata` still mounted at `/home/arduino` | Stops Docker, copies home onto `rootfs` (two `rsync` passes plus a dry-run verify), comments out the `/home/arduino` line in `/etc/fstab` | Reboot |
| 2 | `userdata` present but no longer mounted | Asks you to type `yes`, backs up the partition table, deletes `userdata`, grows `rootfs` to the end of the disk | Reboot |
| 3 | No `userdata`, `rootfs` reaches the end of the disk | Grows the filesystem if it doesn't fill the partition yet, masks `debos-grow-rootfs` | Done |
 
Run it again after that and it just confirms everything and changes
nothing. Running it early (before a reboot it asked for) tells you to
reboot rather than doing anything.
 
Safety nets:
 
- **It only touches the layout it was written for.** It finds partitions
  by GPT name (`rootfs`, `userdata`) and by what `/` is mounted from,
  never by number, and refuses unless `userdata` starts right after
  `rootfs` and is the last partition on the disk.
- **Nothing is deleted until the copy is verified.** If something keeps
  writing to home during the copy, it stops instead; re-running resumes
  the copy where it left off.
- **Run 1 is reversible.** To back out before run 2:
  `sudo cp -a /etc/fstab.pre-merge /etc/fstab && sudo reboot`.
- **Every partition-table write is checked and can roll back.** The table
  is backed up to `~/.uno-q-deploy/logs/gpt-pre-*.sfdisk` before each
  write, then read back afterwards. If `rootfs` changed anything but its
  size (start sector, GUID, name, type, attributes) or doesn't end on the
  disk's last sector, the backup is restored and the stage stops.
## Why some of this exists
 
A couple of decisions here aren't obvious from the flag names alone:
 
- **`tools` upgrades the kernel.** Earlier versions of this script held
  kernel packages back during `full-upgrade`, after a kernel bump
  coincided with a boot loop / blank-screen episode on this board. That
  hold was removed because this lab only tracks Arduino-provided repos —
  a kernel update here is a tested Arduino release, not a random generic
  Debian swap, so there's no good reason to keep it separate from the
  rest of the upgrade. `tools` still prints a plain heads-up whenever a
  given run's upgrade includes a kernel version change, so it's the
  first thing you think of if display or hardware behavior looks
  different afterward.
- **`sudo` grants full passwordless access, deliberately.** This is
  written for a single-technician, physically-controlled lab board, not
  a shared or internet-facing system — anyone with physical access to a
  board here can already do far more than "run a command as root." If
  you reuse this script on a different kind of deployment, reconsider
  this stage specifically (or just `--skip sudo`).
- **`xfce-shortcuts` doesn't hardcode key bindings.** It reads whatever's
  currently bound to the keypad-arrow shortcuts and moves it, rather
  than asserting fixed values — safer than transcribing bindings by hand
  and correct even if a future image ships slightly different defaults.
- **`github-ssh` generates a passphrase-free key, on purpose.** Same
  reasoning as the `sudo` stage: a single-technician, physically
  controlled board, where a passphrase prompt on every `git fetch`
  is friction without a matching benefit. Only the public key is ever
  printed or logged — the private key is never displayed or sent
  anywhere by this script.
- **`home-assistant` and `merge-partitions` are opt-in.** Not every lab
  board needs Home Assistant, and a partition merge is the one thing in
  here you can't undo. `merge-partitions` also always runs last, so any
  other stage in the same run writes into home *before* home is copied,
  not into a partition that's about to be deleted.
- **The Matter server listens on loopback only.** Its WebSocket API has
  no authentication and binds every interface by default, so anything on
  the LAN could commission or remove devices on your fabric. It's also
  pinned to the LAN interface (`--primary-interface`), because `docker0`
  and App Lab's bridge interfaces carry IPv6 link-local addresses too.
- **`merge-partitions` doesn't follow the widely shared forum guide.** On
  this layout that guide's `rsync -x /home/ …` copies *nothing* from the
  user partition: `-x` stops at the `/home/arduino` mount point and
  leaves an empty directory, which the guide's next steps then delete
  the original of. This script copies from the mount itself, through a
  bind mount of `/` so you don't have to unmount the home you're logged
  into. It also grows `rootfs` with `sfdisk -N`, which changes only the
  size, instead of deleting and recreating it in `fdisk`, which throws
  away the partition's GUID, name, type, and attributes. And it reads
  the on-disk table every time, never `lsblk` — after a table write with
  root mounted, the kernel keeps showing the old layout until reboot.
- **`merge-partitions` stops Docker by stopping the daemon**, not the
  containers. A daemon shutdown doesn't count as a manual stop, so
  containers with `restart: unless-stopped` come back on their own after
  the reboot.
## Extending it
 
Every stage is a self-contained `stage_<name>()` function with its own
`local` variables, so adding one doesn't risk colliding with any other
stage's state. To add a new stage:
 
1. Write `stage_<name>()` near the others in the script.
2. Add its id to the `STAGE_IDS` array, in the position you want it to
   run (before `merge-partitions`, which must stay last). If it should
   never run by default, add it to `OPT_IN_STAGES` too.
3. Add one line each to the `STAGE_DESCRIPTIONS` and `STAGE_FUNCS`
   associative arrays.
`--list`, `--only`, `--skip`, and the runner/logging all pick up a new
stage automatically from there — nothing else to wire up.
 
For any stage that writes a file, use the existing `write_if_changed`
helper instead of writing directly: it compares the new content against
what's already on disk, only touches the file (with a timestamped
backup) if something actually changed, and is what makes re-running the
whole script a no-op when nothing's different.
 
## Known things worth knowing
 
- The very first real `speedtest` run needs interactive license
  acceptance. Non-interactively: `speedtest --accept-license --accept-gdpr`.
- `display-fix` needs a live XFCE session to seed the desktop-side
  profile. Run over SSH and it'll install the greeter-level fix fine but
  warn about skipping the rest — re-run `--only display-fix` from the
  actual desktop afterward.
- `github-ssh` doesn't add the key to GitHub for you — copy the printed
  public key to <https://github.com/settings/ssh/new> yourself, then
  verify with `ssh -T git@github.com`. It also adds a small managed
  block to `~/.ssh/config` (`StrictHostKeyChecking accept-new` for
  `github.com`) so that first connection doesn't hang on a host-key
  prompt; anything else already in that file is left untouched.
- `--ha` rewrites `compose.yaml` whenever its content differs from what
  the stage generates (keeping a timestamped `.bak`), so make lasting
  changes in `stage_home_assistant()`, not by hand in the file.
- After `--part` run 1, Docker stays stopped until you reboot.
- `--part` masks `debos-grow-rootfs.service`. It comes from the image
  build and runs at every boot, calling `growpart` on partition 2 (a
  3.5 MB firmware partition that can never grow) and `resize2fs` on both
  filesystem UUIDs — after the merge one of those no longer exists. A
  reflash brings the service back along with the original layout.
- Keep the script's line endings as LF. A copy saved with Windows (CRLF)
  line endings won't run under bash at all.
- Full log of each run: `~/.uno-q-deploy/logs/`. Partition-table backups
  from `--part` land there too.
 
Claude finished the response
