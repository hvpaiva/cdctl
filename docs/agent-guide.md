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

To act, see [Working by screen](#working-by-screen), which is what you usually want, and [Sending input](#sending-input)
for what it does not cover. Check `cdctl capabilities` rather than assuming a command works here: anything needing a UI
profile answers `UNSUPPORTED_BUILD` where none covers this build, language and aspect ratio.

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

`data.screen` names the screen where a profile covers this game: `title`, `world`, `menu.map`, `settings.input`. Unknown
comes with the reason, and a loading screen is unknown too, so read the image then. `artifacts[0].path` is a PNG of the
game window, and `width` and `height` are its real size in pixels. Your image viewer may scale it; coordinates always
refer to the real size.

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
- `resolution.presentation` is also known with nothing stored when `cdctl game launch` started the game, since it recorded
  the display at that moment in `launch_display_mode`.
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

## Working by screen

Say what you want, not which keys to press. Each of these needs the lease (see [Sharing the machine](#sharing-the-machine)):

```sh
cdctl game launch --token TOKEN --json                # through Steam; started: false if already open
cdctl game continue --token TOKEN --json              # title screen to the world; about a minute
cdctl menu open map --token TOKEN --json              # also inventory, journal, skills, others, settings.input
cdctl menu back --token TOKEN --json                  # one level, by the way known for this screen
cdctl settings list --section input --json            # no lease and no game needed
cdctl settings plan keyboard_mouse_preset=classic --json
cdctl settings set keyboard_mouse_preset classic --apply --token TOKEN --json
cdctl game quit --graceful --token TOKEN --json       # through the menu; never kills anything
```

- `before` and `after` are the screens, `changed` says whether anything was sent, and `verification.method` says how it was
  checked: `visual_anchors`, `option_file` or `process`.
- A menu already open answers `changed: false` and sends nothing, so asking twice is safe.
- `settings set` answers with `data.real_changes`, what really differs in the file, and `next_steps` holds the command that
  undoes it. Anything other than the planned change answers `VERIFY_FAILED`. Without `--apply` it sends nothing.
- Starting a new game, picking a save and leaving by force are not offered at all.

| Code | Meaning | What to do |
| --- | --- | --- |
| `UNKNOWN_SCREEN` | The screen is not one this profile knows. Nothing was sent | Observe and read the image. It may be loading |
| `VERIFY_FAILED` | Something was sent once and the expected result did not come | Observe first. Do not repeat it blind: the game may only be slow, and a second key can undo the first |
| `PRECONDITION_FAILED` | There is no known way from here, as the game menu from the title screen | Follow `next_steps` |
| `UNSUPPORTED_BUILD` | No profile covers this game, or this keyboard preset | Use `cdctl input` and read the captures |

This game stalls for seconds when a menu changes, and shows nothing new meanwhile. That is why these commands wait
instead of sending again, and why you should too. After a timeout, look before you act.

## Sending input

Low-level input is for what the commands above do not cover. It needs the lease as well. Read the screen first, send one
thing, then read the capture in the answer:

```sh
cdctl observe --json                                            # look, and keep data.observation_id
cdctl input key Escape --token TOKEN --json                     # a key
cdctl input key w --hold-ms 800 --token TOKEN --json            # held, up to 10 seconds
cdctl input click --x 540 --y 476 --observation OBS --token TOKEN --json
cdctl input scroll --x 600 --y 500 --direction down --steps 3 --observation OBS --token TOKEN --json
```

Keys use X keysym names: `Escape`, `Return`, `space`, `e`, `F1`, `Shift_L`. A coordinate is in window pixels and needs an
observation that still holds, so a capture from before a change of resolution is refused rather than converted.

A key sent proves nothing about what it did. `changed` is null, `verification.method` is `caller_required` and
`input.result` is under `not_verified`, so read `artifacts[0]`. Where a profile exists, `--expect-screen menu.map` waits for
that screen instead and fails with `VERIFY_FAILED` if it does not come. Otherwise wait with `--settle-ms`, and observe
again if the screen is still changing.

Every answer below means the input did not happen, or stopped, with everything released:

| Code | Meaning | What to do |
| --- | --- | --- |
| `FOCUS_LOST` | The game does not have the focus, or lost it during a hold | Ask the person. Do not take the focus yourself |
| `USER_INTERFERENCE` | A person or another program is using the input, or a key is already held | Stop, and tell the person |
| `SYSTEM_DIALOG_PRESENT` | A dialog is or may be over the game | Report it and stop. Never answer or dismiss it |
| `RESOLUTION_CHANGED`, `TARGET_CHANGED` | The window or the process is not the one you saw | Observe again |
| `OBSERVATION_STALE` | The observation is older than `--max-age`, 120 seconds by default | Observe again |
| `LEASE_LOST` | Someone took the lease over | Stop what you were doing |

`actions` lists what really happened, also on failure, with how long each key was held and what released it.
`released_by` is `cdctl`, `sentinel`, or `next_command` when the next input command will finish the job. `status` reports
`input.state: left_held` in that last case, and `cdctl input release` clears it without sending anything else.

On a desktop whose dialogs cdctl cannot see, input stops with `SYSTEM_DIALOG_PRESENT`. `--allow-unverified-dialogs` sends
anyway and lists `system_dialogs` under `not_verified`. Use it only when you know what is on the screen.

Input from a gamepad does not pass through the X server, so it is not noticed. A person on a gamepad can move the game at
the same time as you.

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
change the monitor, or stop anything else on the machine as part of observing it. Entering the world lets the game
autosave, as playing does, so continue a game only when that is what the person wants.

Reading needs nothing. Acting needs the input lease, which another agent on the machine may hold:

```sh
cdctl lease status --json
cdctl lease acquire --owner agent-a --purpose "check a preset" --json   # data.token, shown only here
cdctl lease renew --token TOKEN --json                                  # between long steps
cdctl lease release --token TOKEN --json                                # always, when done
```

| Answer | Meaning | What to do |
| --- | --- | --- |
| `LEASE_BUSY` | Someone else holds it. `data` says who and why | Wait, or ask them |
| `LEASE_LOST` | Your token no longer holds it: it was released or taken over | Stop what you were doing. Read `lease status` first |
| `LEASE_REQUIRED` | Input was tried with no token | Acquire it first |

- A lease never ends because time passed. `orphan.suspected` with its `reasons` (`machine_restarted`,
  `holder_process_gone`, `owner_silent`) is a suspicion for you to weigh, and nothing happens on its own.
- `--holder-pid` names a long-lived process of yours, so others can see when it ends. The shell that runs one
  command is not long-lived.
- `--takeover --reason TEXT` ends a suspected orphan, and needs `--force` when nothing suggests the owner is gone.
  Do that only with the person's say-so. It is logged, and the old token stops working at once.
- Pass the token as `CDCTL_LEASE_TOKEN` to keep it off the command line, and never print it in your own logs.
- A lease coordinates programs. It does not stop the person at the keyboard.
