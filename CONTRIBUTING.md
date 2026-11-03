# Contributing

```sh
mise install          # the Ruby and tools this repository pins
bundle install
bundle exec rake check
```

`rake check` runs what CI runs, except the Ruby and operating system matrix. `CHECK_OFFLINE=1` skips the checks that
need the network. Installing Xvfb lets the integration tests run against a real X server; without it they are skipped
locally and required in CI. Nothing in it looks at your machine's game: `package:check` runs the commands that read
`/proc` and the X server only under CI, and every other test uses a fake machine, so it is safe with the game open.

## Rules

- Nothing about one machine reaches shipped code. No paths, output names, display sizes or helpers from a particular
  setup. If something varies between machines, discover it or report it as unknown.
- Unknown is a valid answer. Never fill in a value because it is usually true.
- A new way of acting on the game needs a precondition, a verification and a release of anything it holds, in that order.
- Tests never touch a real game. Use the fakes in `test/support`.
- Real captures of the game do not enter the repository. `test/fixtures/real/` is ignored for that reason. A profile holds
  reduced signatures only, and a test refuses cells small enough to read anything back from.
- Comments say why, never what. No tool demands a comment on every class or method.

## Commits and pull requests

- Conventional Commits in the imperative: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`, `ci:`.
- One pull request per coherent change. `bin/lint-commits origin/main..HEAD` checks the messages.
- A user-visible change gets a line under `## [Unreleased]` in `CHANGELOG.md`. Otherwise the pull request gets the
  `skip-changelog` label.
- Anything newly tried against the real game goes in `docs/test-matrix.md`, with what was and was not tested.
