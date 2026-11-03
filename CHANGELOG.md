# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `cdctl status` reports the Steam installation, the game process, its window, the compositor and every value called a resolution, each with its source.
- `cdctl observe` captures the game window and stores an observation, and `cdctl observation check` says whether a coordinate from it still applies.
- `cdctl screenshot` captures the game window to a PNG, with an optional region and a zoom that repeats pixels.
- `cdctl doctor` checks what cdctl needs on the machine and says how to fix what is missing.
- `cdctl capabilities` lists what works on the machine, proven by trying it, and every error code and exit status.
- `cdctl schema` prints the JSON Schema of each result.
- `cdctl observe` and `cdctl screenshot` stop with `SYSTEM_DIALOG_PRESENT` when a surface that can be an authentication prompt is over the game, or the session is locked.
- Every command answers with versioned JSON under `--json`, help and the version included, and with documented exit statuses.
- `cdctl lease` coordinates exclusive ownership of input between programs. A lease never expires by itself: a suspected orphan is reported, and ending it takes an explicit, logged takeover that fences the old token.
- `cdctl status` reports who holds the input lease.
- `cdctl input key`, `click`, `move` and `scroll` send guarded input to the focused game, checking the lease, the process, the geometry, the focus, system dialogs and other input before every send and during every hold.
- A key or button is released on an error, a signal or `kill -9`, by the command, by a sentinel process or by the next command from a journal. `cdctl input release` and `cdctl status` cover the last case.
- `cdctl observe` names the screen where a UI profile covers the build, language and aspect ratio, from reduced signatures with no game pixels. `cdctl input key --expect-screen` uses the same recognition as its check.
- `cdctl menu open` reaches a menu and proves it, sending nothing when it is already open, and `cdctl menu back` leaves one by the way known for it.
- `cdctl game launch`, `continue` and `quit` start the game through Steam, enter the saved game and leave through the menu, proving each result and never killing anything. A launch through cdctl records the display at that moment, which makes `presentation` known.
- `cdctl settings list`, `get`, `plan` and `set` read settings, and change the keyboard preset through the menu, comparing the option file with the plan and giving the way back.
