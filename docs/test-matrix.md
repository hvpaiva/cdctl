# Test matrix

What has been run against the real game, as opposed to the automated tests, which use a fake machine and a
real X server without the game. A setup missing from this table is untested, whatever it may look like.

## Tested with the game

| Build | Version | Language | Resolution | Desktop | Proton | Commands | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 26361232 | 2.04.05 | brazilian | 3440x1440 | Hyprland 0.56.2, Xwayland | 11.0-100 | `status`, `doctor`, `capabilities`, `observe`, `observation check`, `screenshot` (X11, grim, region, zoom) | Title screen. The X11 capture matches grim with a mean difference of 0.01 in 255 |
| 26361232 | 2.04.05 | brazilian | 1920x1080 | Hyprland 0.56.2, Xwayland | 11.0-100 | `status`, `doctor`, `capabilities`, `observe`, `observation check`, `screenshot` (X11, grim) | Title screen, with the capture guard and the stop at a system dialog in place |

## Input tried against the game

Build 26361232, version 2.04.05, brazilian, 1920x1080, fullscreen, Hyprland 0.56.2 with Xwayland, Proton 11.0-100, on the
title screen and in the settings menu. A key that does nothing there was held for each case.

| Case | Result |
| --- | --- |
| `input key` and `input click` | The game reacted: settings opened, a tab changed. The desktop's pointer did not move |
| `kill -9` on cdctl during a hold | No key down 100 ms later, journal gone |
| `kill -9` on cdctl and its sentinel | Key left down, `status` says `left_held`, `input release` clears it |
| `kill -9` on the sentinel | The hold ends at once with `released_by: cdctl` |
| `SIGTERM` during a hold | Released, `INTERRUPTED`, exit status 130 |
| A key from the compositor's keyboard path during a hold | `USER_INTERFERENCE`, released, `key_press: 1` |
| Another program using XTEST during a hold | `USER_INTERFERENCE`, released |
| The focus moved to another workspace during a hold | `FOCUS_LOST`, released |
| A real authentication prompt opened over the game during a hold | `SYSTEM_DIALOG_PRESENT`, released after 651 ms |
| The same prompt while idle | `status` says `present`; `observe`, `screenshot` and `input` answer `SYSTEM_DIALOG_PRESENT`. X11 and the compositor both still say the game has the focus |

| Motion from a real pointer device during a hold | `USER_INTERFERENCE`, `motion: 4`, released after 501 ms |

A warp by the compositor produces no raw motion event, so it goes unnoticed. A real device does not.

## Screens and commands tried against the game

Same setup, on the keyboard presets Standard and Classic, with the HUD scale at 90.

| Command | Result |
| --- | --- |
| `observe` | Every screen named below recognized. 83 stored real frames were all labeled correctly, and loading frames answer unknown |
| `menu open` | `map`, `inventory`, `journal`, `skills`, `others`, `settings.video`, `settings.input`, `settings.gameplay`, from the world and between each other |
| `menu open map`, with the map already open | Nothing sent, and the map stays open |
| `menu open settings.input` from the title | Works. `menu open map` from the title is refused with nothing sent |
| `menu back` | Menu to world, settings to menu, settings to title, and nothing sent in the world |
| `game launch` | Through Steam, with its launch options. The title screen is recognized with the prompts of a controller and of a keyboard |
| `game continue` | Title to world in 57 seconds, with one key |
| `game quit` | From the world and from settings: through the menu and the dialog, 8 to 11 seconds, process gone. From the title: holding the exit key, 4 seconds, with no dialog. Already closed: nothing sent |
| `settings set keyboard_mouse_preset` | Both ways. Exactly one element changes in the option file, and after coming back it holds the same values in the same order, differing only in an id the game regenerates |
| `input key --expect-screen` | World to map, verified by the anchors |

Shortcuts `M`, `I`, `J` and `K` work the same in both presets.

Not yet covered: any other screen, cutscenes, a dialog other than the two named here, the map or the inventory with a
controller, and an ultrawide window, whose layout was measured on one tab only and has no profile.

## Measured on the same setup, without running cdctl

- The compositor answers whether the session is locked, and lists the desktop's bar and dock on the top layer. A
  capture of the screen and one of the window of a fullscreen game match, so a fullscreen window hides that layer.
- The option file was two hours older than a running process, so starting the game does not rewrite it.
- Xwayland's RandR reports 49.922 Hz for a monitor the compositor reports at 49.953 Hz.
- The X server has the `XWAYLAND` extension, and the compositing manager selection has an owner.

## Not tested with the game

- Any other desktop: GNOME, KDE, Sway, a plain X session.
- gamescope, nested or as the session. Its nested state is recognized from the process tree.
- Steam Deck, and Steam from Flatpak, whose display fallback rests on automated tests.
- Any other language or build.
- A capture while the game window is not focused or is on a hidden workspace. Until this is tested, such a result
  lists `capture.frame_is_current` under `not_verified`.
- A locked session, and a game that is not fullscreen under a surface on the top layer. These rules are covered by
  automated tests only.

## Automated, without the game

| Suite | Runs against |
| --- | --- |
| `test/unit` | A fake X server speaking the protocol over a socket, a fake `/proc`, fake Steam trees, fake external programs |
| `test/integration` | A real X server (Xvfb), with windows created through the protocol |

CI runs both on Ruby 3.4 and 4.0, and starts the program on Windows and macOS to confirm it answers within its
contract there.
