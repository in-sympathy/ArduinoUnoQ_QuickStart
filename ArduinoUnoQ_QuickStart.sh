#!/usr/bin/env bash
#
# deploy-uno-q.sh
#
# Post-flash provisioning for the Arduino UNO Q boards in the NIVROKU lab.
# Replaces re-flashing + manually reconfiguring every board after each
# firmware/image update: run this once per fresh flash and it brings the
# board up to the standard lab image. Every stage checks its own work
# first and skips anything already applied, so re-running the script (in
# full or with --only/--skip/--screen/--keyboard/--apps) is always safe.
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
#                       this board only tracks Arduino-provided repos),
#                       install fastfetch, sysbench, btop, flashrom, and
#                       Ookla Speedtest CLI.                     [--apps]
#   6. sudo             Passwordless sudo for the invoking user, via a
#                       validated /etc/sudoers.d/ drop-in.
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
#
# USAGE
#   chmod +x deploy-uno-q.sh
#   ./deploy-uno-q.sh                     # run every stage, in order
#   ./deploy-uno-q.sh --list              # show available stages
#   ./deploy-uno-q.sh --only zsh          # run just one stage
#   ./deploy-uno-q.sh --skip motd,tools   # run everything except these
#   ./deploy-uno-q.sh --screen --apps     # combine flags to run several
#   ./deploy-uno-q.sh --help
#
# ADDING A NEW STAGE
#   1. Write a function stage_<name>() below, near the others. Keep its
#      tunables as `local` variables inside the function so they can't
#      collide with other stages' variables as more get added.
#   2. Add its id to STAGE_IDS, in the position you want it to run.
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

  # Kernel packages are NOT held here -- this lab only tracks
  # Arduino-provided repos, so a kernel bump is an Arduino release, not
  # an untested swap from a generic Debian mirror. If an earlier run of
  # this script left any kernel package held, release it so full-upgrade
  # actually updates it like everything else.
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
# Stage registry -- add new stages here
# ============================================================

STAGE_IDS=(display-fix xfce-shortcuts zsh motd tools sudo)

declare -A STAGE_DESCRIPTIONS=(
  [display-fix]="Force 1920x1080@60 on DP-1 (greeter service + XFCE profile)"
  [xfce-shortcuts]="Remap tile-window shortcuts from Super+keypad-arrow to Super+arrow"
  [zsh]="Install zsh + plugins, set as login shell, deploy .zshrc"
  [motd]="Install the NIVROKU /etc/motd banner"
  [tools]="apt update/full-upgrade (kernel included), install fastfetch, sysbench, btop, flashrom, speedtest"
  [sudo]="Passwordless sudo for the invoking user (validated sudoers.d drop-in)"
)

declare -A STAGE_FUNCS=(
  [display-fix]=stage_display_fix
  [xfce-shortcuts]=stage_xfce_shortcuts
  [zsh]=stage_zsh
  [motd]=stage_motd
  [tools]=stage_tools
  [sudo]=stage_sudo
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
  -h, --help            Show this help and exit

  --screen, --keyboard, and --apps can be combined with each other (and
  with --only/--skip) to run more than one stage in a single pass.

Examples:
  ./$SCRIPT_NAME                     Run every stage, in order
  ./$SCRIPT_NAME --only display-fix  Run just the display fix
  ./$SCRIPT_NAME --skip motd,tools   Run everything except motd + tools
  ./$SCRIPT_NAME --screen --apps     Run the display fix and tools stages
USAGE
}

list_stages() {
  printf '%-14s %s\n' "ID" "DESCRIPTION"
  local id
  for id in "${STAGE_IDS[@]}"; do
    printf '%-14s %s\n' "$id" "${STAGE_DESCRIPTIONS[$id]}"
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
