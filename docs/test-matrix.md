# Test matrix

What has been run against the real game, as opposed to the automated tests, which use a fake machine and a
real X server without the game. A setup missing from this table is untested, whatever it may look like.

## Tested with the game

| Build | Version | Language | Resolution | Desktop | Proton | Commands | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 26361232 | 2.04.05 | brazilian | 3440x1440 | Hyprland 0.56.2, Xwayland | 11.0-100 | `status`, `doctor`, `capabilities`, `observe`, `observation check`, `screenshot` (X11, grim, region, zoom) | Title screen. The X11 capture matches grim with a mean difference of 0.01 in 255 |
| 26361232 | 2.04.05 | brazilian | 1920x1080 | Hyprland 0.56.2, Xwayland | 11.0-100 | The X11 capture path only, not the commands | Settings menu. The X11 capture matches grim with a mean difference of 0.11 in 255 |

These runs came before the capture guard and the stop at a system dialog, which so far have automated tests only.

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
- A real authentication prompt over the game seen by `modals`, a locked session, and a game that is not fullscreen
  under a surface on the top layer. These rules are covered by automated tests only.

## Automated, without the game

| Suite | Runs against |
| --- | --- |
| `test/unit` | A fake X server speaking the protocol over a socket, a fake `/proc`, fake Steam trees, fake external programs |
| `test/integration` | A real X server (Xvfb), with windows created through the protocol |

CI runs both on Ruby 3.4 and 4.0, and starts the program on Windows and macOS to confirm it answers within its
contract there.
