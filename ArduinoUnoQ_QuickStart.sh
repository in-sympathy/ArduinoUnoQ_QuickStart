#!/usr/bin/env bash
#
# deploy-uno-q.sh
#
# Post-flash provisioning for the Arduino UNO Q boards in the NIVROKU lab.
# Replaces re-flashing + manually reconfiguring every board after each
# firmware/image update: run this once per fresh flash and it brings the
# board up to the standard lab image. Every stage checks its own work
# first and skips anything already applied, so re-running the script (in
# full or with --only/--skip/--screen/--keyboard/--apps/--ha/--part) is
# always safe.
#
# Stages (run in this order by default):
#   1. display-fix     Force 1920x1080@60 on DP-1 at the greeter AND inside
#                       the XFCE desktop session (two independent EDID
#                       workarounds -- see stage_display_fix() for why both
#                       are needed).                          [--screen]
#   2. xfce-shortcuts   Remap the window-tiling keyboard shortcuts from
#                       Super+<keypad arrow> to Super+<arrow>, whatever
#                       command is currently bound to each -- see
#                       stage_xfce_shortcuts() for why this is done as a
#                       live discover-and-migrate rather than hardcoded.
#                                                             [--keyboard]
#   3. zsh              Install zsh + zsh-autosuggestions + zsh-syntax-
#                       highlighting, make it the login shell, deploy .zshrc.
#   4. motd             Install the NIVROKU /etc/motd banner.
#   5. tools            apt update && full-upgrade (kernel included --
#                       the kernel this board boots is Arduino's build),
#                       install fastfetch, sysbench, btop, flashrom, and
#                       Ookla Speedtest CLI.                     [--apps]
#   6. sudo             Passwordless sudo for the invoking user, via a
#                       validated /etc/sudoers.d/ drop-in.
#   7. github-ssh       Generate (or reuse) an ed25519 key for GitHub
#                       access, print the public key with setup steps.
#                       Never touches GitHub itself.      [--github-ssh]
#
# Opt-in stages (NEVER part of a default run -- they only run when
# selected by their flag or by --only):
#   8. wireguard        Always-on WireGuard client to the lab's PiVPN
#                       server, built from the client config PiVPN
#                       generated for this board (~/wg-client.conf):
#                       userspace wireguard-go, split tunnel, keepalive,
#                       Pi-hole as DNS with the LAN gateway as fallback.
#                                                                 [--wg]
#   9. home-assistant   Home Assistant Container + the matter.js Matter
#                       server as one docker compose project in
#                       ~/homeassistant, Matter API on loopback only.
#                                                                 [--ha]
#  10. merge-partitions Fold the separate userdata (/home/arduino)
#                       partition into rootfs, so the whole eMMC is one
#                       root filesystem. Destructive, spans two reboots:
#                       each run detects where the board is and does the
#                       next phase -- see stage_merge_partitions().
#                                                               [--part]
#
# REQUIREMENTS
#   * Run as your normal desktop user -- NOT as root, NOT via sudo.
#     The script calls sudo itself wherever it needs privilege. Running
#     the whole thing under sudo breaks stage_display_fix()'s XFCE part,
#     which needs your real DBus session.
#   * Run it from a terminal INSIDE the logged-in XFCE desktop so the
#     display-fix stage can seed the XFCE display profile. Over SSH the
#     greeter-level fix still installs fine; re-run with
#     --only display-fix from the desktop afterwards to finish that part.
#   * wireguard, home-assistant and merge-partitions don't need the
#     desktop and run fine over SSH. merge-partitions does need an
#     interactive terminal: it asks for a typed "yes" before deleting the
#     userdata partition. wireguard needs this board's PiVPN client
#     config at ~/wg-client.conf (or WG_CLIENT_CONF=/path/to/file).
#
# USAGE
#   chmod +x deploy-uno-q.sh
#   ./deploy-uno-q.sh                     # run every default stage, in order
#   ./deploy-uno-q.sh --list              # show available stages
#   ./deploy-uno-q.sh --only zsh          # run just one stage
#   ./deploy-uno-q.sh --skip motd,tools   # run everything except these
#   ./deploy-uno-q.sh --screen --apps     # combine flags to run several
#   ./deploy-uno-q.sh --wg                # connect to the PiVPN server
#   ./deploy-uno-q.sh --ha                # install Home Assistant
#   ./deploy-uno-q.sh --part              # next phase of the partition merge
#   ./deploy-uno-q.sh --help
#
# ADDING A NEW STAGE
#   1. Write a function stage_<name>() below, near the others. Keep its
#      tunables as `local` variables inside the function so they can't
#      collide with other stages' variables as more get added.
#   2. Add its id to STAGE_IDS, in the position you want it to run.
#      Add it to OPT_IN_STAGES too if it must never run by default.
#   3. Add one line each to STAGE_DESCRIPTIONS and STAGE_FUNCS.
#   The runner, logging, --only/--skip and --list all pick it up from
#   there automatically -- nothing else to wire up.
#
# This file can also be `source`d (e.g. to test one function in
# isolation) without triggering a full run -- see the guard at the very
# bottom.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "deploy-uno-q.sh needs bash. Run: bash deploy-uno-q.sh" >&2
  exit 1
fi

# -E (errtrace) is required for the ERR trap below to fire on failures
# that happen inside a function -- which is where all our real work
# lives. Without it, `set -e` still aborts correctly, but the trap that
# prints *why* silently never runs.
set -Eeuo pipefail

# ============================================================
# Global config
# ============================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_DIR="${LOG_DIR:-$HOME/.uno-q-deploy/logs}"
mkdir -p "$LOG_DIR"
readonly RUN_LOG="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"

CURRENT_STAGE=""
APT_UPDATED=0
SUDO_KEEPALIVE_PID=""
ONLY_STAGES=()
SKIP_STAGES=()

# ============================================================
# Logging
# ============================================================

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$RUN_LOG"
}

warn() {
  log "WARN: $*" >&2
}

error() {
  log "ERROR: $*" >&2
}

die() {
  error "$*"
  exit 1
}

# Plain, un-timestamped, copy-pasteable tip -- still saved to the log.
hint() {
  printf '    %s\n' "$*" | tee -a "$RUN_LOG"
}

# ============================================================
# Error handling / cleanup
# ============================================================

on_error() {
  local exit_code=$? line_no="$1"
  error "command failed (exit $exit_code) at line $line_no${CURRENT_STAGE:+, during stage '$CURRENT_STAGE'}"
}

