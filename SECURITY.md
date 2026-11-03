# Security

Report a vulnerability through a private security advisory on this repository.

## What cdctl touches

| Thing | Access |
| --- | --- |
| Steam's library and manifest files | Read |
| `/proc`: process names, arguments and a fixed list of environment variables | Read |
| The game's X server | Read: window properties, geometry, images, how many keys are down. Write, only under an `input` command: XTEST key, button and pointer events |
| Xauthority files, for the display in use | Read, and the cookie goes only to that X server, if its socket belongs to the same user or to root |
| The compositor's status command | Read, and nothing about any window but the game's is kept or reported |
| The game's option file | Read |
| `$XDG_STATE_HOME/cdctl` | Write, with files readable by their owner alone |

A lease token appears once, in the answer to `lease acquire`, and only its hash is stored. The lease stops programs that
ask for it. Anything running as the same user could read or replace its file, so it is coordination and not a security
boundary.

Captures can show what is on the player's screen, which is why they are private files, and why a capture reads the game
window rather than the desktop. A result never holds image data. What keeps other windows out of a capture:

- With a compositing manager, which every Wayland desktop has, X keeps each window's pixels apart. Without one, X leaves
  a covered part of a window undefined and in practice returns what covers it, so the result lists
  `capture.only_the_game` under `not_verified`.
- The screen backend runs only while two fresh looks at the compositor, one on each side of the capture, prove the game
  alone is on that rectangle. Otherwise the frame is discarded.
- With a surface that can be an authentication prompt over the game, or a locked session, no capture is taken at all.

A window title can name a bank or a private document, and every result ends up in a caller's log, so no title or class
of another window is read into a result. The price is that cdctl cannot say what an active window is.

To notice a person during a send, cdctl asks the X server for input events from every device while an `input` command
runs. The X server sends keycodes with them, as it does to any client that asks, and cdctl discards them unread: only the
kind of event and the device are used, and only counts reach a result. The same goes for which keys are down. While
another program has the focus, its keys do not reach this X server at all.

Input needs a lease and a focused game, and it stops at a surface that can be an authentication prompt. cdctl never types
into, answers, dismisses or works around such a prompt.

cdctl never prints the environment of another process beyond `DISPLAY`, never writes to the game's files, its saves or
its settings, and starts other programs only by argument vector, never through a shell.
