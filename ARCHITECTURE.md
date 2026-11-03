# Architecture

## The rule everything follows

cdctl works on any machine that runs the game, so what is true of one machine never reaches the code. Facts about
the game itself (its Steam app id, its executable) are constants in `lib/cdctl/game.rb`. Everything else is
discovered at run time, and what cannot be discovered is reported as unknown. `test/unit/conventions_test.rb`
refuses home directories, video output names, fixed display sizes and desktop-specific helpers in shipped code.

## Layers

```text
cli/            Command registry, parser, help, exit statuses. Knows nothing about the game.
commands/       One class per command. Each returns a Result or raises an Error.
invocation.rb   The result contract.
error_codes.rb  Stable error codes and the exit status of each category.

observer.rb     One look at the machine, read only. Produces a Snapshot.
snapshot.rb     What that look found, and the refusals for commands that need the game.

steam/          Steam's own files: roots, libraries, manifests.
game/           The game's process, option file and version.
x11/            An X11 client over the Unix socket, in Ruby alone.
game_window.rb  Finds the game's window on one X server.
compositor.rb   Optional enrichment from a compositor driver.
modals.rb       Whether a system dialog may be over the game.
resolution.rb   Every number called a resolution, kept apart.
capture/        Frames, PNG writing and the capture backends.
ledger.rb       First sighting of each process, for detecting later display changes.
observation_store.rb  What a caller last saw, for refusing stale coordinates.
lease.rb, lease/      Exclusive ownership of input between programs.
input/          Guards, the sentinel, the journal and the watch on other input.
recognition/    Signatures, anchors and profiles: which screen is on the window.
driving.rb      Moving between recognized screens.
profiles/       What was measured on the real game, per build, language and aspect ratio.

capabilities.rb What works here, proven by trying it.
doctor.rb       What is missing here, and how to fix it.
```

## Decisions

### X11 first, compositor optional

The game draws through X on every Proton setup that does not opt into native Wayland, whatever the desktop is. Talking
to the game's own X server covers GNOME, KDE, wlroots compositors, plain X sessions and a nested gamescope with one
code path. Its address comes from the game's `DISPLAY`, and the desktop's is tried only when that one cannot be reached,
as with a sandboxed Steam, whose number exists only inside the sandbox. The window's own properties then prove whether
it was the right server. Reading the window itself also means that a capture and a coordinate share one pixel space,
which spares every compositor's scaling rules, and that a capture holds only the game wherever a compositing manager
keeps windows apart. Where none does, the result says so.

A compositor driver adds what X cannot see: the real monitor mode, whether the game is the active window and the
surfaces drawn over the game. Each answer it cannot give becomes unknown and appears in `not_verified`. It keeps nothing
about any other window. Adding a desktop means adding a driver, and nothing else changes.

### Clear needs proof

`modals.status` is `clear` only when the game is the active window, the session is known not to be locked and nothing on
the overlay or top layer can be over it. A prompt can be an ordinary window, which only shows as another window being
active, so that case is `unverified` rather than `clear`, and telling them apart would mean reading another program's
window. A surface that can be a prompt stops every capture, including the one backend that would not show it, because
the person has a decision to make.

### Two looks around a screen capture

grim reads the composited screen, where anything on top of the game ends up in the file. A state read earlier says nothing
about the moment the pixels were taken, so `Capture::ScreenGuard` asks the compositor again before and after, and the
frame is kept only if both looks prove the game alone was on that rectangle. X11 stays the first choice.

### No dependencies

The X11 client, the PNG writer and the option file reader are small and written here, so the gem has no runtime
dependency and no native extension. libX11, libXtst and an image library were each avoidable, and each would be one
more thing that differs between machines.

### No service

Nothing keeps running between commands. The cost is that a display mode at launch is known only when `cdctl game launch`
started the game; for a game started elsewhere, the ledger records the first sighting and detects changes from there.
Before that sighting the answer is unknown.

### A lease never expires

Two programs on one machine must not send input at once, and a JSON file alone cannot stop that, so each change happens
under `flock` and lands with an atomic rename. `flock` ends with its process, so a crash leaves no lock behind, and the
rename means a crash leaves the previous state whole.

Expiry is the tempting design and the wrong one: a slow owner would lose its lease without knowing, and the next owner
would act over it. So time, a dead process and a restart only raise `orphan.suspected`, and ending a lease takes an
explicit, logged takeover. Each acquire raises a generation, and a token is checked against the current holder under the
lock, so a message delayed from an old owner can neither end a newer lease nor revive a finished one. The file stores a
hash of the token. A process id alone would prove little here, since the shell running one command dies right after it,
so only a process the caller names with `--holder-pid` counts.

### A key is never left down

The X server keeps a key pressed until someone releases it, whoever pressed it and whether or not they still exist. An
`ensure` block covers errors and signals, and nothing covers `SIGKILL`, so three layers hand off to each other:

1. The command releases in `ensure`.
2. A sentinel, forked before the press, runs in its own session, ignores ordinary signals and watches a pipe from the
   command. If the pipe closes without a "done", or a hold outlives its deadline, it releases. If the sentinel dies, the
   command sees its pipe close and ends the hold.
