# Contributing

Thanks for considering a contribution to review.nvim.

## Before you start

Read [AGENTS.md](AGENTS.md) for the repo map, coding conventions, and gotchas — it's the
canonical dev-workflow doc for both humans and AI agents working in this codebase.

## Dev workflow

1. Make your change in the relevant `lua/review/*.lua` module.
2. Add or update a test in `tests/` (one file per concern, e.g. `*_spec.lua`).
3. Run `just test` (or `just test-file tests/<name>_spec.lua` while iterating).
4. Update `README.md` (and `doc/review.txt` if user-facing commands/keymaps changed).
5. Keep diffs small and focused.

## Commit messages

This repo uses [Conventional Commits](https://www.conventionalcommits.org/) — `feat:`, `fix:`,
`chore:`, `docs:`, `refactor:`, `test:`, `build:`, `ci:`, `perf:`. Releases and `CHANGELOG.md` are
generated automatically from these via [release-please](https://github.com/googleapis/release-please),
so please don't hand-edit the changelog or version files in your PR.

## Reporting bugs / requesting features

Open a [GitHub Issue](https://github.com/tkolleh/review.nvim/issues). For security issues, see
[SECURITY.md](SECURITY.md) instead.
