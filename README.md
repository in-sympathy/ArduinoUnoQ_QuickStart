# ArduinoUnoQ_QuickStart

Post-flash provisioning script for Arduino UNO Q boards. Run it once after
flashing (or reflashing) a board and it brings the board up to a standard,
working lab image — display fixed, shortcuts sane, shell configured,
tools installed, sudo passwordless, and a `~/Code` folder of your own
for git clones and board files — instead of clicking through the same
manual setup every time. Three opt-in stages go further when you ask for
them: a WireGuard connection to the lab's PiVPN server (with Pi-hole as
DNS), Home Assistant with a Matter server in Docker, and merging the
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
- [WireGuard](#wireguard)
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
- `wireguard`, `home-assistant` and `merge-partitions` don't need the
  desktop and run fine over SSH. `merge-partitions` does need an
  **interactive terminal**: it asks you to type `yes` before it deletes
  the userdata partition.
- `wireguard` needs this board's PiVPN client config at
  `~/Code/UnoQ.conf` — see [WireGuard](#wireguard).
- `home-assistant` needs Docker Engine 23.0 or later with the compose
  plugin. The UNO Q image ships both (App Lab runs its bricks in
  containers); the stage checks for them but never installs Docker itself.
- Debian (this is written and tested against the UNO Q's Debian trixie
  image specifically).

## Quick start

```bash
mkdir -p ~/Code && cd ~/Code
git clone https://github.com/in-sympathy/ArduinoUnoQ_QuickStart.git
cd ArduinoUnoQ_QuickStart
chmod +x ArduinoUnoQ_QuickStart.sh
./ArduinoUnoQ_QuickStart.sh
```

Clone over HTTPS on a fresh board: it has no GitHub SSH key yet (the
`github-ssh` stage sets that up), and some networks block SSH's port 22.

That runs every default stage, in order. The first one, `code-dir`, makes
sure `~/Code` exists and belongs to you (the `mkdir` above only gives the
clone a home on a fresh board). The three opt-in stages are left
out unless you ask for them (`--wg`, `--ha`, `--part`). To see what's
available first:

```bash
./ArduinoUnoQ_QuickStart.sh --list
```

## Stages

Stages run in this order by default. Skip or select individual ones with
`--only`/`--skip`, or use the shorthand flags where available.

| # | Stage | Flag | What it does |
|---|-------|------|---------------|
| 1 | `code-dir` | — | Creates `~/Code`, owned by you, not root: the working folder for git clones and for board-specific files other stages read (`--wg` takes `~/Code/UnoQ.conf`). If it already exists but belongs to someone else — say a `sudo` command created it — only the folder itself is handed back to you; what's inside is left alone. |
| 2 | `display-fix` | `--screen` | Forces 1920×1080@60 on `DP-1`, both at the greeter (a polling `systemd` service) and inside the XFCE session (seeded `xfconf` display profile) — two independent fixes for the UNO Q's ANX7625 DSI-to-DisplayPort bridge, which doesn't always negotiate EDID reliably through a hub. |
| 3 | `xfce-shortcuts` | `--keyboard` | Migrates the window-tiling shortcuts from `Super`+*numpad arrow* to `Super`+*arrow*. Discovers whatever command is currently bound to each key live via `xfconf-query` and moves it, rather than hardcoding values — correct regardless of what's actually bound on a given flash. |
| 4 | `zsh` | — | Installs `zsh` + `zsh-autosuggestions` + `zsh-syntax-highlighting`, sets it as the login shell, deploys `.zshrc`. |
| 5 | `motd` | — | Installs the lab's `/etc/motd` banner. |
| 6 | `tools` | `--apps` | `apt update && full-upgrade` (kernel included — the kernel this board boots is Arduino's own build, so a kernel bump here is an Arduino release, not an untested swap for a generic Debian kernel), plus `fastfetch`, `sysbench`, `btop`, `flashrom`, and the Ookla Speedtest CLI. |
| 7 | `sudo` | — | Passwordless `sudo` for the invoking user, via a `/etc/sudoers.d/` drop-in that's syntax-validated with `visudo -c` *before* it's ever installed. |
| 8 | `github-ssh` | `--github-ssh` | Generates (or reuses) an `ed25519` SSH key for this board and prints the public key with the steps to add it to GitHub. Never touches GitHub itself — registering the key is always a manual step. If this network blocks port 22 to GitHub, routes `github.com` over GitHub's port-443 SSH (`ssh.github.com`) so `git@github.com:…` remotes still work. Safe to re-run any time just to get the public key back on screen. |

### Opt-in stages

These never run as part of a plain run or a `--skip` run — only when
selected with their flag or named in `--only`.

| # | Stage | Flag | What it does |
|---|-------|------|---------------|
| 9 | `wireguard` | `--wg` | Always-on WireGuard client to the lab's PiVPN server, built from the client config PiVPN generated for this board (`~/Code/UnoQ.conf`). Userspace `wireguard-go` (the Arduino kernel has no WireGuard module), split tunnel, keepalive, Pi-hole as DNS with the LAN's gateway as fallback. See [WireGuard](#wireguard). |
| 10 | `home-assistant` | `--ha` | Home Assistant Container plus the matter.js Matter server, as one Docker Compose project in `~/homeassistant`, with the Matter API reachable on loopback only. See [Home Assistant](#home-assistant). |
| 11 | `merge-partitions` | `--part` | Folds the separate `userdata` partition (`/home/arduino`) into `rootfs`, so the whole eMMC is one root filesystem. Destructive and spread over two reboots: each run works out where the board is and does the next phase. Always runs last. See [Merging the partitions](#merging-the-partitions). |

## Options

```
Usage: ArduinoUnoQ_QuickStart.sh [OPTIONS]

  -l, --list            List available stages and exit
  -o, --only LIST       Run only these stages, comma-separated ids
  -s, --skip LIST       Skip these stages, comma-separated ids
      --screen          Run just the display-fix stage
      --keyboard        Run just the xfce-shortcuts stage
      --apps            Run just the tools (package installation) stage
      --github-ssh      Run just the github-ssh stage
      --wg              Run just the wireguard stage (opt-in; needs
                        ~/Code/UnoQ.conf -- see stage_wireguard())
      --ha              Run just the home-assistant stage (opt-in)
      --part            Run the next phase of merge-partitions (opt-in,
                        destructive -- see stage_merge_partitions())
  -h, --help            Show this help and exit
```

`--screen`, `--keyboard`, `--apps`, `--github-ssh`, `--wg`, `--ha`, and
`--part` can be combined with each other (and with `--only`/`--skip`) to
run more than one stage in a single pass. Stages always run in the order
of the tables above, whatever order the flags are given in.

## Examples

```bash
./ArduinoUnoQ_QuickStart.sh                     # every default stage, in order
./ArduinoUnoQ_QuickStart.sh --list              # see what's available
./ArduinoUnoQ_QuickStart.sh --only zsh          # just one stage
./ArduinoUnoQ_QuickStart.sh --skip motd,tools   # every default stage except these
./ArduinoUnoQ_QuickStart.sh --screen --apps     # combine flags to run several stages
./ArduinoUnoQ_QuickStart.sh --only sudo         # one-time: passwordless sudo setup
./ArduinoUnoQ_QuickStart.sh --github-ssh        # generate/print this board's GitHub key
./ArduinoUnoQ_QuickStart.sh --wg                # connect to the PiVPN server
./ArduinoUnoQ_QuickStart.sh --ha                # install Home Assistant + the Matter server
./ArduinoUnoQ_QuickStart.sh --part              # next phase of the partition merge
```

## WireGuard

`--wg` makes the board an always-on client of the lab's PiVPN server, and
puts Pi-hole (reached through the tunnel) first in its DNS settings.

**Before running it:**

1. On the server, create a peer for this board, optionally with a fixed
   tunnel address: `pivpn add -n <name>`. PiVPN writes the client config
   to `~/configs/<name>.conf` on the server.
2. Put its contents on this board as `~/Code/UnoQ.conf`, **exactly as
   PiVPN wrote it** — keys and the `DNS =` line included (the stage reads
   Pi-hole's address from it and rewrites the rest itself). Over SSH,
   create the file private first, then paste into it:

   ```bash
   install -m 600 /dev/null ~/Code/UnoQ.conf
   nano ~/Code/UnoQ.conf
   ```

   A different file name or place works too:
   `WG_CLIENT_CONF=/path/to/file ./ArduinoUnoQ_QuickStart.sh --wg`. Run on its own,
   `--wg` creates `~/Code` first if the default run hasn't yet.

What the stage does:

- Installs `wireguard-tools` and `wireguard-go` **without recommends**.
  The Arduino kernel is built without WireGuard, so the tunnel runs in
  `wireguard-go`, WireGuard's official userspace implementation —
  `wg-quick` switches to it by itself when the kernel module is missing.
  `wireguard-tools` recommends the kernel-module package, which Debian
  can satisfy with a Debian kernel image; that's what the flag prevents.
- Writes `/etc/wireguard/wg0.conf` (root-only) from your file, changed in
  three ways:
  - `AllowedIPs` becomes a **split tunnel**: the tunnel subnet plus the
    LAN behind the server (`WG_EXTRA_NETS`, default `192.168.80.0/22`).
    PiVPN's default full tunnel would cut the board off the internet
    whenever the server's end is down, and would push the board's IPv6
    default route — which Matter runs on — into a tunnel with no IPv6.
  - `PersistentKeepalive = 25` is added. The board sits behind NAT, and
    without regular traffic the server side can't reach it.
  - The `DNS =` line is dropped (kept as a comment). `wg-quick` would need
    `resolvconf` to apply it and would fight NetworkManager over
    `/etc/resolv.conf`.
- Enables `wg-quick@wg0` with a drop-in that retries a failed start every
  30 seconds, starts it, and waits for a handshake with the server.
- Sets DNS on the LAN connection through NetworkManager: the client
  config's DNS server (Pi-hole) first, the LAN's gateway second, with a
  2-second timeout. A tunnel or server outage makes lookups slower instead
  of breaking them. HA picks up the board's DNS, so nothing DNS-related
  goes into HA itself — restart HA after this stage if it was already
  running.

`~/Code/UnoQ.conf` can stay where it is — re-runs read it — but it holds
the board's private key, so the stage keeps it at mode `600`. `~/Code` is
where git clones live, so the stage also warns if the file ends up inside
a git repository without being ignored, and warns harder if it's been
committed (if that commit was ever pushed, replace the key on the server:
`pivpn remove`, then `pivpn add`). Deleting the file is fine too: re-running
`--wg` without it keeps the installed config.

**Reaching the board from the server's LAN.** The board's tunnel address
is fixed (the server ties it to the board's key), and the server's LAN is
in its `AllowedIPs`, so the only missing piece is a route on the
**server's LAN router**: the tunnel subnet (e.g. `10.233.27.0/24`) via the
server's LAN address. Then any device there reaches the board's HA at
`http://<tunnel-address>:8123` — the same address a phone uses over the
VPN from anywhere.

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
7. Installs a NetworkManager hook that keeps both containers' DNS in step
   with the board's, and restarts any container that's out of step right
   away (see below).

**Why the DNS hook.** With host networking, Docker copies the board's
`/etc/resolv.conf` into a container only when the container starts. After
a reboot where Wi-Fi comes up later than Docker — every blackout, since the
router reboots too — HA starts with *no* DNS servers: LAN integrations keep
working, but nothing online does, until HA is restarted. The hook
(`/etc/NetworkManager/dispatcher.d/90-ha-dns-sync`) runs on network events
(Wi-Fi up, DHCP or DNS changes) and restarts any of the two containers
whose DNS servers no longer match the board's. Restarts are logged:
`journalctl -t ha-dns-sync`.

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

Run `./ArduinoUnoQ_QuickStart.sh --part` three times, rebooting between runs. Each
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
  hold was removed because the kernel this board boots is Arduino's own
  build from Arduino's repo — a kernel update here is a tested Arduino
  release, not a random generic Debian swap, so there's no good reason
  to keep it separate from the rest of the upgrade. (Debian's own
  archive, trixie and trixie-backports, is enabled on the image too.
  That's why stages that install packages use `--no-install-recommends`
  wherever a Recommends could pull in a Debian kernel.) `tools` still prints a plain heads-up whenever a
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
- Some networks block outbound SSH on port 22 (the Uzhgorod connection
  does): `ssh -T git@github.com` then just hangs. `github-ssh` checks for
  this and, when 22 gets no answer but 443 does, adds a second managed
  block sending `github.com` to `ssh.github.com` port 443 — GitHub's
  official SSH-over-HTTPS-port endpoint. The block stays if the board
  later moves to a network that allows 22, since 443 works everywhere. If
  you've already set this up by hand, it's detected and left alone.
- `--ha` rewrites `compose.yaml` whenever its content differs from what
  the stage generates (keeping a timestamped `.bak`), so make lasting
  changes in `stage_home_assistant()`, not by hand in the file.
- **The Arduino kernel has no WireGuard and no SMB (CIFS) support**
  (`modprobe wireguard` and `modprobe cifs` both fail). `--wg` works around
  the first with `wireguard-go`. For the second, `mount -t cifs` fails
  with "cifs filesystem not supported", so use `smbclient` to copy files
  to and from a share. NFS and FUSE *are* in the kernel, so an NFS export
  or `sshfs` is the way to mount a remote folder on this board.
- `--wg` stores the Pi-hole address as a comment in
  `/etc/wireguard/wg0.conf`, so re-running it after you've deleted
  `~/Code/UnoQ.conf` still knows it.
- After `--part` run 1, Docker stays stopped until you reboot.
- `--part` masks `debos-grow-rootfs.service`. It comes from the image
  build and runs at every boot, calling `growpart` on partition 2 (a
  3.5 MB firmware partition that can never grow) and `resize2fs` on both
  filesystem UUIDs — after the merge one of those no longer exists. A
  reflash brings the service back along with the original layout.
- Keep the script's line endings as LF. A copy saved with Windows (CRLF)
  line endings won't run under bash at all.
- HA works on the LAN but can't reach anything online? Check its DNS
  copy: `docker exec homeassistant grep nameserver /etc/resolv.conf`. Empty
  means it started before the network had DNS; `docker restart
  homeassistant matter-server` fixes it, and the `--ha` stage's DNS hook
  normally does that for you.
- Full log of each run: `~/.uno-q-deploy/logs/`. Partition-table backups
  from `--part` land there too.