3. A journal is on disk before the press. If both processes die together, `status` reports it and the next `input`
   command releases exactly what it names, before sending anything else.

The press waits for the sentinel to confirm, so nothing is ever held without cover. What is under test is what happens
when a process dies, so `test/integration` kills real ones against a real X server.

### A person outranks a lease

A lease cannot stop the person at the keyboard, so input watches for them. XI2 raw events carry a source device, and
everything a person does through the compositor arrives from a device other than XTEST, while another program using
XTEST shows up as more XTEST events than cdctl sent. A key or a button stops the send, and so does more than a little
pointer motion, since a hand resting on a mouse produces a few events. Those events hold keycodes, and they are never
read: only the type and the device leave `X11::XInput`, so this cannot log what someone types. `QueryKeymap` before each
press catches a key already held, and its answer is reduced to a count for the same reason.

Focus alone is not enough. With a real authentication dialog open over the game, both the X server and the compositor
still report the game as focused, measured on the tested setup. Only the surface on the overlay layer shows the dialog,
which is why input checks `modals` before every send and every quarter of a second during a hold.

### Screens are told apart by reduced signatures

The repository holds no game pixels. An anchor is a rectangle, in fractions of the window height, and a small grid of
averages from that rectangle, with cells too large for a letter or an icon to be read back. Correlation between grids
ignores brightness and contrast, so a label matches over a light map as it does over a dark forest. Luma recognizes text
and icons. A warm channel, how much redder than blue a pixel is, tells a selected entry from the others whatever is behind
it. On 83 real frames, the screens in the first profile were all told apart: an anchor scores 0.97 to 1.00 where it
belongs and at most 0.66 elsewhere, in about 30 ms for the whole frame.

Everything that varies is in the profile, keyed by build, language and aspect ratio. Outside it, recognition answers
unknown with the reason, and commands that need it answer `UNSUPPORTED_BUILD` without sending anything. A screen known only
by the HUD is also tied to the HUD scale it was measured with. A profile placed under `$XDG_DATA_HOME/cdctl/profiles`
takes precedence over what ships.

### One input, then wait

Menus in this game stall for seconds at a time and present no new frame meanwhile, so an input that looks ignored has
usually just not shown yet. Measured: a key pressed during a stall appeared to do nothing, and the next one seemed to
apply to the previous screen. The same stall makes a second key dangerous, since `M` on an open map closes it. So each
step sends once and then waits for the screen it expects, up to a timeout, and fails instead of trying again. A screen
counts only after two looks in a row, since a frame in a transition can match by chance, and the next input waits a moment
longer, because a click right after a menu appeared was seen to do nothing while the same click later worked.

Routes come from the transitions in the profile, all observed on the game, and are searched from wherever the game really
is. Some hold only in one context: Escape from the settings returns to wherever they were opened from, and what is on the
screen says which.

### A setting changes only through the menu, and the file is the proof

cdctl never edits the option file. `settings set` predicts the one element that should change, walks the menu, confirms
the dialog once it is recognized, and compares the file afterwards, leaving out the ids the game regenerates on every
save. Any other difference fails, with the way back in the answer. Measured: applying the other keyboard preset removes
exactly that element from the file, and applying it back returns the same values in the same order.

### Unknown is an answer

A value is reported with where it came from, or as unknown with a reason. Nothing is filled in because it is usually
true. In particular, a window's size is never reported as the game's resolution, and a field missing from the
option file is reported as missing.

### Secrets stay out

Only a fixed list of variables is read from another process's environment. X11 cookies go to the X server and nowhere
else. cdctl reads named files only, and never scans the directories of other tools.

## What is known about the game's resolution

From captures and option files of one installation, build 26361232:

| Screen the game sees | Window | `_viewportSize` | Menu | Image |
| --- | --- | --- | --- | --- |
| 3440x1440 | 3440x1440 | absent | 3440X1440 | One to one |
| 3440x1440 | 3440x1440 | 2560 1440 | 2560X1440 | Stretched horizontally by exactly 3440/2560 |
| 2560x1440, nested | 3440x1440 outside | absent | 2560X1440 | Side bars, from the nested compositor's fit mode |

The field appeared in 4 of 38 stored option files, each time with a resolution chosen in the menu that differed from
the screen. The likely rule is that it exists only when the choice differs from the screen, and that without it the
game follows the screen at launch. That rule has not been tested on purpose, so cdctl reports the field and does not
predict from it, beyond inferring `stretched` or `native` from a stored resolution. With no stored resolution it answers
unknown: a mode changed after the launch leaves a window that fills the screen around an image of the old size, unless
cdctl itself launched the game and recorded the display at that moment.

The game writes the file when settings are applied and not when it starts: a running process was seen to be two hours
newer than the file. So a file older than the process is the one the process read, and a newer one may describe nothing
yet, which makes `presentation` unknown.

Layout measured on one settings tab: within 16:9, positions scale with height to within 3 pixels between 1080p and
1440p. At 3440x1440, sizes and vertical positions match the 2560x1440 frame, and horizontal positions gain a margin of
40 pixels on both sides. A UI profile therefore needs an edge reference and a margin per aspect ratio, not one scale.