start_sudo_keepalive() {
  (
    set +e
    while kill -0 "$$" 2>/dev/null; do
      sudo -n true 2>/dev/null
      sleep 60
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
}

stop_sudo_keepalive() {
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
}

# ============================================================
# Small helpers
# ============================================================

contains() {
  local needle="$1" straw
  shift
  for straw in "$@"; do
    [[ "$straw" == "$needle" ]] && return 0
  done
  return 1
}

# Refresh the apt index at most once per run, so stages that need it
# (and any future ones) don't each pay for their own `apt update`.
ensure_apt_index_fresh() {
  if [[ "$APT_UPDATED" -eq 1 ]]; then
    log "Package index already refreshed this run, skipping apt update"
    return 0
  fi
  log "Updating package index"
  sudo apt update -qq
  APT_UPDATED=1
}

# write_if_changed <dest_path> <tmp_content_path> [sudo]
#
# The idempotency primitive every stage below uses for the files it
# deploys: compares tmp_content_path (already-written new content)
# against dest_path byte-for-byte.
#   * Identical (dest exists and matches)  -> leaves dest alone, returns 1.
#   * Different or dest doesn't exist yet  -> backs up any existing dest
#     (timestamped), installs the new content, returns 0.
# Pass "sudo" as the third argument when dest needs root to read/write.
# Callers use the return value to decide what to log and whether any
# dependent action (systemctl reload, etc.) is actually necessary.
write_if_changed() {
  local dest="$1" tmp="$2" use_sudo="${3:-}"
  local as=()
  [[ "$use_sudo" == "sudo" ]] && as=(sudo)

  if "${as[@]}" test -f "$dest" && "${as[@]}" cmp -s "$tmp" "$dest"; then
    return 1
  fi
  if "${as[@]}" test -f "$dest"; then
    "${as[@]}" cp "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)"
  fi
  "${as[@]}" cp "$tmp" "$dest"
  return 0
}

# confirm_on_tty <prompt>
#
# Asks on the controlling terminal and succeeds only on a literal "yes".
# Reads /dev/tty rather than stdin so it still works when stdin is
# redirected, and fails closed (returns 1) when there's no terminal to
# ask on at all -- a destructive step must never be confirmed by default.
confirm_on_tty() {
  local reply=""
  { printf '\n%s\nType yes to continue: ' "$1" > /dev/tty && read -r reply < /dev/tty; } 2>/dev/null || return 1
  [[ "$reply" == "yes" ]]
}

# ============================================================
# Preflight
# ============================================================

preflight_checks() {
  if [[ "$EUID" -eq 0 ]]; then
    die "Run this as your normal desktop user, not root/sudo -- it calls sudo itself where needed, and the display-fix stage needs your real desktop session."
  fi

  command -v sudo >/dev/null 2>&1 || die "sudo is required but not found on PATH."

  log "Requesting sudo access (you may be prompted for your password)"
  sudo -v || die "Could not obtain sudo privileges."
  start_sudo_keepalive
}

# ============================================================
# Stage: display-fix
# ============================================================
#
# Forces 1920x1080@60 on the Arduino UNO Q where the hub/monitor EDID
# isn't read reliably at the X level. Two independent problems, two
# fixes:
#
#   1. Greeter (pre-login) X session: DP-1 shows "0mm x 0mm" and only
#      offers the generic 640x480/1024x768/800x600/848x480 fallback
#      list. A systemd service polls for X + DP-1, then manually
#      creates and applies a 1080p mode via xrandr.
#
#   2. Desktop session (post-login): XFCE's xfsettingsd applies its own
#      saved per-monitor profile from the "displays" xfconf channel,
#      independent of the greeter's X state, and falls back to
#      1024x768 if it has no saved profile yet. This seeds that profile
#      directly so there's nothing to fall back to.

stage_display_fix() {
  local OUTPUT="DP-1"
  local MODE_NAME="1080p60"
  local MODELINE="173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync"
  local MAX_WAIT=60   # seconds to wait for X + display before giving up

  # XFCE per-monitor profile values, captured from a known-good session via
  # `xfconf-query -c displays -l -v`. If you ever swap monitor or hub, fix
  # the resolution manually once, re-run that command, and update these.
  local XFCE_EDID_HASH="49c5e9ee8a2f90d07351eaec4ec2667061b9caa0"
  local XFCE_RESOLUTION="1920x1080"
  local XFCE_REFRESH="59.962844"

  local FIX_SCRIPT=/usr/local/bin/fix-display-mode.sh
  local SERVICE_FILE=/etc/systemd/system/fix-display-mode.service

  # ---- Part 1: greeter-level fix (systemd service, runs before login) ----

  local tmp_fix_script tmp_service_file
  tmp_fix_script="$(mktemp)"
  cat > "$tmp_fix_script" <<FIX_DISPLAY_MODE_SH
#!/bin/sh
# Auto-generated by deploy-uno-q.sh (display-fix stage)
XR="env DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 /usr/bin/xrandr"
waited=0
echo "waiting for X session and $OUTPUT..."
while [ "\$waited" -lt $MAX_WAIT ]; do
    if [ -e /var/run/lightdm/root/:0 ] && \$XR --query >/dev/null 2>&1 && \$XR --query | grep -q "^$OUTPUT connected"; then
        echo "ready after \${waited}s"
        break
    fi
    sleep 2
    waited=\$((waited + 2))
done
if [ "\$waited" -ge $MAX_WAIT ]; then
    echo "timed out after ${MAX_WAIT}s waiting for X/$OUTPUT -- giving up"
    exit 1
fi
\$XR --newmode "$MODE_NAME" $MODELINE 2>&1 || echo "newmode: already exists, continuing"
\$XR --addmode $OUTPUT "$MODE_NAME" 2>&1 || echo "addmode: already added, continuing"
\$XR --output $OUTPUT --mode "$MODE_NAME" --rate 60
echo "applied $MODE_NAME to $OUTPUT"
\$XR --query | grep "^$OUTPUT"
FIX_DISPLAY_MODE_SH

  tmp_service_file="$(mktemp)"
  cat > "$tmp_service_file" <<SYSTEMD_UNIT
[Unit]
Description=Force working display mode on $OUTPUT (UNO Q EDID workaround)
After=lightdm.service
Wants=lightdm.service

[Service]
Type=oneshot
ExecStart=$FIX_SCRIPT
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
SYSTEMD_UNIT

  local files_changed=0
  if write_if_changed "$FIX_SCRIPT" "$tmp_fix_script" sudo; then
    log "Wrote $FIX_SCRIPT"
    sudo chmod +x "$FIX_SCRIPT"
    files_changed=1
  else
    log "$FIX_SCRIPT already up to date, skipping"
  fi
  if write_if_changed "$SERVICE_FILE" "$tmp_service_file" sudo; then
    log "Wrote $SERVICE_FILE"
    files_changed=1
  else
    log "$SERVICE_FILE already up to date, skipping"
  fi
  rm -f "$tmp_fix_script" "$tmp_service_file"

  if [[ "$files_changed" -eq 1 ]] || ! systemctl is-enabled fix-display-mode.service >/dev/null 2>&1; then
    log "Enabling greeter-level service"
    sudo systemctl daemon-reload
    sudo systemctl enable fix-display-mode.service
    log "Applying now"
    sudo "$FIX_SCRIPT"
  else
    log "Greeter-level display fix already installed, enabled, and up to date -- skipping re-apply"
  fi

  # ---- Part 2: desktop-session fix (seed XFCE's saved display profile) ----

  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "/run/user/$(id -u)/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
  fi
  export DISPLAY="${DISPLAY:-:0}"

  if command -v xfconf-query >/dev/null 2>&1 && xfconf-query -c displays -l >/dev/null 2>&1; then
    local current_edid
    current_edid="$(xfconf-query -c displays -p "/Default/$OUTPUT/EDID" 2>/dev/null || true)"

    if [[ "$current_edid" == "$XFCE_EDID_HASH" ]]; then
      log "XFCE displays profile already seeded for $OUTPUT, skipping"
    else
      log "Seeding XFCE displays profile"

      xfconf_set() {
        local prop="$1" type="$2" value="$3"
        xfconf-query -c displays -p "$prop" -s "$value" 2>/dev/null || \
        xfconf-query -c displays -p "$prop" -n -t "$type" -s "$value"
      }

      xfconf_set "/ActiveProfile"                string "Default"
      xfconf_set "/AutoEnableProfiles"           int    3
      xfconf_set "/Default/$OUTPUT"              string "$OUTPUT"
      xfconf_set "/Default/$OUTPUT/Active"       bool   true
      xfconf_set "/Default/$OUTPUT/EDID"         string "$XFCE_EDID_HASH"
      xfconf_set "/Default/$OUTPUT/Position/X"   int    0
      xfconf_set "/Default/$OUTPUT/Position/Y"   int    0
      xfconf_set "/Default/$OUTPUT/Primary"      bool   false
      xfconf_set "/Default/$OUTPUT/Reflection"   int    0
      xfconf_set "/Default/$OUTPUT/RefreshRate"  double "$XFCE_REFRESH"
      xfconf_set "/Default/$OUTPUT/Resolution"   string "$XFCE_RESOLUTION"
      xfconf_set "/Default/$OUTPUT/Rotation"     int    0
      xfconf_set "/Default/$OUTPUT/Scale"        double 1.000000

      log "XFCE profile seeded -- desktop session should come up at $XFCE_RESOLUTION too"
    fi
  else
    warn "No live XFCE session detected (running over SSH?)."
    warn "Greeter fix is installed. Re-run: $SCRIPT_NAME --only display-fix from a terminal INSIDE the desktop session to seed the XFCE profile too."
  fi

  hint "Verify greeter fix:  sudo env DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 xrandr"
  hint "Verify XFCE profile: xfconf-query -c displays -l -v"
}

# ============================================================
# Stage: xfce-shortcuts
# ============================================================
#
# Moves the window-tiling keyboard shortcuts off the numpad. On this
# image they're currently bound to Super+<keypad arrow> (xfconf keysyms
# KP_Up/KP_Down/KP_Left/KP_Right); the goal is Super+<arrow> instead,
# with no keypad involved, same tiling behavior as before.
#
# This is deliberately NOT a fixed list of "old value -> new value"
# xfconf-query calls. Whatever command each Super+KP_<dir> is currently
# bound to (in either the /commands/custom/... or /xfwm4/custom/...
# subtree -- XFCE splits "Application Shortcuts" from "Window Manager"
# actions between those) gets read live and copied onto the matching
# Super+<dir> property, then the keypad property is removed. That's
# correct regardless of exactly what command string is behind each key
# on a given flash, and re-running it is a no-op once migrated.

stage_xfce_shortcuts() {
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "/run/user/$(id -u)/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
  fi

  if ! command -v xfconf-query >/dev/null 2>&1 || ! xfconf-query -c xfce4-keyboard-shortcuts -l >/dev/null 2>&1; then
    warn "No live XFCE session detected (running over SSH?)."
    warn "Re-run: $SCRIPT_NAME --only xfce-shortcuts from a terminal INSIDE the desktop session."
    return 0
  fi

  local channel="xfce4-keyboard-shortcuts"
  local prop value new_prop existing remapped=0

  while IFS= read -r prop; do
    case "$prop" in
      *"<Super>KP_Up")    new_prop="${prop/KP_Up/Up}" ;;
      *"<Super>KP_Down")  new_prop="${prop/KP_Down/Down}" ;;
      *"<Super>KP_Left")  new_prop="${prop/KP_Left/Left}" ;;
      *"<Super>KP_Right") new_prop="${prop/KP_Right/Right}" ;;
      *) continue ;;
    esac

    value="$(xfconf-query -c "$channel" -p "$prop")"

    existing="$(xfconf-query -c "$channel" -p "$new_prop" 2>/dev/null || true)"
    if [[ -n "$existing" && "$existing" != "$value" ]]; then
      warn "$new_prop already has a different binding (\"$existing\") -- overwriting with \"$value\" from $prop"
    fi

    log "Remapping shortcut: $prop -> $new_prop  (command: $value)"
    xfconf-query -c "$channel" -p "$new_prop" -n -t string -s "$value" 2>/dev/null || \
    xfconf-query -c "$channel" -p "$new_prop" -s "$value"
    xfconf-query -c "$channel" -p "$prop" -r
    remapped=$((remapped + 1))
  done < <(xfconf-query -c "$channel" -l)

  if [[ "$remapped" -eq 0 ]]; then
    log "No Super+<keypad arrow> shortcuts found in $channel -- already migrated, or this flash uses a different binding scheme."
  else
    log "Remapped $remapped shortcut(s) from Super+<keypad arrow> to Super+<arrow>."
  fi

  hint "Verify: xfconf-query -c xfce4-keyboard-shortcuts -l -v | grep -E '<Super>(Up|Down|Left|Right|KP_)'"
}

# ============================================================
# Stage: zsh
# ============================================================

stage_zsh() {
  local zsh_packages=(zsh zsh-common zsh-autosuggestions zsh-syntax-highlighting)

  # NOTE: this used to be `dpkg -s "${zsh_packages[@]}"`, gating on its exit
  # code alone. That's a real bug -- dpkg -s exits 0 for a package it merely
  # has *a record of*, including half-configured/unpacked-but-not-configured
  # states, not only "install ok installed". A board that was rebooting
  # mid-upgrade (as this one was) can easily leave a package in exactly that
  # state, and the old check would have called it "already installed" and
  # skipped apt install -- silently leaving it broken instead of letting apt
  # finish configuring it. Checking the actual Status field is the fix.
  local zsh_all_installed=1
  local pkg status
  for pkg in "${zsh_packages[@]}"; do
    status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
    [[ "$status" == "install ok installed" ]] || { zsh_all_installed=0; break; }
  done

  if [[ "$zsh_all_installed" -eq 1 ]]; then
    log "zsh and plugins already installed, skipping apt install"
  else
    ensure_apt_index_fresh
    log "Installing zsh and plugins"
    sudo apt install -y "${zsh_packages[@]}"
  fi

  local target_user zsh_path current_shell
  target_user="$(id -un)"
  zsh_path="$(command -v zsh)"
  current_shell="$(getent passwd "$target_user" | cut -d: -f7)"

  if [[ "$current_shell" != "$zsh_path" ]]; then
    log "Setting login shell to $zsh_path for $target_user"
    sudo chsh -s "$zsh_path" "$target_user"
  else
    log "Login shell for $target_user is already $zsh_path"
  fi

  # NOTE: the banner-suppression flag inside this file uses the literal
  # text "#{UID}", not the shell parameter ${UID}. That's kept exactly as
  # given -- but as written it will NOT be expanded by sh/zsh, so every
  # user/session shares one flag file ("/tmp/.nivroku_#{UID}") instead of
  # getting a per-UID one. Change it to ${UID} below if that's not what
  # you want.
  local zshrc="$HOME/.zshrc"
  local tmp_zshrc
  tmp_zshrc="$(mktemp)"
  cat > "$tmp_zshrc" <<'ZSHRC_CONTENT'
# Load autosuggestions
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Load syntax highlighting
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# Set up the prompt

autoload -Uz promptinit
promptinit
prompt adam1

# adam1's built-in hostname field is %m (short hostname, up to the first
# '.'), not %M (full hostname). It sets $base_prompt once at setup time
# and its precmd hook re-reads that same variable on every prompt draw,
# so mutating it here -- after the theme is loaded -- is enough; no need
# to touch the hook or the theme file itself. The backslash before %m is
# required: zsh's pattern matcher treats a bare % as special and it
# silently fails to match without it.
base_prompt="${base_prompt//\%m/%M}"

setopt histignorealldups sharehistory

# Use emacs keybindings even if our EDITOR is set to vi
bindkey -e

# Keep 1000 lines of history within the shell and save it to ~/.zsh_history:
HISTSIZE=1000
SAVEHIST=1000
HISTFILE=~/.zsh_history

# Use modern completion system
autoload -Uz compinit
compinit -u

zstyle ':completion:*' auto-description 'specify: %d'
zstyle ':completion:*' completer _expand _complete _correct _approximate
zstyle ':completion:*' format 'Completing %d'
zstyle ':completion:*' group-name ''
zstyle ':completion:*' menu select=2
eval "$(dircolors -b)"
zstyle ':completion:*:default' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' list-colors ''
zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=* l:|=*'
zstyle ':completion:*' menu select=long
zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
zstyle ':completion:*' use-compctl false
zstyle ':completion:*' verbose true

zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'

# Show NIVROKU banner
[[ $- != *i* ]] && return

banner="$HOME/NivrokuGreeter.txt"
flag="/tmp/.nivroku_#{UID}"

if [[ -r "$banner" && ! -e "$flag" ]]; then
 cat "$banner"
 : > "$flag"
fi
ZSHRC_CONTENT

  if write_if_changed "$zshrc" "$tmp_zshrc"; then
    log "Wrote $zshrc"
  else
    log "$zshrc already up to date, skipping"
  fi
  rm -f "$tmp_zshrc"
}

