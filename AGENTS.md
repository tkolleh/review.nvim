# AGENTS.md

## Project Overview
review.nvim is a Neovim plugin that adds code review annotations on top of
[codediff.nvim](https://github.com/esmuellert/codediff.nvim): comment on lines/ranges in a diff
view, persist comments per git branch, export as AI-friendly Markdown. Plain Lua plugin
(`lua/review/*` + `plugin/review.lua`), tested with plenary.nvim.

`tkolleh/review.nvim` (`origin`) is a **hard fork** of `georgeguimaraes/review.nvim` (`upstream`
remote), diverged as of `v2.0.0`: storage was rewritten onto DuckDB (multi-writer) and the
direction shifted toward general-purpose multi-author commenting.

## Architecture
- Layering: `store.lua` (in-memory cache, sync reads) -> `storage.lua` (DuckDB persistence, schema
  bootstrap, 7-day session sweep) -> `duckdb.lua` (short-lived `duckdb <db> -c "<sql>"` subprocess
  per call via `vim.system`; `query_with_retry` retries on lock contention only).
- Loading persisted comments is async: `store.sync_from_storage(callback)` (renamed from
  `store.load()`; grep for `store.load(` before trusting a remaining caller).
- DB files live in `~/.local/share/nvim/review/{project-hash}-{branch}.duckdb`, scoped per git
  branch or explicit revision range (`storage.set_revisions`).
- `review_comments.color_dark`/`color_light` are `GENERATED ALWAYS AS` columns; the schema is
  mirrored in `skills/review-nvim/main.py`'s `SCHEMA_SQL` — keep both in sync.
- `specs/review-storage.allium` is the behavioural spec for storage; consult it before changing
  `storage.lua`/`duckdb.lua` semantics. `docs/research/` is background, not authoritative.

## Commands
- Run `just --list`; `just test` runs the full suite, `just test-file tests/<name>_spec.lua` one spec.
- Needs Neovim >= 0.11, codediff.nvim, nui.nvim, and the `duckdb` CLI on `$PATH`. Tests clone
  plenary.nvim into `/tmp/plenary.nvim` if `PLENARY_DIR` is unset.
- No linter/formatter is configured; match the style of the file you're editing.

## Conventions
- Never add a long-lived DuckDB connection or FFI binding (crash isolation, `vim.system` timeout).
- Preserve per-branch/revision-range storage scoping so comments don't leak across reviews.
- `pcall(require, "codediff...")` before use; on failure `vim.notify(..., ERROR)` with title
  `"review.nvim"`.
- Favor pure helpers and tagged shapes over optional-field soup. `vim.json.decode` turns JSON
  `null` into `vim.NIL`, not `nil` — see `OptionalFieldsPersistAsAbsent` in the Allium spec.
- New setup-time side effects in `init.lua` go behind its `initialized` guard; keep the
  `vim.g.loaded_review` guard in `plugin/review.lua`.
- Add a spec in `tests/` (one file per concern) with every change; keep diffs small.

## Gotchas
- codediff session detection is timing-sensitive (`vim.defer_fn` retries in `init.lua`). If hooks
  don't attach, suspect that race first.
- `codediff.ui.lifecycle` is unpinned internal API and has broken review.nvim via an unannounced
  rename; check upstream renames first.
- Tests run as concurrent `nvim --headless` processes; each needs its own
  `REVIEW_NVIM_TEST_DATA_DIR` (see `tests/minimal_init.lua`) or they hit DuckDB's single-writer lock.
- DuckDB rejects `ALTER TABLE ... ADD COLUMN ... GENERATED ALWAYS AS`, and bootstrap is
  `CREATE TABLE IF NOT EXISTS`, so new generated columns never reach old `.duckdb` files. By
  design: `:Review clear` is the reset path; no migration code.
- Comments expire after 7 days, so stale manual-testing state may be a prior session.
- Releases are automated by `release-please`; never hand-edit `CHANGELOG.md`,
  `.release-please-manifest.json`, or versions. A major bump comes from a `BREAKING CHANGE:` footer.

## Agent Rules
- For anything touching comment storage/schema, use the repo's `skills/review-nvim/SKILL.md`
  instead of ad-hoc DuckDB queries.
- Never run destructive commands (force-push, hard reset, branch deletion, production deploys)
  without explicit human confirmation.
- Do NOT commit secrets, credentials, or PII.

## When You're Stuck
- Ask 1 targeted question instead of guessing.
- If commands fail due to environment/tooling, report the exact error and STOP rather than looping.
- Prefer the smallest reproducible check that validates the change.
- When uncertain about architectural decisions, ask before implementing.
