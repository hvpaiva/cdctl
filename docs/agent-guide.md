# Using cdctl from an agent

This guide is for any program that drives cdctl: a language model, an agent or a script. You need
nothing else: no history, no knowledge of the machine.

## The loop

```sh
cdctl capabilities --json                  # what works here, and why not
cdctl schema status --json                 # the shape of a result
cdctl status --json                        # the game right now
cdctl observe --json                       # the same, plus a capture and an observation id
cdctl observation check OBS_ID --json      # is that observation still true?
```

This version only observes. `input`, `menu`, `settings`, `game` and `lease` answer `NOT_IMPLEMENTED` with
exit status 4. Check `cdctl capabilities` rather than assuming a command exists.

## Reading a result

- Trust `ok` and the exit status, then read `data`. On failure read `error.code`, which is stable, and
  `next_steps`.
- A fact is `{"status": "known", "value": ...}` or `{"status": "unknown", "reason": ...}`. Do not fill in an
  unknown from what seems likely. A known fact with a null value means the source was read and holds
  nothing, which says nothing about the running game.
- `confidence: "inferred"` means a rule produced the value, not a direct reading.
- `not_verified` lists what this result does not establish. Absence from it proves nothing else.
- `status` answers with exit status 0 when the game is closed. A closed game is an answer, not an error.
- A timeout is never a success. `TIMEOUT` comes with exit status 1, and `data` still holds what was read before it.

## Looking at the screen

`data.screen` is unknown until a UI profile exists, so read the image. `artifacts[0].path` is a PNG of the game
window, and `width` and `height` are its real size in pixels. Your image viewer may scale it; coordinates
always refer to the real size.

```sh
cdctl screenshot --region 0,650,500,430 --zoom 4 --output /tmp/corner.png --json
```

A region is in window pixels. Zoom repeats whole pixels; nothing is reconstructed.

`not_verified` says what a capture cannot claim:

| Entry | Meaning |
| --- | --- |
| `capture.frame_is_current` | The window was not focused, so the frame may be old |
| `capture.only_the_game` | No compositing manager keeps windows apart here, so whatever covers the window can be in the image |
| `capture.frame_is_not_blank` | The frame is all black, which can be a loading screen or a capture that did not work |

## Coordinates

A coordinate from a capture belongs to the geometry of that moment. Before using one, ask:

```sh
cdctl observation check OBS_ID --max-age 30 --json
```

| Answer | Meaning |
| --- | --- |
| `valid: true` | No difference in what could be compared. Read `not_verified` for what could not |
| `RESOLUTION_CHANGED` | The window moved, or the display, a stored resolution or the HUD scale changed. Observe again |
| `TARGET_CHANGED` | The game restarted or closed. Observe again |
| `OBSERVATION_STALE` | Older than `--max-age` |
| `WINDOW_NOT_FOUND`, `TIMEOUT` | cdctl could not read the game now, so nothing is known about the observation |

Never convert an old coordinate to a new resolution. The layout does not scale the same way across aspect
ratios.

## Resolution

- `resolution.window` is not the game's resolution. A window can hold a smaller image stretched to fill it,
  and `resolution.presentation` says so when a stored resolution shows it. With nothing stored, or a file newer
  than the process, it stays unknown. Do not read that as native.
- `resolution.active` stays unknown: the game does not publish it. Reading the video menu is the only source.
- If `resolution.coherence` says `display_changed`, the image may be cropped or stretched. cdctl will not fix it
  and neither should you without being asked. The known remedy on tested setups is to restart the game
  with the display already at the wanted mode, which is the user's decision. `window_changed` means the window
  alone changed, as when a splash becomes the game, and says nothing about the image.
- `first_seen` is when cdctl first looked at this process, not when it started.

## System dialogs

| `modals.status` | Meaning | What to do |
| --- | --- | --- |
| `clear` | The game is the active window and nothing is proven to be over it | Continue |
| `present` | A surface that can be an authentication prompt is over the game, or the session is locked | Report it and stop |
| `unverified` | Another window is active, or a surface overlaps a game that is not fullscreen | Say so. It can be a dialog |
| `unavailable` | This desktop does not let cdctl see those surfaces | Say so rather than assuming there are none |

On `present`, `observe` and `screenshot` answer `SYSTEM_DIALOG_PRESENT` and take no capture, while `status` still
reports it. Never answer, dismiss or work around a dialog. cdctl never reads the title or class of another window,
so it cannot tell you what an active window is; ask the person.

## From a program

Shell:

```sh
out=$(cdctl status --json); code=$?
state=$(jq -r '.data.game.state' <<<"$out")
```

Python:

```python
import json, subprocess

def cdctl(*args):
    run = subprocess.run(["cdctl", *args, "--json"], capture_output=True, text=True)
    return run.returncode, json.loads(run.stdout)

code, result = cdctl("observe")
if result["ok"]:
    print(result["artifacts"][0]["path"], result["data"]["observation_id"])
else:
    print(result["error"]["code"], result["next_steps"])
```

Any agent: run the command, parse stdout as JSON, branch on `error.code`, and open the file in `artifacts` when
you need to see the game.

## Sharing the machine

The person who owns the machine may be playing, locally or through a stream. Do not close or restart the game,
change the monitor, or stop anything else on the machine as part of observing it.