# ============================================================
# Stage: motd
# ============================================================

stage_motd() {
  local motd_file="/etc/motd"
  local tmp_motd
  tmp_motd="$(mktemp)"
  cat > "$tmp_motd" <<'MOTD_CONTENT'


███╗   ██╗██╗██╗   ██╗██████╗  ██████╗ ██╗  ██╗██╗   ██╗
████╗  ██║██║██║   ██║██╔══██╗██╔═══██╗██║ ██╔╝██║   ██║
██╔██╗ ██║██║██║   ██║██████╔╝██║   ██║█████╔╝ ██║   ██║
██║╚██╗██║██║╚██╗ ██╔╝██╔══██╗██║   ██║██╔═██╗ ██║   ██║
██║ ╚████║██║ ╚████╔╝ ██║  ██║╚██████╔╝██║  ██╗╚██████╔╝
╚═╝  ╚═══╝╚═╝  ╚═══╝  ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝ ╚═════╝

                     NIVROKU.COM.UA
                 Electronics Repair Lab
       Microsoldering • Firmware • Data Recovery

MOTD_CONTENT

  if write_if_changed "$motd_file" "$tmp_motd" sudo; then
    log "Wrote $motd_file"
  else
    log "$motd_file already up to date, skipping"
  fi
  rm -f "$tmp_motd"

  if [[ -d /etc/update-motd.d ]]; then
    warn "This image also has /etc/update-motd.d -- dynamic motd scripts there may append to or override this static banner; worth checking."
  fi
}

# ============================================================
# Stage: tools
# ============================================================

