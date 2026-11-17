# lg-display-wake-fix

A small macOS background helper that brings an external display back when it wakes from sleep with the backlight on but no picture.

It was written for an LG 32UN880 (UltraFine Ergo 4K) on an Apple Silicon Mac, where the problem appeared after a macOS upgrade. It is a workaround on the Mac side, not a monitor firmware fix.

## The problem

- The display goes to sleep normally.
- On wake (key press or mouse move) the monitor's backlight comes on, but the screen stays black.
- The only way to get the picture back is to power-cycle the monitor or replug the cable.
- LG's OnScreen Control reports the monitor firmware as up to date.

## What the diagnosis showed

Setup where this was found and tested:

| | |
|---|---|
| Mac | Mac mini (M2), macOS 27.2.1 |
| Monitor | LG 32UN880, shown by macOS as "LG HDR 4K" |
| Connection | DisplayPort, tunnelled through a Thunderbolt 3 dock |
| Mode | 2560×1440 HiDPI at 60 Hz |

Findings:

- **The Mac thinks everything is fine.** In the failed state macOS reports the display as online and the DisplayPort link as active (HBR2, 4 lanes, hot-plug detect high). Nothing on the Mac side distinguishes a black screen from a working one.
- **The link is rebuilt on every sleep.** The DisplayPort transport entry in the IORegistry is recreated each time the display sleeps and wakes, so the monitor and Mac renegotiate the link every time.
- **`pmset displaysleepnow` reproduces it**, even when the display is woken again within a second.
- **A new mode-set fixes it.** Switching the display to the same resolution at 30 Hz and back to 60 Hz restores the picture, with no power-cycle.

Whether the Thunderbolt dock is the root cause was not tested. If you can, try connecting the monitor directly to the Mac first.

## How the helper works

`lgwakefix` runs as a login agent and listens for display-wake and system-wake notifications. After each wake it:

1. waits 4 seconds for the monitor to come up,
2. switches the display to the same resolution at a different refresh rate (30 Hz when available),
3. holds that for 2 seconds,
4. switches back to the original mode.

The mode changes are applied for the login session only, so your saved display settings are never modified.

Because the failure cannot be detected, the helper does this after **every** wake. You will see two short blinks a few seconds after the screen wakes.

By default it only touches LG displays (EDID vendor `GSM`). Pass `--all` to act on every external display.

## Requirements

- macOS on Apple Silicon (only tested on the setup above)
- A Swift compiler: install the Xcode Command Line Tools with `xcode-select --install`

## Install

```bash
git clone https://github.com/feijj/lg-display-wake-fix.git
cd lg-display-wake-fix
```

Run it for the current login session only (no password needed):

```bash
./install.sh
```

Or start it at every login (asks for your password once, to copy one file into `/Library/LaunchAgents`):

```bash
./install.sh --persist
```

The script compiles `lgwakefix.swift`, copies the binary to `/Users/Shared/lgwakefix/`, and loads the agent. Re-run it after editing the source or the options.

## Check that it works

Put the display to sleep, wake it, and watch for the two blinks:

```bash
pmset displaysleepnow
```

Then look at the log:

```bash
tail ~/Library/Logs/lgwakefix.log
```

A successful run looks like this:

```
22:26:22.791 display sleep
22:26:22.819 display wake after 0s — re-initialising in 4.0s
22:26:27.086 reinit start (method=refresh) — link: LG HDR 4K: active=true rate=5.4 Gbps (HBR2) lanes=4 hpd=High sinks=1
22:26:27.088 display 1: 2560x1440 (5120x2880 px) HiDPI @ 60.00 Hz -> 2560x1440 (5120x2880 px) HiDPI @ 30.00 Hz
22:26:30.531 display 1: restored 2560x1440 (5120x2880 px) HiDPI @ 60.00 Hz ok=true
22:26:30.532 reinit done — link: LG HDR 4K: active=true rate=5.4 Gbps (HBR2) lanes=4 hpd=High sinks=1
```

## Commands

The installed binary is `/Users/Shared/lgwakefix/lgwakefix`.

| Command | What it does |
|---|---|
| `lgwakefix status` | Show the target display, its current mode and the DisplayPort link state |
| `lgwakefix modes` | List every mode the display offers |
| `lgwakefix reinit` | Re-initialise the display once, right now |
| `lgwakefix daemon` | Stay running and re-initialise after each wake (what the login agent runs) |

Options for `reinit` and `daemon`:

| Option | Default | Meaning |
|---|---|---|
| `--method refresh` | yes | Same resolution, different refresh rate, then back |
| `--method resolution` | | Switch to a 1080p mode, then back (moves windows around) |
| `--method sleepwake` | | Sleep the display again briefly, then wake it |
| `--delay S` | 3 (agent uses 4) | Seconds to wait after wake before re-initialising |
| `--hold S` | 2 | Seconds to stay on the temporary mode |
| `--min-sleep S` | 0 | Skip the re-init if the display slept for less than S seconds |
| `--all` | off | Act on every external display, not only LG ones |

To change what the agent uses, edit the `ProgramArguments` block in `install.sh` and run it again.

## Uninstall

```bash
./uninstall.sh
```

This stops the agent and removes `/Users/Shared/lgwakefix` and, if present, `/Library/LaunchAgents/local.lgwakefix.plist`. The log file is left in place.

## Troubleshooting

**`Bootstrap failed: 5: Input/output error`**
launchd refuses to load agent files from a volume that has ownership disabled, which is common when the home folder lives on an external drive. That is why this project installs under `/Users/Shared` and `/Library/LaunchAgents` instead of `~/Library/LaunchAgents`. If you see this error with the stock scripts, check `/var/log/com.apple.xpc.launchd/launchd.log` for the reason.

**`You have not agreed to the Xcode license agreements`**
`install.sh` already prefers the Command Line Tools compiler, which does not need the licence. If you only have Xcode, run `sudo xcodebuild -license` once.

**`no matching external display online` in the log**
Your display is not an LG. Add `--all` to the agent's arguments in `install.sh`.

**The screen is still black after the blinks**
Try a longer `--delay` (for example 8), or `--method resolution`. Run `lgwakefix reinit` by hand over SSH or blind in a terminal to test a method while the screen is black.

## Limitations

- Tested on a single setup. Only the `refresh` method is confirmed to restore the picture; `resolution` and `sleepwake` are included as alternatives but unproven.
- Wakes after a long idle sleep had not been observed when this was written; the tests used `pmset displaysleepnow`.
- Every wake costs two blinks, even when the picture would have been fine.
- It does not fix the underlying cause. Worth trying as well: turning off Deep Sleep Mode in the monitor's menu, connecting the monitor without a dock, turning off HDR, and reporting the problem to Apple (Feedback Assistant) and LG.

## Licence

MIT — see [LICENSE](LICENSE).
