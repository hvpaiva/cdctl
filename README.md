# cdctl

Observe and control Crimson Desert from the command line, with evidence.

cdctl finds a Steam installation of the game, its process and its window, and reports what it can
prove about them, including what it could not verify. It is built for anything that can run a
command and read JSON and images: a language model, an agent, a script or a person. It works on any
machine that runs the game, needs no hook, driver or service, and depends on nothing but Ruby.

It replaces fragile sequences of clicks and key presses with operations that state what they found,
what they did and how they checked it. It is not a combat bot, a save editor or a system manager.

**Status: this version only observes. It sends nothing to the game.** Input, menus and settings are
listed as `not_implemented` by `cdctl capabilities` until they exist.

## Install

Ruby 3.4 or newer is the one requirement.

```sh
gem install cdctl
```

## Start here

```sh
cdctl capabilities --json   # what works on this machine, and why not
cdctl doctor                # what is missing, and how to fix it
cdctl status                # the game right now
cdctl observe --json        # the same, with a capture of the game window
```

`cdctl status` on a machine running the game:

```text
Installation       Crimson Desert in /games/SteamLibrary/steamapps/common/Crimson Desert
Build              2.04.05 (Steam build 26361232, english, Proton 9.0-1)
Game               running as PID 4242 since 2026-11-02T21:16:19-03:00
X11                connected to :0
Window             0x5200005 2560x1440+0+0 focused, fullscreen
Compositor         none known: no driver for this desktop, so system dialogs cannot be seen
System dialogs     cannot see them: no driver for this desktop, so system dialogs cannot be seen
Display mode       2560x1440@59.951 (DP-1) [x11_randr]
Game screen        2560x1440@59.951 (DP-1) [x11_randr]
Window size        2560x1440 [x11]
Capture            unknown: this command took no capture
Stored resolution  not in the file [option_file]
Active resolution  unknown: the game does not publish this; it can only be read from its video menu, for this process
Render scale       67% [option_file]
HUD scale          100 [option_file]
Presentation       unknown: the file stores no resolution, so the game chose one at launch, and cdctl did not launch it
Coherence          consistent [cdctl_ledger]

Not verified: game.active_resolution, game.screen, system_dialogs
```

New to it as an agent? Read [the agent guide](docs/agent-guide.md).

## Commands

| Command | What it does |
| --- | --- |
| `cdctl capabilities` | Lists what works here, proven by trying it, with every error code and exit status |
| `cdctl doctor` | Checks what cdctl needs and says how to fix what is missing |
| `cdctl schema [NAME]` | Prints the JSON Schema of a command's result |
| `cdctl status` | Reports the installation, process, window and resolution |
| `cdctl observe` | Captures the game window and stores an observation |
| `cdctl screenshot` | Captures the game window to a PNG, with a region and a zoom that repeats pixels |
| `cdctl observation check ID` | Says whether a stored observation still describes the game |
| `cdctl lease status\|acquire\|renew\|release` | Coordinates exclusive ownership of input between programs |

`cdctl COMMAND --help` documents each one.

## The result contract

Under `--json`, stdout holds one JSON document and nothing else. Every result has the same envelope:

```json
{
  "schema_version": "1",
  "request_id": "9a82fd1f8c59a471",
  "command": "screenshot",
  "ok": true,
  "status": "ok",
  "started_at": "2026-11-02T21:17:16.303-03:00",
  "duration_ms": 184,
  "changed": false,
  "actions": [],
  "target": { "pid": 4242, "start_ticks": 102662156, "window": "0x5200005", "observed_at": "2026-11-02T21:17:16.303-03:00" },
  "data": { "path": "/path/to/capture.png", "modals": { "status": "clear" }, "resolution": {} },
  "artifacts": [{ "kind": "screenshot", "path": "/path/to/capture.png", "width": 2560, "height": 1440, "sha256": "..." }],
  "not_verified": ["game.active_resolution", "game.screen"],
  "error": null,
  "next_steps": []
}
```

A claim that can be wrong is a fact with its origin: `{"status": "known", "value": ..., "source": ...}`
or `{"status": "unknown", "reason": ...}`. Unknown is a valid answer, and `not_verified` lists what a
result does not establish. Images are always files; a result never holds pixels. Help and the version
answer in the same envelope, and so does a failure, including a timeout or a signal.