stage_tools() {
  : > "$LOG_DIR/updates.log"
  log "apt/install output also being teed to $LOG_DIR/updates.log"

  # Finish configuring anything dpkg left half-done. A board that's been
  # rebooting mid-upgrade (as this one was) can easily have a package
  # stuck "unpacked but not configured" from an interrupted dpkg run --
  # this repairs that before anything else touches the package database.
  # Safe and fast when there's nothing pending.
  log "Repairing any half-configured packages (dpkg --configure -a)"
  sudo dpkg --configure -a 2>&1 | tee -a "$LOG_DIR/updates.log"

  # Kernel packages are NOT held here -- the kernel this board boots is
  # Arduino's own build, from Arduino's repo, so a kernel bump is an
  # Arduino release, not an untested swap for a generic Debian kernel.
  # (Debian's own archive is enabled on this image too -- trixie and
  # trixie-backports from deb.debian.org -- which is why other stages
  # install with --no-install-recommends where a Recommends could pull
  # in a Debian kernel.) If an earlier run of this script left any
  # kernel package held, release it so full-upgrade actually updates it
  # like everything else.
  local kernel_pkgs
  kernel_pkgs="$(dpkg-query -W -f='${Package}\n' 'linux-image*' 'linux-headers*' 'linux-modules*' 2>/dev/null || true)"
  if [[ -n "$kernel_pkgs" ]]; then
    local already_held pkg held_now=()
    already_held="$(apt-mark showhold 2>/dev/null || true)"
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue
      grep -qxF "$pkg" <<< "$already_held" && held_now+=("$pkg")
    done <<< "$kernel_pkgs"

    if (( ${#held_now[@]} )); then
      log "Releasing kernel package hold(s) left by an earlier run: ${held_now[*]}"
      sudo apt-mark unhold "${held_now[@]}" >/dev/null
    fi
  fi

  log "apt update & full-upgrade"
  sudo apt update 2>&1 | tee -a "$LOG_DIR/updates.log"

  # Not a block, just a heads-up: print it plainly if this upgrade
  # includes a kernel version change, so it's the first thing you think
  # of if display/hardware behavior looks different afterward.
  if [[ -n "$kernel_pkgs" ]]; then
    local pkg cur cand
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue
      cur="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
      cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2}')"
      if [[ -n "$cur" && -n "$cand" && "$cur" != "$cand" ]]; then
        warn "This upgrade includes a kernel change: $pkg $cur -> $cand"
      fi
    done <<< "$kernel_pkgs"
  fi

  sudo apt full-upgrade -y 2>&1 | tee -a "$LOG_DIR/updates.log"
  APT_UPDATED=1

  log "Ensuring sysbench, btop, flashrom, fastfetch, and speedtest are installed"

  local pkg
  for pkg in sysbench btop flashrom; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
      sudo apt install -y "$pkg" 2>&1 | tee -a "$LOG_DIR/updates.log"
    fi
  done

  if ! command -v fastfetch >/dev/null; then
    local fastfetch_url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-aarch64.deb"
    curl -fL --retry 3 "$fastfetch_url" -o "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log"
    sudo dpkg -i "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log" || true
    sudo apt -f install -y 2>&1 | tee -a "$LOG_DIR/updates.log"
    rm -f "$LOG_DIR/fastfetch.deb"
  fi

  # Ookla's own repo, not a Debian-packaged tool -- installed via their
  # official packagecloud script. Two independent things to check before
  # doing anything, so re-runs (and --apps on its own) stay cheap:
  #   1. is the package already installed
  #   2. is the repo already registered (so we don't re-fetch+re-run a
  #      root shell script off the network for no reason)
  if command -v speedtest >/dev/null 2>&1; then
    log "Ookla Speedtest CLI already installed, skipping"
  else
    local ookla_repo_list="/etc/apt/sources.list.d/ookla_speedtest-cli.list"
    if [[ -f "$ookla_repo_list" ]]; then
      log "Ookla repository already registered, skipping repo-install script"
    else
      log "Adding the Ookla Speedtest repository"
      curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
    fi
    log "Installing speedtest"
    sudo apt-get install -y speedtest 2>&1 | tee -a "$LOG_DIR/updates.log"
  fi

  hint "First real run needs license acceptance: speedtest --accept-license --accept-gdpr"
}

# ============================================================
# Stage: sudo
# ============================================================
#
# Passwordless sudo for the invoking user (the "arduino" user in the
# normal case). This is a single-technician lab devboard, not a shared
# system -- anyone with physical access to it can already do far more
# than "run a command as root" (this whole lab exists to do BGA/eMMC/PMIC
# level work, which is a much lower bar to clear than "knows the sudo
# password"), so the password prompt on every sudo call is friction
# without a matching benefit here.
#
# This writes to /etc/sudoers.d/, which is exactly the kind of file
# where a mistake is expensive (a bad edit can break sudo entirely), so
# the content is validated with `visudo -c` BEFORE it's ever installed,
# never after.

stage_sudo() {
  local target_user
  target_user="$(id -un)"

  # visudo lives in /usr/sbin, which a non-root user's PATH commonly does
  # NOT include (that's the whole reason this script insists on running
  # as a normal user rather than root) -- `command -v visudo` fails there
  # even though the binary is sitting right there. Check the well-known
  # locations directly instead of trusting PATH for this one.
  local visudo_bin="" candidate
  for candidate in /usr/sbin/visudo /sbin/visudo /usr/local/sbin/visudo; do
    if [[ -x "$candidate" ]]; then
      visudo_bin="$candidate"
      break
    fi
  done
  [[ -n "$visudo_bin" ]] || visudo_bin="$(command -v visudo || true)"
  [[ -n "$visudo_bin" ]] || die "visudo not found (checked /usr/sbin, /sbin, /usr/local/sbin, and \$PATH) -- it ships with the sudo package, which must already be installed for this script to have gotten this far. Refusing to install an unvalidated sudoers file."

  local sudoers_file="/etc/sudoers.d/${target_user}-nopasswd"
  local tmp_sudoers
  tmp_sudoers="$(mktemp)"
  cat > "$tmp_sudoers" <<SUDOERS_CONTENT
# Auto-generated by deploy-uno-q.sh (sudo stage). Passwordless sudo for
# $target_user -- see the comment above stage_sudo() in the script for why.
$target_user ALL=(ALL) NOPASSWD: ALL
SUDOERS_CONTENT
  chmod 0440 "$tmp_sudoers"

  local check_output
  if ! check_output="$("$visudo_bin" -c -f "$tmp_sudoers" 2>&1)"; then
    rm -f "$tmp_sudoers"
    die "Generated sudoers content failed validation, refusing to install it: $check_output"
  fi

  if write_if_changed "$sudoers_file" "$tmp_sudoers" sudo; then
    sudo chown root:root "$sudoers_file"
    sudo chmod 0440 "$sudoers_file"
    log "Wrote $sudoers_file -- $target_user no longer needs a password for sudo"
  else
    log "$sudoers_file already up to date, skipping"
  fi
  rm -f "$tmp_sudoers"

  hint "Verify: sudo -k && sudo whoami   (should run with no password prompt)"
}

# ============================================================
# Stage: github-ssh
# ============================================================
#
# Generates (or reuses) an SSH key for this board to authenticate to
# GitHub, and prints the public key plus the steps to register it.
# Doesn't touch GitHub itself -- adding the key to the account at
# https://github.com/settings/ssh/new is a manual step every time, on
# every board, so this stage is idempotent on the *key material* (skip
# generation if a key already exists) but always re-prints the public
# key and instructions, since re-running it just to get the key back on
# screen is a legitimate use on its own.
#
# ed25519, no passphrase: consistent with this lab's passwordless-sudo
# posture elsewhere in this script -- a single-technician, physically
# controlled devboard, where a passphrase prompt on every git fetch is
# friction without a matching benefit. If you reuse this on a different
# kind of deployment, reconsider this (and the sudo stage) specifically.

stage_github_ssh() {
  local ssh_dir="$HOME/.ssh"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  # Prefer an existing key over generating a second one, checked in this
  # order. (id_dsa is deliberately not checked -- GitHub stopped
  # accepting DSA keys years ago, so finding one isn't a reason to skip
  # generating a key that will actually work.)
  local key_types=(ed25519 ecdsa rsa)
  local key_type priv_key="" pub_key=""
  for key_type in "${key_types[@]}"; do
    if [[ -f "$ssh_dir/id_$key_type" ]]; then
      priv_key="$ssh_dir/id_$key_type"
      pub_key="$priv_key.pub"
      break
    fi
  done

  if [[ -n "$priv_key" ]]; then
    log "Existing SSH key found ($(basename "$priv_key")), skipping generation"
    if [[ ! -f "$pub_key" ]]; then
      warn "$pub_key is missing even though $priv_key exists -- regenerating the public half from it"
      ssh-keygen -y -f "$priv_key" > "$pub_key"
    fi
  else
    priv_key="$ssh_dir/id_ed25519"
    pub_key="$priv_key.pub"
    local comment
    comment="$(id -un)@$(hostname)-uno-q"
    log "No existing SSH key found, generating a new ed25519 key"
    ssh-keygen -t ed25519 -f "$priv_key" -N "" -C "$comment" -q
  fi
  chmod 600 "$priv_key"
  chmod 644 "$pub_key"

  # Non-interactive-friendly default for future git/ssh calls to GitHub:
  # accept the host key on first contact instead of prompting (and
  # hanging, if nothing's there to answer it). Only touches ~/.ssh/config
  # when this exact block isn't already present -- anything else in that
  # file, including a github.com entry you wrote by hand, is left alone.
  # (If you do have your own github.com block already, ssh_config takes
  # the first value it finds for each setting, so appending ours after
  # yours is safe either way: yours wins on anything it sets, ours just
  # fills in StrictHostKeyChecking if yours didn't.)
  local config_file="$ssh_dir/config"
  local marker_begin="# >>> deploy-uno-q.sh managed block: github.com >>>"
  local marker_end="# <<< deploy-uno-q.sh managed block: github.com <<<"

  if [[ -f "$config_file" ]] && grep -qF "$marker_begin" "$config_file"; then
    log "$config_file already has a github.com block, skipping"
  else
    log "Adding a github.com entry to $config_file (StrictHostKeyChecking accept-new)"
    touch "$config_file"
    chmod 600 "$config_file"
    {
      [[ -s "$config_file" ]] && echo
      echo "$marker_begin"
      echo "Host github.com"
      echo "    StrictHostKeyChecking accept-new"
      echo "$marker_end"
    } >> "$config_file"
  fi

  log "Public key ($(basename "$pub_key")):"
  hint "$(cat "$pub_key")"
  hint "Add it at:  https://github.com/settings/ssh/new"
  hint "Then test:  ssh -T git@github.com"
  hint "Git remotes need the SSH form for this key to be used: git@github.com:user/repo.git (not https://github.com/...)"
}

# ============================================================
# Stage: wireguard  (OPT-IN -- never part of a default run)
# ============================================================
#
# Connects the board to the lab's PiVPN server as an always-on WireGuard
# client and makes Pi-hole, reached through the tunnel, the board's
# first DNS server. The input is the client config PiVPN generates for
# this board: create the peer on the server (`pivpn add -n <name>`),
# copy ~/configs/<name>.conf from there to ~/wg-client.conf here (or set
# WG_CLIENT_CONF=/path/to/file). Keys never live in this script.
#
# Decisions baked in:
#
#   * Arduino's kernel is built without WireGuard (`modprobe wireguard`
#     fails), so this uses wireguard-go, WireGuard's official userspace
#     implementation. wg-quick switches to it by itself when the kernel
#     module is missing, so the config file and the wg-quick@ unit are
#     the standard ones. Slower than the kernel module; plenty for HA.
#   * Both packages install with --no-install-recommends. wireguard-tools
#     recommends the kernel-module package, which Debian can satisfy with
#     a Debian kernel image -- and this image pulls from deb.debian.org.
#   * Split tunnel. PiVPN generates AllowedIPs = 0.0.0.0/0, ::0/0; that
#     becomes the tunnel subnet plus WG_EXTRA_NETS (the LAN behind the
#     server). A full tunnel would cut the board off the internet
#     whenever the server end is down, and would push its IPv6 default
#     route -- which Matter runs on -- into a tunnel with no IPv6.
#   * The server's LAN is in AllowedIPs so devices on it can reach this
#     board: WireGuard drops packets from sources outside AllowedIPs, and
#     replies to them would otherwise leave through the local internet.
#     Those devices also need a route to the tunnel subnet via the
#     server -- a static route on that LAN's router.
#   * PersistentKeepalive = 25. The board sits behind NAT; without
#     regular traffic the mapping expires, and the server side can't
#     reach the board until the board happens to send something first.
#   * DNS is set through NetworkManager, not wg-quick: wg-quick's DNS=
#     needs resolvconf and would fight NetworkManager over
#     /etc/resolv.conf. The DNS server from the client config (Pi-hole)
#     goes first on the LAN connection and the LAN's gateway second, so
#     a tunnel or server outage makes lookups slower instead of failing
#     them. The value is kept as a comment in the generated wg0.conf, so
#     a re-run still knows it after you delete ~/wg-client.conf.
#   * wg-quick@<iface> gets Restart=on-failure, so a failed start at
#     boot is retried instead of leaving the tunnel down.

# wg_conf_get <file> <section> <key>
# First value of <key> in [<section>] of a WireGuard config; empty if absent.
wg_conf_get() {
  awk -v want_sec="$2" -v want_key="$3" '
    { line = $0; sub(/#.*/, "", line) }
    line ~ /^[[:space:]]*\[/ { sec = line; gsub(/[][[:space:]]/, "", sec); next }
    tolower(sec) == tolower(want_sec) && index(line, "=") {
      k = substr(line, 1, index(line, "=") - 1)
      v = substr(line, index(line, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (tolower(k) == tolower(want_key)) { print v; exit }
    }' "$1"
}

# wg_ipv4_network <a.b.c.d/len>  ->  network address, e.g. 10.233.27.0/24
wg_ipv4_network() {
  local ip="${1%/*}" len="${1#*/}" a b c d n mask
  IFS=. read -r a b c d <<< "$ip"
  n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
  n=$(( n & mask ))
  printf '%d.%d.%d.%d/%d\n' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) \
    $(( (n >> 8) & 255 )) $(( n & 255 )) "$len"
}

# wg_render_client_conf <pivpn_client_conf> <extra_nets> <keepalive>
# Prints this board's wg-quick config: keys, Address, Endpoint and MTU
# kept; DNS kept only as a comment (applied via NetworkManager instead);
# AllowedIPs replaced with the split-tunnel list; keepalive set.
wg_render_client_conf() {
  local src="$1" extra_nets="$2" keepalive="$3"
  local priv addr mtu dns pub psk endpoint allowed peers

  priv="$(wg_conf_get "$src" Interface PrivateKey)"
  addr="$(wg_conf_get "$src" Interface Address)"
  mtu="$(wg_conf_get "$src" Interface MTU)"
  dns="$(wg_conf_get "$src" Interface DNS)"
  pub="$(wg_conf_get "$src" Peer PublicKey)"
  psk="$(wg_conf_get "$src" Peer PresharedKey)"
  endpoint="$(wg_conf_get "$src" Peer Endpoint)"
  peers="$(grep -ci '^[[:space:]]*\[peer\]' "$src" || true)"

  [[ -n $priv && -n $pub && -n $endpoint ]] \
    || die "$src is missing PrivateKey, the server's PublicKey or Endpoint -- is it the full client config from the server (keys included)?"
  [[ "$peers" == 1 ]] || die "$src has $peers [Peer] sections; expected exactly one (the server)."
  [[ $addr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
    || die "$src: Address must be one IPv4 address with its prefix (e.g. 10.233.27.98/24); got '$addr'."

  allowed="$(wg_ipv4_network "$addr")"
  extra_nets="${extra_nets// /}"
  if [[ -n $extra_nets ]]; then
    allowed+=", ${extra_nets//,/, }"
  fi
  dns="${dns// /}"

  echo "# Generated by deploy-uno-q.sh (wireguard stage) -- re-run that stage to change it."
  if [[ -n $dns ]]; then
    echo "# DNS = $dns (applied through NetworkManager, not wg-quick)"
  fi
  echo "[Interface]"
  echo "PrivateKey = $priv"
  echo "Address = $addr"
  if [[ -n $mtu ]]; then
    echo "MTU = $mtu"
  fi
  echo
  echo "[Peer]"
  echo "PublicKey = $pub"
  if [[ -n $psk ]]; then
    echo "PresharedKey = $psk"
  fi
  echo "Endpoint = $endpoint"
  echo "AllowedIPs = $allowed"
  echo "PersistentKeepalive = $keepalive"
}

# wg_apply_dns <primary[,primary2]> <fallback>
# Puts the given DNS servers first on the NetworkManager connection that
# carries the default route, followed by <fallback> (empty = that
# connection's gateway). Leaves the connection alone if already set.
wg_apply_dns() {
  local primary="$1" fallback="$2" dev con want
  dev="$(ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
  [[ -n $dev ]] || die "No default route -- can't tell which connection should get the DNS servers."
  con="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null || true)"
  [[ -n $con ]] || die "$dev isn't managed by NetworkManager -- set its DNS servers by hand: $primary first, then your router."
  if [[ -z $fallback ]]; then
    fallback="$(ip route show default dev "$dev" | awk '$2 == "via" {print $3; exit}')"
  fi
  want="$primary${fallback:+,$fallback}"

  if [[ "$(nmcli -g ipv4.dns connection show "$con")" == "$want" \
     && "$(nmcli -g ipv4.ignore-auto-dns connection show "$con")" == "yes" \
     && "$(nmcli -g ipv6.ignore-auto-dns connection show "$con")" == "yes" ]]; then
    log "DNS on '$con' ($dev) is already $want"
    return 0
  fi

  log "Setting DNS on '$con' ($dev) to $want -- Pi-hole first, ${fallback:-nothing} as fallback"
  sudo nmcli connection modify "$con" \
    ipv4.dns "$want" ipv4.ignore-auto-dns yes ipv4.dns-options "timeout:2" \
    ipv6.ignore-auto-dns yes
  sudo nmcli device reapply "$dev"
  sleep 2
  if getent hosts deb.debian.org >/dev/null 2>&1; then
    log "Name resolution works"
  else
    warn "Name resolution failed right after the DNS change. Check: grep nameserver /etc/resolv.conf"
  fi
}

stage_wireguard() {
  local WG_IFACE="wg0"
  local WG_SRC="${WG_CLIENT_CONF:-$HOME/wg-client.conf}"
  local WG_EXTRA_NETS="192.168.80.0/22"  # LAN behind the server (Kyiv); "" for none
  local WG_KEEPALIVE=25
  local WG_FALLBACK_DNS=""                # "" = the LAN connection's gateway
  local WG_HANDSHAKE_TIMEOUT=30           # seconds

  local conf="/etc/wireguard/$WG_IFACE.conf"
  local unit="wg-quick@$WG_IFACE.service"
  local dropin="/etc/systemd/system/$unit.d/restart.conf"
  local conf_changed=0 dropin_changed=0 tmp

  # ---- packages ----

  local pkg missing=()
  for pkg in wireguard-tools wireguard-go; do
    if [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)" != "install ok installed" ]]; then
      missing+=("$pkg")
    fi
  done
  if (( ${#missing[@]} )); then
    ensure_apt_index_fresh
    log "Installing ${missing[*]} (without recommends -- see stage_wireguard())"
    sudo apt-get install -y --no-install-recommends "${missing[@]}"
  else
    log "wireguard-tools and wireguard-go already installed"
  fi

  # ---- wg0.conf ----

  if [[ -f $WG_SRC ]]; then
    tmp="$(mktemp)"
    wg_render_client_conf "$WG_SRC" "$WG_EXTRA_NETS" "$WG_KEEPALIVE" > "$tmp"
    if write_if_changed "$conf" "$tmp" sudo; then
      conf_changed=1
      log "Wrote $conf from $WG_SRC"
    else
      log "$conf already up to date"
    fi
    rm -f "$tmp"
    sudo chown root:root "$conf"
    sudo chmod 600 "$conf"
  elif sudo test -f "$conf"; then
    log "No $WG_SRC -- keeping the existing $conf"
  else
    die "No client config at $WG_SRC. On the server: pivpn add -n <name>, then copy ~/configs/<name>.conf from there to $WG_SRC on this board (or set WG_CLIENT_CONF) and re-run."
  fi

  # ---- systemd: retry a failed start instead of staying down ----

  tmp="$(mktemp)"
  cat > "$tmp" <<'WG_DROPIN'
# Auto-generated by deploy-uno-q.sh (wireguard stage)
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=30
WG_DROPIN
  sudo mkdir -p "${dropin%/*}"
  if write_if_changed "$dropin" "$tmp" sudo; then
    dropin_changed=1
    sudo chmod 644 "$dropin"
    sudo systemctl daemon-reload
    log "Wrote $dropin"
  fi
  rm -f "$tmp"

  # ---- up ----

  sudo systemctl enable --quiet "$unit"
  if (( conf_changed || dropin_changed )) || ! systemctl is-active --quiet "$unit"; then
    if ip link show "$WG_IFACE" >/dev/null 2>&1 && ! systemctl is-active --quiet "$unit"; then
      log "Taking down the $WG_IFACE that was brought up outside systemd"
      sudo wg-quick down "$WG_IFACE" 2>&1 | tee -a "$RUN_LOG" || sudo ip link del "$WG_IFACE"
    fi
    log "Starting $unit (an SSH session through this tunnel drops for a few seconds)"
    sudo systemctl restart "$unit"
  else
    log "$unit already running with this config"
  fi

  # Keepalive makes wireguard send right away, so a handshake follows fast.
  local waited=0 hs=""
  while :; do
    hs="$(sudo wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}' || true)"
    if [[ -n $hs && $hs != 0 ]]; then
      break
    fi
    if (( waited >= WG_HANDSHAKE_TIMEOUT )); then
      die "No handshake with the server after ${WG_HANDSHAKE_TIMEOUT}s. Check that the Endpoint in $conf is reachable from here, that the server still has this board's peer (pivpn -c), and that the config is this board's."
    fi
    sleep 2
    waited=$((waited + 2))
  done
  log "Tunnel up: handshake with the server OK"

  # ---- DNS ----

  local dns
  dns="$(sudo sed -n 's/^# DNS = \([^ ]*\) .*/\1/p' "$conf" | head -n1)"
  if [[ -n $dns ]]; then
    wg_apply_dns "$dns" "$WG_FALLBACK_DNS"
  else
    log "The client config names no DNS server -- leaving DNS as it is"
  fi

  local addr
  addr="$(sudo awk -F' = ' '$1 == "Address" {print $2; exit}' "$conf")"
  hint "Check the tunnel:     sudo wg show $WG_IFACE"
  hint "This board is ${addr%/*} on the tunnel; Pi-hole's query log shows it under that address."
  if [[ -n $WG_EXTRA_NETS ]]; then
    hint "To reach it from $WG_EXTRA_NETS, that LAN's router needs a static route: $(wg_ipv4_network "$addr") via the server's LAN address."
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx homeassistant; then
    hint "Restart HA so it uses the new DNS servers: docker restart homeassistant"
  fi
  if [[ -f $WG_SRC ]]; then
    warn "$WG_SRC holds this board's private key. It's now in $conf (root-only); delete the copy: rm $WG_SRC"
  fi
}

# ============================================================
# Stage: home-assistant  (OPT-IN -- never part of a default run)
# ============================================================
#
# Home Assistant Container plus the Open Home Foundation Matter server,
# as one docker compose project in ~/homeassistant. This is the setup
# worked out by hand on uno-q-4gb, captured so a fresh flash gets the
# same thing. Decisions baked in:
#
#   * Docker itself comes with the UNO Q image (App Lab runs its bricks
#     in containers), so this stage never installs it -- running the
#     get.docker.com script over an existing install can break it.
#   * Both containers use host networking: mDNS discovery and Matter both
#     need to sit directly on the LAN.
#   * The Matter server is the matter.js one (ghcr.io/matter-js/
#     matterjs-server). python-matter-server, which older guides still
#     show, was archived at its final 8.1.2 release.
#   * The Matter server listens on 127.0.0.1 only. Its WebSocket API has
#     no authentication and by default binds every interface, so anything
#     on the LAN could commission or remove devices on the fabric. HA
#     reaches it on loopback: ws://127.0.0.1:5580/ws -- not "localhost",
#     which can resolve to ::1 first and miss an IPv4-only listener.
#   * --primary-interface pins Matter's link-local IPv6/mDNS traffic to
#     the LAN interface; docker0 and App Lab's bridge/veth interfaces
#     carry link-local addresses too. It's passed as a flag rather than
#     an env var so it shows on the server's "Command line:" log line.
#     The image's ENTRYPOINT is the whole `node ... MatterServer.js` call
#     and its CMD is empty, so compose's `command:` is purely arguments.
#   * stop_grace_period 60s: Docker's 10 s default can kill HA before it
#     has closed its SQLite database cleanly.
#   * TZ is set explicitly: the board's own clock runs in UTC.
#   * The config dirs are created as you before compose runs; otherwise
#     Docker creates bind-mount sources itself, owned by root.
#
# Re-running is a no-op once everything is up: compose.yaml is rewritten
# only if its content changes, and `docker compose up -d` only pulls
# missing images and recreates containers whose config changed. It never
# updates images on its own -- the update command is in the hints.

# Runs docker directly if this user can reach the daemon, otherwise via
# sudo -- so the stage also works right after `usermod -aG docker`,
# before the new group membership is active in the current login.
HA_DOCKER_CMD=()
ha_docker() {
  if (( ${#HA_DOCKER_CMD[@]} == 0 )); then
    if docker info >/dev/null 2>&1; then
      HA_DOCKER_CMD=(docker)
    else
      HA_DOCKER_CMD=(sudo docker)
    fi
  fi
  "${HA_DOCKER_CMD[@]}" "$@"
}

# ha_render_compose <tz> <iface> <disable_jemalloc: 0|1>
# Prints the compose.yaml for the stage.
ha_render_compose() {
  local tz="$1" iface="$2" no_jemalloc="$3"
  local jemalloc_line=""
  if [[ "$no_jemalloc" == 1 ]]; then
    jemalloc_line=$'\n      DISABLE_JEMALLOC: "true"'
  fi
  cat <<COMPOSE_YAML
# Auto-generated by deploy-uno-q.sh (home-assistant stage). A re-run of
# that stage replaces this file (keeping a timestamped .bak) if it differs.
services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    volumes:
      - ./config:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    environment:
      TZ: $tz$jemalloc_line
    network_mode: host
    privileged: true
    restart: unless-stopped
    stop_grace_period: 60s

  matter-server:
    container_name: matter-server
    image: ghcr.io/matter-js/matterjs-server:stable
    command: ["--listen-address", "127.0.0.1", "--primary-interface", "$iface"]
    volumes:
      - ./matter:/data
    network_mode: host
    restart: unless-stopped
COMPOSE_YAML
}

stage_home_assistant() {
  local HA_DIR="$HOME/homeassistant"
  local HA_TZ="Europe/Kyiv"
  local HA_IFACE=""              # empty = the interface of the default route
  local HA_IMAGE="ghcr.io/home-assistant/home-assistant:stable"
  local MIN_DOCKER_MAJOR=23      # Home Assistant Container needs Docker Engine 23.0+
  local PULL_HEADROOM_GB=4       # HA + Matter server images came to ~3.3 GB on uno-q-4gb
  local START_TIMEOUT=600        # seconds to wait for the web UI; first boot takes minutes
  local MATTER_TIMEOUT=60        # seconds to wait for the Matter server's listener

  # ---- Docker present, new enough, with compose ----

  command -v docker >/dev/null 2>&1 \
    || die "Docker isn't installed. The UNO Q image normally ships it for App Lab -- this stage deliberately doesn't install Docker itself."
  local server_ver
  server_ver="$(ha_docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  [[ -n "$server_ver" ]] || die "Docker is installed but the daemon isn't answering. Check: sudo systemctl status docker"
  if (( ${server_ver%%.*} < MIN_DOCKER_MAJOR )); then
    die "Docker Engine $server_ver is too old -- Home Assistant needs $MIN_DOCKER_MAJOR.0 or later."
  fi
  ha_docker compose version >/dev/null 2>&1 \
    || die "The docker compose plugin is missing (Debian package: docker-compose)."
  log "Docker Engine $server_ver with the compose plugin found (via: ${HA_DOCKER_CMD[*]})"

  # ---- Host checks ----

  if [[ -z "$HA_IFACE" ]]; then
    HA_IFACE="$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
  fi
  [[ -n "$HA_IFACE" ]] || die "No default route, so no LAN interface to pin the Matter server to. Connect the board to the network, or set HA_IFACE in stage_home_assistant()."
  log "Matter server will use $HA_IFACE"
  if ! ip -6 addr show dev "$HA_IFACE" scope link 2>/dev/null | grep -q inet6; then
    warn "$HA_IFACE has no IPv6 link-local address -- Matter needs IPv6 on the LAN interface."
  fi

  local no_jemalloc=0 page_size
  page_size="$(getconf PAGESIZE)"
  if [[ "$page_size" != 4096 ]]; then
    no_jemalloc=1
    warn "Page size is $page_size, not 4096 -- disabling HA's jemalloc allocator, which fails on larger pages."
  fi

  # ---- compose project ----

  mkdir -p "$HA_DIR/config" "$HA_DIR/matter"
  local tmp_compose
  tmp_compose="$(mktemp)"
  ha_render_compose "$HA_TZ" "$HA_IFACE" "$no_jemalloc" > "$tmp_compose"
  if write_if_changed "$HA_DIR/compose.yaml" "$tmp_compose"; then
    log "Wrote $HA_DIR/compose.yaml"
  else
    log "$HA_DIR/compose.yaml already up to date, skipping"
  fi
  rm -f "$tmp_compose"

  local compose=(compose --project-directory "$HA_DIR" -f "$HA_DIR/compose.yaml")
  ha_docker "${compose[@]}" config -q

  # ---- Space, before a first pull ----

  if ! ha_docker image inspect "$HA_IMAGE" >/dev/null 2>&1; then
    local docker_root avail_kb
    docker_root="$(ha_docker info -f '{{.DockerRootDir}}')"
    avail_kb="$(sudo df -Pk "$docker_root" | awk 'NR == 2 {print $4}')"
    if (( avail_kb < PULL_HEADROOM_GB * 1024 * 1024 )); then
      die "Only $((avail_kb / 1024 / 1024)) GB free under $docker_root; the first pull needs about $PULL_HEADROOM_GB GB. Free some space (unused App Lab brick images: docker image prune -a; or merge the partitions: $SCRIPT_NAME --part) and re-run."
    fi
  fi

  # ---- Ports: free, or already ours ----

  local port name
  for port in 8123 5580; do
    case "$port" in
      8123) name="homeassistant" ;;
      5580) name="matter-server" ;;
    esac
    if [[ -z "$(ha_docker ps -q --filter "name=^${name}\$" --filter status=running)" ]] \
       && [[ -n "$(sudo ss -Htln "sport = :$port")" ]]; then
      die "Port $port is already taken by something other than the $name container: $(sudo ss -Htlnp "sport = :$port")"
    fi
  done

  # ---- Up ----

  log "Starting Home Assistant and the Matter server (a first run pulls ~3 GB of images)"
  ha_docker "${compose[@]}" up -d 2>&1 | tee -a "$RUN_LOG"

  log "Waiting for Home Assistant's web UI (first boot takes a few minutes)"
  local waited=0
  until curl -s -o /dev/null http://127.0.0.1:8123; do
    if (( waited >= START_TIMEOUT )); then
      die "Home Assistant didn't answer on port 8123 within ${START_TIMEOUT}s. Check: docker logs --tail 50 homeassistant"
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "Home Assistant is answering on port 8123"

  local matter_listen=""
  waited=0
  until matter_listen="$(sudo ss -Htln 'sport = :5580' | awk '{print $4}')" && [[ -n "$matter_listen" ]]; do
    if (( waited >= MATTER_TIMEOUT )); then
      die "The Matter server isn't listening on port 5580 after ${MATTER_TIMEOUT}s. Check: docker logs matter-server"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  if [[ "$matter_listen" != "127.0.0.1:5580" ]]; then
    die "The Matter server is listening on '$matter_listen' instead of 127.0.0.1:5580 only -- its API would be reachable from the LAN. Check $HA_DIR/compose.yaml."
  fi
  log "Matter server is listening on loopback only ($matter_listen)"

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  hint "Onboarding:            http://${ip:-<board-ip>}:8123"
  hint "Matter integration:    Settings > Devices & services > Add integration > Matter, URL ws://127.0.0.1:5580/ws"
  hint "Matter dashboard (PC): ssh -L 5580:127.0.0.1:5580 $(id -un)@${ip:-<board-ip>}, then open http://localhost:5580"
  hint "Update later:          cd $HA_DIR && docker compose pull && docker compose up -d && docker image prune -f"
}

# ============================================================
# Stage: merge-partitions  (OPT-IN -- never part of a default run)
# ============================================================
#
# Folds the separate "userdata" partition (mounted at /home/arduino) into
# the "rootfs" partition, so the board runs on one root filesystem with
# all of the eMMC's free space in one pool instead of two fixed halves.
# Trade-off: arduino-flasher-cli's --preserve-user can't be used on a
# merged board -- there's no user partition left to preserve -- so any
# future reflash is a full wipe. Back up /home/arduino first.
#
# This is the script's only destructive stage, so it's opt-in, and it's
# LAST in STAGE_IDS: anything else selected in the same run writes into
# home BEFORE home is copied, not into a userdata partition that's about
# to be thrown away.
#
# The work spans two reboots, so each run inspects the board and does
# only the next phase:
#
#   Phase 1  userdata is still mounted at /home/arduino
#            -> copy it onto rootfs, stop mounting it at boot. Reboot.
#   Phase 2  userdata exists but is no longer mounted
#            -> typed confirmation, delete userdata, grow rootfs over its
#               space. Reboot.
#   Phase 3  no userdata, rootfs runs to the end of the disk
#            -> grow the filesystem if it doesn't fill the partition yet,
#               mask debos-grow-rootfs. Running it again from here on just
#               re-confirms everything and changes nothing.
#
# Design decisions worth knowing before changing anything here:
#
#   * Partition state is always read from the ON-DISK table (sfdisk -d),
#     never from lsblk or sysfs. Once the table is rewritten with root
#     mounted, the kernel keeps its old view until reboot, so lsblk would
#     still show a partition that's already gone.
#   * Partitions are found by GPT name ("rootfs"/"userdata") and by what
#     / is mounted from -- never by number, which differs between images.
#     The stage refuses any layout other than "userdata starts right
#     after rootfs and is the last partition on the disk".
#   * The copy goes through a bind mount of /, which exposes rootfs's own
#     /home/arduino directory -- normally hidden under the userdata mount.
#     That allows copying while you're logged in, without unmounting home.
#   * rsync's source is the mount point itself, so -x keeps it inside the
#     userdata filesystem. (The forum guide's `rsync -x /home/ ...` copies
#     NOTHING on this layout: -x stops at the /home/arduino mount point
#     and leaves an empty directory.)
#   * rootfs is grown with `sfdisk -N <n>`, which changes only the size and
#     keeps the partition's GUID, name, type and attributes. Deleting and
#     recreating it in fdisk would lose all four. Boot finds root by
#     filesystem UUID, which neither approach touches.
#   * sfdisk's exit status isn't what decides success for the two table
#     writes: with root mounted, the kernel's refusal to re-read the table
#     is expected. After each write the on-disk table is read back and
#     checked field by field, and restored from a backup taken just before
#     the write if anything is off.
#   * Docker is stopped for the copy by stopping the daemon, not the
#     containers. A daemon shutdown doesn't count as a manual stop, so
#     containers with restart: unless-stopped come back after the reboot.

# ---- On-disk GPT helpers. Each takes the output of `sfdisk -d <disk>`
# ---- as $1, so a run can read the table once and query it many times.

# Entry line for the partition with GPT name $2 (empty if none).
merge_gpt_entry_by_name() {
  grep -E "[ ,]name=\"$2\"" <<< "$1" || true
}

# Entry line for partition device $2, e.g. /dev/mmcblk0p68 (empty if none).
merge_gpt_entry_by_dev() {
  grep -E "^$2 :" <<< "$1" || true
}

# Value of field $2 (start/size/type/uuid/name/attrs) in entry line $1,
# quotes stripped.
merge_gpt_field() {
  sed -nE "s/.*[ ,]$2= *(\"[^\"]*\"|[^,]*).*/\1/p" <<< "$1" | tr -d '"'
}

merge_gpt_header() {
  sed -n "s/^$2: *//p" <<< "$1"
}

# Highest start sector of any partition, i.e. where the last one starts.
merge_gpt_max_start() {
  sed -nE 's|^/dev/[^ ]+ : start= *([0-9]+),.*|\1|p' <<< "$1" | sort -n | tail -n1
}

# ---- fstab helpers (file argument defaults to /etc/fstab) ----

# Succeeds if the file has an uncommented entry mounting at $1. Trailing
# slashes are ignored -- this image's fstab says "/home/arduino/".
merge_fstab_has_active_entry() {
  awk -v mp="$1" '
    /^[[:space:]]*#/ { next }
    { m = $2; if (m != "/") sub(/\/+$/, "", m); if (m == mp) found = 1 }
    END { exit !found }
  ' "${2:-/etc/fstab}"
}

# Prints the file with every uncommented entry mounting at $1 commented
# out, and everything else byte-for-byte unchanged.
merge_fstab_comment_out() {
  awk -v mp="$1" '
    /^[[:space:]]*#/ { print; next }
    { m = $2; if (m != "/") sub(/\/+$/, "", m) }
    m == mp { print "#" $0; next }
    { print }
  ' "${2:-/etc/fstab}"
}

# merge_restore_gpt <disk> <backup_file>
merge_restore_gpt() {
  local disk="$1" backup="$2"
  warn "Restoring the partition table of $disk from $backup"
  # The backup and the run log are this user's own files, so the shell
  # (not sudo) opening them is intended.
  # shellcheck disable=SC2024
  sudo sfdisk --no-reread --wipe-partitions never "$disk" < "$backup" >>"$RUN_LOG" 2>&1 || true
  if [[ "$(sudo sfdisk -d "$disk")" == "$(cat "$backup")" ]]; then
    warn "Partition table restored exactly."
  else
    error "The restored table does NOT match the backup. Do not reboot. Compare: sudo sfdisk -d $disk  vs  $backup"
  fi
}

# merge_grow_root <disk> <root_dev>
#
# Grows <root_dev> in place to the end of the disk. Takes its own backup
# first and returns normally only if the new entry has the same start,
# type, GUID, name and attributes as before and ends on the disk's last
# usable sector; otherwise it restores the backup and dies.
merge_grow_root() {
  local disk="$1" root_dev="$2"
  local root_partn="${root_dev##*[!0-9]}"
  local before before_entry backup
  before="$(sudo sfdisk -d "$disk")"
  before_entry="$(merge_gpt_entry_by_dev "$before" "$root_dev")"
  backup="$LOG_DIR/gpt-pre-grow-$(date +%Y%m%d-%H%M%S).sfdisk"
  printf '%s\n' "$before" > "$backup"
  log "Partition table backed up to $backup"

  log "Growing partition $root_partn ($root_dev) to the end of the disk"
  # shellcheck disable=SC2024  # the run log is this user's own file
  echo ', +' | sudo sfdisk --no-reread --wipe-partitions never -N "$root_partn" "$disk" >>"$RUN_LOG" 2>&1 || true

  local after after_entry last_lba problems=() f
  after="$(sudo sfdisk -d "$disk")"
  after_entry="$(merge_gpt_entry_by_dev "$after" "$root_dev")"
  last_lba="$(merge_gpt_header "$after" last-lba)"

  if [[ -z "$after_entry" ]]; then
    problems+=("$root_dev is missing from the partition table")
  else
    for f in start type uuid name attrs; do
      if [[ "$(merge_gpt_field "$after_entry" "$f")" != "$(merge_gpt_field "$before_entry" "$f")" ]]; then
        problems+=("$f changed: '$(merge_gpt_field "$before_entry" "$f")' -> '$(merge_gpt_field "$after_entry" "$f")'")
      fi
    done
    local start size end
    start="$(merge_gpt_field "$after_entry" start)"
    size="$(merge_gpt_field "$after_entry" size)"
    end=$((start + size - 1))
    if (( end != last_lba )); then
      problems+=("ends at sector $end, not on the last usable sector $last_lba")
    fi
  fi

  if (( ${#problems[@]} )); then
    error "Growing $root_dev didn't produce the expected entry:"
    local p
    for p in "${problems[@]}"; do
      error "  $p"
    done
    merge_restore_gpt "$disk" "$backup"
    die "Rolled back to the table from just before the grow. sfdisk's output is in $RUN_LOG."
  fi
  log "Grown: $after_entry"
}

# Phase 1: copy the mounted userdata filesystem onto rootfs and stop
# mounting it at boot.
merge_phase_copy() {
  local user_mnt="$1" bind_dir="$2" marker="$3" margin="$4" max_diffs="$5"
  local dest="$bind_dir$user_mnt"

  # Re-run after phase 1 but before its reboot: fstab no longer mounts
  # userdata; it's only still mounted because nothing has rebooted yet.
  if ! merge_fstab_has_active_entry "$user_mnt"; then
    warn "Phase 1 is already done -- /etc/fstab no longer mounts $user_mnt; it's only still mounted until the next boot."
    warn "Reboot, then run $SCRIPT_NAME --part again for phase 2."
    return 0
  fi

  log "Phase 1 of 3: copying $user_mnt onto the root filesystem"

  if ! command -v rsync >/dev/null 2>&1; then
    ensure_apt_index_fresh
    sudo apt install -y rsync
  fi

  if systemctl is-active --quiet docker.service || systemctl is-active --quiet docker.socket; then
    log "Stopping Docker for the copy -- its containers come back on their own after the reboot"
    sudo systemctl stop docker.socket docker.service
  fi

  sudo mkdir -p "$bind_dir"
  mountpoint -q "$bind_dir" || sudo mount --bind / "$bind_dir"

  # The directory under the userdata mount must be empty, or hold only our
  # marker from an interrupted earlier run -- in which case rsync resumes.
  if [[ -n "$(sudo ls -A "$dest")" ]] && ! sudo test -e "$dest/$marker"; then
    die "$dest -- rootfs's own $user_mnt, normally hidden under the userdata mount -- already has content this stage didn't put there. Inspect it and move it aside, then re-run. Nothing was copied."
  fi
  sudo touch "$dest/$marker"

  local need have avail
  need="$(sudo du -sxB1 "$user_mnt" | cut -f1)"
  have="$(sudo du -sxB1 "$dest" | cut -f1)"
  avail="$(df -B1 --output=avail / | tail -n1 | tr -d ' ')"
  if (( need - have + margin > avail )); then
    die "Not enough room on / for the copy: $(numfmt --to=iec $((need - have))) still to copy plus $(numfmt --to=iec "$margin") headroom, but only $(numfmt --to=iec "$avail") free. Free some space on / (e.g. docker image prune -a) and re-run."
  fi
  log "Space check OK: $(numfmt --to=iec "$need") in $user_mnt, $(numfmt --to=iec "$avail") free on /"

  # --delete makes an interrupted copy converge on an exact mirror when
  # re-run. Safe here: $dest was just checked to hold nothing but this
  # stage's own copy, and the marker is excluded so --delete keeps it.
  # rsync exit 24 ("some files vanished") is normal for a live home --
  # caches come and go mid-copy -- so it counts as success.
  local rsync_opts=(-aHAXx --numeric-ids --delete --exclude=/lost+found --exclude="/$marker")
  local pass rc
  for pass in 1 2; do
    log "Copying, pass $pass of 2$([[ "$pass" == 2 ]] && echo ' (whatever changed during pass 1)')"
    rc=0
    if [[ "$pass" == 1 ]]; then
      sudo rsync "${rsync_opts[@]}" --info=progress2 "$user_mnt/" "$dest/" || rc=$?
    else
      sudo rsync "${rsync_opts[@]}" "$user_mnt/" "$dest/" || rc=$?
    fi
    (( rc == 0 || rc == 24 )) || die "rsync failed (exit $rc). Re-run to resume the copy; nothing has been deleted."
  done

  local diffs ndiffs
  diffs="$(sudo rsync "${rsync_opts[@]}" -n --itemize-changes "$user_mnt/" "$dest/" || true)"
  ndiffs="$(grep -c . <<< "$diffs" || true)"
  if (( ndiffs > max_diffs )); then
    log "Paths that still differ after two passes:"
    printf '%s\n' "$diffs" | sed 's/^/    /' | tee -a "$RUN_LOG"
    die "$ndiffs paths still differ (limit $max_diffs) -- something is still writing to $user_mnt. Stop it and re-run; the copy resumes where it left off."
  elif (( ndiffs > 0 )); then
    log "$ndiffs path(s) changed during the copy (live session files -- expected):"
    printf '%s\n' "$diffs" | sed 's/^/    /' | tee -a "$RUN_LOG"
  else
    log "Copy verified: no differences"
  fi
  sudo rm -f "$dest/$marker"

  [[ -e /etc/fstab.pre-merge ]] || sudo cp -a /etc/fstab /etc/fstab.pre-merge
  local tmp_fstab
  tmp_fstab="$(mktemp)"
  merge_fstab_comment_out "$user_mnt" > "$tmp_fstab"
  if write_if_changed /etc/fstab "$tmp_fstab" sudo; then
    log "Commented out the $user_mnt entry in /etc/fstab (original kept as /etc/fstab.pre-merge)"
  fi
  rm -f "$tmp_fstab"
  if merge_fstab_has_active_entry "$user_mnt"; then
    die "/etc/fstab still mounts $user_mnt after the edit -- fix it by hand before rebooting."
  fi
  sudo systemctl daemon-reload

  sudo umount "$bind_dir"
  sudo rmdir "$bind_dir"

  log "Phase 1 done: $user_mnt is on the root filesystem and won't be mounted from userdata after the next boot."
  warn "Reboot now, then run: $SCRIPT_NAME --part   (phase 2 deletes the userdata partition)"
  warn "Docker stays stopped until that reboot."
  hint "To back out instead: sudo cp -a /etc/fstab.pre-merge /etc/fstab && sudo reboot"
}

# Phase 2: userdata exists but is no longer mounted -> delete it and grow
# rootfs over its space.
merge_phase_repartition() {
  local disk="$1" root_dev="$2" user_dev="$3" dump="$4" user_mnt="$5" marker="$6"
  local root_entry user_entry sector_size
  root_entry="$(merge_gpt_entry_by_dev "$dump" "$root_dev")"
  user_entry="$(merge_gpt_entry_by_dev "$dump" "$user_dev")"
  sector_size="$(merge_gpt_header "$dump" sector-size)"

  log "Phase 2 of 3: deleting the userdata partition and growing rootfs"

  if merge_fstab_has_active_entry "$user_mnt"; then
    die "$user_dev isn't mounted, but /etc/fstab still mounts $user_mnt -- the boot-time mount may have failed. Check 'journalctl -b' before going further. Nothing was changed."
  fi
  if [[ "$(findmnt -no TARGET -T "$user_mnt")" != "/" ]]; then
    die "$user_mnt isn't on the root filesystem -- refusing to delete userdata."
  fi
  if sudo test -e "$user_mnt/$marker"; then
    die "$user_mnt/$marker exists, so the phase 1 copy never finished -- refusing to delete userdata."
  fi
  if [[ -z "$(ls -A "$user_mnt")" ]]; then
    die "$user_mnt on the root filesystem is empty -- the copy isn't there. Refusing to delete userdata."
  fi

  local user_size_h
  user_size_h="$(numfmt --to=iec $(( $(merge_gpt_field "$user_entry" size) * ${sector_size:-512} )))"
  if ! confirm_on_tty "About to DELETE partition $user_dev (GPT name \"userdata\", $user_size_h) on $disk and grow $root_dev over its space. Your home is already on the root filesystem. This can't be undone."; then
    die "Not confirmed (or no terminal to ask on) -- nothing was changed. Re-run from an interactive terminal to continue."
  fi

  local backup
  backup="$LOG_DIR/gpt-pre-merge-$(date +%Y%m%d-%H%M%S).sfdisk"
  printf '%s\n' "$dump" > "$backup"
  log "Partition table backed up to $backup. The original entries, worth keeping off the board:"
  hint "$root_entry"
  hint "$user_entry"

  local user_partn="${user_dev##*[!0-9]}"
  log "Deleting partition $user_partn ($user_dev)"
  # shellcheck disable=SC2024  # the run log is this user's own file
  sudo sfdisk --no-reread --delete "$disk" "$user_partn" >>"$RUN_LOG" 2>&1 || true

  local after
  after="$(sudo sfdisk -d "$disk")"
  if [[ -n "$(merge_gpt_entry_by_dev "$after" "$user_dev")" ]]; then
    die "$user_dev is still in the partition table -- the delete didn't apply (sfdisk's output is in $RUN_LOG). Nothing else was changed."
  fi
  if [[ "$(merge_gpt_entry_by_dev "$after" "$root_dev")" != "$root_entry" ]]; then
    error "Deleting $user_dev also changed the $root_dev entry."
    merge_restore_gpt "$disk" "$backup"
    die "Rolled back to the original table."
  fi
  log "Deleted $user_dev from the partition table"

  merge_grow_root "$disk" "$root_dev"

  log "Phase 2 done."
  warn "Reboot now, then run: $SCRIPT_NAME --part   (phase 3 grows the filesystem and finishes up)"
}

# Phase 3: no userdata left. Finishes the grow if an earlier run stopped
# short, otherwise grows the filesystem into the partition and tidies up.
merge_phase_finish() {
  local disk="$1" root_dev="$2" dump="$3" bind_dir="$4"
  local root_entry start size last_lba end sector_size
  root_entry="$(merge_gpt_entry_by_dev "$dump" "$root_dev")"
  start="$(merge_gpt_field "$root_entry" start)"
  size="$(merge_gpt_field "$root_entry" size)"
  last_lba="$(merge_gpt_header "$dump" last-lba)"
  sector_size="$(merge_gpt_header "$dump" sector-size)"
  end=$((start + size - 1))

  if [[ "$(merge_gpt_max_start "$dump")" != "$start" ]]; then
    die "There's no \"userdata\" partition, but rootfs isn't the last partition either -- not a layout this stage knows. Nothing was changed."
  fi

  if (( end != last_lba )); then
    # userdata is already gone but the grow never happened (interrupted run).
    log "Phase 2, resumed: rootfs ends at sector $end, the disk at $last_lba"
    merge_grow_root "$disk" "$root_dev"
    warn "Reboot now, then run: $SCRIPT_NAME --part   (phase 3 finishes up)"
    return 0
  fi

  # /sys reports 512-byte units regardless of the device's sector size.
  local kernel_bytes table_bytes
  kernel_bytes=$(( $(cat "/sys/class/block/${root_dev##*/}/size") * 512 ))
  table_bytes=$(( size * ${sector_size:-512} ))
  if (( kernel_bytes != table_bytes )); then
    warn "The partition table already has rootfs at full size, but the kernel is still using the old table."
    warn "Reboot, then run: $SCRIPT_NAME --part   (phase 3 finishes up)"
    return 0
  fi

  log "Phase 3 of 3: making sure the root filesystem fills its partition"
  local out
  if ! out="$(sudo resize2fs "$root_dev" 2>&1)"; then
    printf '%s\n' "$out" | tee -a "$RUN_LOG"
    die "resize2fs failed on $root_dev"
  fi
  printf '%s\n' "$out" >> "$RUN_LOG"
  if grep -q 'Nothing to do' <<< "$out"; then
    log "Filesystem already fills the partition (debos-grow-rootfs usually does this at boot)"
  else
    log "Filesystem grown to fill the partition"
  fi

  # debos-grow-rootfs comes from the image build and runs at boot. On this
  # image it calls growpart on partition 2 -- a 3.5 MB firmware partition
  # that can never grow -- then resize2fs on both filesystem UUIDs,
  # including the deleted userdata one, which errors on every boot.
  # Harmless, but it has nothing left to do, so it's masked. A reflash
  # brings it back along with the original layout.
  local grow_unit="debos-grow-rootfs.service" grow_state
  grow_state="$(systemctl is-enabled "$grow_unit" 2>/dev/null || true)"
  case "$grow_state" in
    masked)        log "$grow_unit already masked" ;;
    ""|not-found)  log "$grow_unit isn't on this image, nothing to mask" ;;
    *)             sudo systemctl mask "$grow_unit"; log "Masked $grow_unit" ;;
  esac

  if mountpoint -q "$bind_dir"; then
    sudo umount "$bind_dir"
  fi
  if [[ -d "$bind_dir" ]]; then
    sudo rmdir "$bind_dir" 2>/dev/null || true
  fi

  log "Partitions merged: $(df -h --output=size,avail / | tail -n1 | awk '{print $1 " total, " $2 " free"}') on /"
  hint "arduino-flasher-cli --preserve-user can't work on this board any more -- back up /home/arduino before any reflash."
  hint "Once you're happy with the new layout: the commented userdata line in /etc/fstab and /etc/fstab.pre-merge can go."
}

stage_merge_partitions() {
  local ROOT_LABEL="rootfs"
  local USER_LABEL="userdata"
  local USER_MNT="/home/arduino"
  local BIND_DIR="/mnt/uno-q-merge-rootfs"
  local MARKER=".uno-q-merge-in-progress"
  local SPACE_MARGIN=$((1024 * 1024 * 1024))   # bytes to leave free on / after the copy
  local MAX_LIVE_DIFFS=25                       # paths allowed to still differ after the copy

  local root_dev disk dump root_entry user_entry user_dev
  root_dev="$(readlink -f "$(findmnt -no SOURCE /)")"
  disk="/dev/$(lsblk -no PKNAME "$root_dev")"
  dump="$(sudo sfdisk -d "$disk")"

  root_entry="$(merge_gpt_entry_by_dev "$dump" "$root_dev")"
  [[ -n "$root_entry" ]] || die "Couldn't find $root_dev in the partition table of $disk."
  if [[ "$(merge_gpt_field "$root_entry" name)" != "$ROOT_LABEL" ]]; then
    die "/ is on $root_dev, but its GPT name isn't \"$ROOT_LABEL\" -- not the Arduino layout this stage knows. Nothing was changed."
  fi

  user_entry="$(merge_gpt_entry_by_name "$dump" "$USER_LABEL")"
  if [[ -z "$user_entry" ]]; then
    merge_phase_finish "$disk" "$root_dev" "$dump" "$BIND_DIR"
    return 0
  fi
  user_dev="${user_entry%% *}"

  # Only the layout this was written for: userdata starts on the sector
  # right after rootfs ends and is the last partition on the disk, so
  # growing rootfs to the end covers exactly userdata's old space.
  local r_start r_size u_start u_size last_lba
  r_start="$(merge_gpt_field "$root_entry" start)"
  r_size="$(merge_gpt_field "$root_entry" size)"
  u_start="$(merge_gpt_field "$user_entry" start)"
  u_size="$(merge_gpt_field "$user_entry" size)"
  last_lba="$(merge_gpt_header "$dump" last-lba)"
  if (( u_start != r_start + r_size )) || (( u_start + u_size - 1 != last_lba )); then
    die "userdata ($user_dev) isn't directly after rootfs at the end of the disk -- not the layout this stage knows. Nothing was changed."
  fi

  local user_target
  user_target="$(findmnt -rno TARGET -S "$user_dev" | sed -n 1p || true)"
  if [[ -n "$user_target" ]]; then
    if [[ "$user_target" != "$USER_MNT" ]]; then
      die "$user_dev is mounted at $user_target, not $USER_MNT -- not the layout this stage knows. Nothing was changed."
    fi
    merge_phase_copy "$USER_MNT" "$BIND_DIR" "$MARKER" "$SPACE_MARGIN" "$MAX_LIVE_DIFFS"
  else
    merge_phase_repartition "$disk" "$root_dev" "$user_dev" "$dump" "$USER_MNT" "$MARKER"
  fi
}

# ============================================================
# Stage registry -- add new stages here
# ============================================================

# merge-partitions must stay last -- see the comment above
# stage_merge_partitions().
STAGE_IDS=(display-fix xfce-shortcuts zsh motd tools sudo github-ssh wireguard home-assistant merge-partitions)

# Stages that never run by default: only when named by --only or by
# their own flag.
OPT_IN_STAGES=(wireguard home-assistant merge-partitions)

declare -A STAGE_DESCRIPTIONS=(
  [display-fix]="Force 1920x1080@60 on DP-1 (greeter service + XFCE profile)"
  [xfce-shortcuts]="Remap tile-window shortcuts from Super+keypad-arrow to Super+arrow"
  [zsh]="Install zsh + plugins, set as login shell, deploy .zshrc"
  [motd]="Install the NIVROKU /etc/motd banner"
  [tools]="apt update/full-upgrade (kernel included), install fastfetch, sysbench, btop, flashrom, speedtest"
  [sudo]="Passwordless sudo for the invoking user (validated sudoers.d drop-in)"
  [github-ssh]="Generate/reuse an ed25519 key for GitHub, print it with setup steps"
  [wireguard]="WireGuard client to the PiVPN server (wireguard-go), split tunnel, Pi-hole DNS"
  [home-assistant]="Home Assistant + Matter server in Docker (~/homeassistant), Matter API on loopback"
  [merge-partitions]="Merge the userdata partition into rootfs (3 phases, reboot after phases 1 and 2)"
)

declare -A STAGE_FUNCS=(
  [display-fix]=stage_display_fix
  [xfce-shortcuts]=stage_xfce_shortcuts
  [zsh]=stage_zsh
  [motd]=stage_motd
  [tools]=stage_tools
  [sudo]=stage_sudo
  [github-ssh]=stage_github_ssh
  [wireguard]=stage_wireguard
  [home-assistant]=stage_home_assistant
  [merge-partitions]=stage_merge_partitions
)

# ============================================================
# CLI
# ============================================================

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [OPTIONS]

Runs the post-flash provisioning stages for the Arduino UNO Q lab image.
Run as your normal desktop user (not root/sudo) from a terminal inside
the logged-in XFCE session -- the script calls sudo itself where needed.
Every stage checks its own work first and skips anything already applied,
so re-running the whole script (or any of these flags) is always safe.

Options:
  -l, --list            List available stages and exit
  -o, --only LIST       Run only these stages, comma-separated ids
  -s, --skip LIST       Skip these stages, comma-separated ids
      --screen          Run just the display-fix stage
      --keyboard        Run just the xfce-shortcuts stage
      --apps            Run just the tools (package installation) stage
      --github-ssh      Run just the github-ssh stage
      --wg              Run just the wireguard stage (opt-in; needs
                        ~/wg-client.conf -- see stage_wireguard())
      --ha              Run just the home-assistant stage (opt-in)
      --part            Run the next phase of merge-partitions (opt-in,
                        destructive -- see stage_merge_partitions())
  -h, --help            Show this help and exit

  --screen, --keyboard, --apps, --github-ssh, --wg, --ha and --part can
  be combined with each other (and with --only/--skip) to run more than
  one stage in a single pass.

  wireguard, home-assistant and merge-partitions are opt-in: a plain run,
  or a run with only --skip, never includes them. They run only when
  selected by --wg/--ha/--part or named in --only.

Examples:
  ./$SCRIPT_NAME                     Run every default stage, in order
  ./$SCRIPT_NAME --only display-fix  Run just the display fix
  ./$SCRIPT_NAME --skip motd,tools   Run every default stage except motd + tools
  ./$SCRIPT_NAME --screen --apps     Run the display fix and tools stages
  ./$SCRIPT_NAME --github-ssh        Generate/print this board's GitHub key
  ./$SCRIPT_NAME --wg                Connect to the PiVPN server (WireGuard)
  ./$SCRIPT_NAME --ha                Install Home Assistant + the Matter server
  ./$SCRIPT_NAME --part              Run the next phase of the partition merge
USAGE
}

list_stages() {
  printf '%-17s %s\n' "ID" "DESCRIPTION"
  local id tag
  for id in "${STAGE_IDS[@]}"; do
    tag=""
    if contains "$id" "${OPT_IN_STAGES[@]}"; then
      tag="  [opt-in]"
    fi
    printf '%-17s %s%s\n' "$id" "${STAGE_DESCRIPTIONS[$id]}" "$tag"
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--list)
        list_stages
        exit 0
        ;;
      -o|--only)
        [[ $# -ge 2 ]] || die "--only requires a value"
        IFS=',' read -r -a ONLY_STAGES <<< "$2"
        shift 2
        ;;
      -s|--skip)
        [[ $# -ge 2 ]] || die "--skip requires a value"
        IFS=',' read -r -a SKIP_STAGES <<< "$2"
        shift 2
        ;;
      --screen)
        ONLY_STAGES+=(display-fix)
        shift
        ;;
      --keyboard)
        ONLY_STAGES+=(xfce-shortcuts)
        shift
        ;;
      --apps)
        ONLY_STAGES+=(tools)
        shift
        ;;
      --github-ssh)
        ONLY_STAGES+=(github-ssh)
        shift
        ;;
      --wg)
        ONLY_STAGES+=(wireguard)
        shift
        ;;
      --ha)
        ONLY_STAGES+=(home-assistant)
        shift
        ;;
      --part)
        ONLY_STAGES+=(merge-partitions)
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1 (see --help)"
        ;;
    esac
  done
}

validate_stage_ids() {
  local id
  for id in "${ONLY_STAGES[@]}" "${SKIP_STAGES[@]}"; do
    contains "$id" "${STAGE_IDS[@]}" || die "Unknown stage id: '$id' (see --list)"
  done
}

# ============================================================
# Main
# ============================================================

main() {
  trap 'on_error "$LINENO"' ERR
  trap stop_sudo_keepalive EXIT

  parse_args "$@"
  validate_stage_ids

  local id
  local stages_to_run=()
  for id in "${STAGE_IDS[@]}"; do
    if (( ${#ONLY_STAGES[@]} )) && ! contains "$id" "${ONLY_STAGES[@]}"; then
      continue
    fi
    # Opt-in stages never ride along with a plain or --skip-only run.
    if contains "$id" "${OPT_IN_STAGES[@]}" && ! contains "$id" "${ONLY_STAGES[@]}"; then
      continue
    fi
    if contains "$id" "${SKIP_STAGES[@]}"; then
      continue
    fi
    stages_to_run+=("$id")
  done

  if (( ${#stages_to_run[@]} == 0 )); then
    die "No stages selected to run (check --only/--skip). Use --list to see available stages."
  fi

  preflight_checks

  log "Stages to run: ${stages_to_run[*]}"

  local script_start=$SECONDS
  local stage_id fn t0
  for stage_id in "${stages_to_run[@]}"; do
    fn="${STAGE_FUNCS[$stage_id]}"
    CURRENT_STAGE="$stage_id"
    log "Starting stage '$stage_id' -- ${STAGE_DESCRIPTIONS[$stage_id]}"
    t0=$SECONDS
    "$fn"
    log "Finished stage '$stage_id' in $((SECONDS - t0))s"
  done
  CURRENT_STAGE=""

  log "All requested stages completed in $((SECONDS - script_start))s"
  log "Full log: $RUN_LOG"

  if [[ -f /var/run/reboot-required ]]; then
    warn "A reboot is required to finish applying updates (/var/run/reboot-required present)."
  fi
}

# Only auto-run when executed directly -- lets this file be `source`d
# (e.g. `source deploy-uno-q.sh` then call a single stage_* function by
# hand) without triggering a full run.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
