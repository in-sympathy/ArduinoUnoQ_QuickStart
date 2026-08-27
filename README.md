# ArduinoUnoQ_QuickStart.sh

Post-flash provisioning script for Arduino UNO Q boards. Run it once after
flashing (or reflashing) a board and it brings the board up to a standard,
working lab image — display fixed, shortcuts sane, shell configured,
tools installed, sudo passwordless — instead of clicking through the same
manual setup every time.

Every stage checks its own work first and skips anything already applied,
so running the whole script again (or any subset of it) on an
already-provisioned board is always safe and fast.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Stages](#stages)
- [Options](#options)
- [Examples](#examples)
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
- Debian (this is written and tested against the UNO Q's Debian trixie
  image specifically).

## Quick start

```bash
git clone <this-repo-url>
cd <this-repo>
chmod +x ArduinoUnoQ_QuickStart.sh
./ArduinoUnoQ_QuickStart.sh
```

That runs every stage, in order. To see what it's about to do first:

```bash
./ArduinoUnoQ_QuickStart.sh --list
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

## Options

```
Usage: ArduinoUnoQ_QuickStart.sh [OPTIONS]

  -l, --list            List available stages and exit
  -o, --only LIST       Run only these stages, comma-separated ids
  -s, --skip LIST       Skip these stages, comma-separated ids
      --screen          Run just the display-fix stage
      --keyboard        Run just the xfce-shortcuts stage
      --apps            Run just the tools (package installation) stage
  -h, --help            Show this help and exit
```

`--screen`, `--keyboard`, and `--apps` can be combined with each other
(and with `--only`/`--skip`) to run more than one stage in a single pass.

## Examples

```bash
./ArduinoUnoQ_QuickStart.sh                     # everything, in order
./ArduinoUnoQ_QuickStart.sh --list              # see what's available
./ArduinoUnoQ_QuickStart.sh --only zsh          # just one stage
./ArduinoUnoQ_QuickStart.sh --skip motd,tools   # everything except these
./ArduinoUnoQ_QuickStart.sh --screen --apps     # combine flags to run several stages
./ArduinoUnoQ_QuickStart.sh --only sudo         # one-time: passwordless sudo setup
```

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

## Extending it

Every stage is a self-contained `stage_<name>()` function with its own
`local` variables, so adding one doesn't risk colliding with any other
stage's state. To add a new stage:

1. Write `stage_<name>()` near the others in the script.
2. Add its id to the `STAGE_IDS` array, in the position you want it to
   run.
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
- Full log of each run: `~/.uno-q-deploy/logs/`.