| Exit status | Meaning |
| --- | --- |
| 0 | The operation reached its result |
| 1 | The operation ran and did not reach its result |
| 2 | The command line is wrong. Nothing ran |
| 3 | The state of the game or machine does not allow the operation |
| 4 | This build, platform or backend does not support the operation |
| 130 | A signal stopped the operation |

Errors carry stable codes such as `GAME_NOT_RUNNING`, `TARGET_AMBIGUOUS` and `RESOLUTION_CHANGED`.
`cdctl capabilities --json` lists them all.

## Resolution

"The resolution" is several numbers that disagree in practice, so cdctl never reports just one:

| Field | What it is | Where it comes from |
| --- | --- | --- |
| `display_mode` | The monitor's mode | The compositor, or a plain X server. Xwayland reports only its own view of the monitors |
| `game_screen` | The screen as the game's X server reports it | X11 RandR |
| `window` | The window on that screen | X11 |
| `capture` | The size of the capture a command took | The capture itself |
| `configured_override` | A resolution stored in the game's option file | The option file |
| `active` | The resolution the running game is using | Unknown: the game does not publish it |
| `render_scale` | The upscaler setting, below whatever the menu shows | The option file |
| `hud_scale` | The HUD scale | The option file |
| `presentation` | How the image fills the window | Inferred from a stored resolution older than the process, otherwise unknown |
| `coherence` | Whether the display or the window changed since this process was first seen | cdctl's ledger |

Three things follow from how the game behaves:

- The size of the window does not reveal the resolution. A window can stay at the monitor's size
  while the game renders a smaller image stretched to fill it. cdctl reports that case as
  `stretched`, with the exact factors. With no stored resolution it says `unknown`: a mode changed
  after the launch leaves a window that fills the screen around an image of the old size.
- Changing the monitor's mode while the game is open can crop, shift or stretch the image. cdctl
  detects the change, invalidates every observation taken before it and answers
  `RESOLUTION_CHANGED`. It never fixes the display on its own: it does not change the monitor,
  fullscreen, gamescope or the game's settings.
- Coordinates belong to one geometry. `cdctl observation check` refuses an old one instead of
  converting it.

## Supported machines

The game's window, input and capture all go through the X server the game itself uses, so nothing
depends on one desktop. What a machine lacks is reported as unknown or unsupported, and
`cdctl capabilities` says which of its setups were tried against the real game.

| Setup | State |
| --- | --- |
| Linux, Proton, Hyprland | Tested with the game |
| Linux, Proton, another Xwayland desktop (GNOME, KDE, Sway) or an X session | Same path, not yet tested with the game; system dialogs cannot be seen |
| Linux, Proton with gamescope | Observed as nested, not yet tested with the game |
| Linux, native Wayland Proton | The game has no X window, so observation answers `WINDOW_NOT_FOUND` |
| Windows, macOS | Discovery only; observation answers `UNSUPPORTED_PLATFORM` |

[docs/test-matrix.md](docs/test-matrix.md) records what was tested, by build, language, resolution and
backend.

## Configuration

Nothing is required. Everything is discovered.

| Variable | Meaning |
| --- | --- |
| `CDCTL_STEAM_ROOT` | Use this Steam directory instead of searching |
| `CDCTL_STATE_HOME` | Where captures and observations are stored |
| `CDCTL_CONFIG` | The configuration file, by default `$XDG_CONFIG_HOME/cdctl/config.yaml` |
| `CDCTL_LEASE_TOKEN` | The lease token, kept off the command line |
| `CDCTL_COLOR` | When to use color: `auto`, `always` or `never` |

The configuration file accepts `steam_root`, `ignored_overlay_layers` (surfaces that are not dialogs,
as globs) and `evidence_keep` (how many captures to keep, 100 by default).

## What it reads and writes

It reads Steam's library and manifest files, `/proc`, the game's X server, the compositor's status and
the game's option file. It never writes to the game, its saves or its settings.

It writes only under `$XDG_STATE_HOME/cdctl`, with files readable by their owner alone: captures, which
can show what is on your screen, small records of observations, and the input lease with its history.
Old captures and observations are pruned. It reads a fixed list of variables from the game's environment
and prints none but `DISPLAY`.

## Remove it

```sh
gem uninstall cdctl
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/cdctl" "${XDG_CONFIG_HOME:-$HOME/.config}/cdctl"
```

The game is not touched by either step.

## Development

```sh
bundle install
bundle exec rake check
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [ARCHITECTURE.md](ARCHITECTURE.md).

## License

MIT. See [LICENSE.txt](LICENSE.txt).
