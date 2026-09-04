# AGENTS.md

## Project Overview
review.nvim is a Neovim plugin that adds code review annotations on top of
[codediff.nvim](https://github.com/esmuellert/codediff.nvim). It lets you comment on lines/ranges
in a diff view (Note/Suggestion/Issue/Praise), persists comments per git branch, and exports them
as AI-friendly Markdown (clipboard, preview split, or [sidekick.nvim](https://github.com/folke/sidekick.nvim)).
Distributed as a standard Lua Neovim plugin (`lua/review/*` + `plugin/review.lua`), tested with
plenary.nvim.

`tkolleh/review.nvim` (`origin`) is a **hard fork** of `georgeguimaraes/review.nvim` (`upstream`,
still configured as a git remote), diverged as of `v2.0.0`: the storage layer was rewritten onto
DuckDB (multi-writer support) and the project direction shifted toward general-purpose
multi-author commenting. `v2.0.0` is reached via a `BREAKING CHANGE:` footer on a Conventional
Commit, letting the existing `release-please` automation compute and PR the major bump itself —
don't hand-edit `.release-please-manifest.json`/`CHANGELOG.md` for this, same as any other
release (see Gotchas below).

## Repo Map
- `plugin/review.lua` - defines the `:Review` user command and its subcommands (open, commits,
  close, export, preview, sidekick, clear, list, toggle); entrypoint loaded automatically by Neovim.
- `lua/review/init.lua` - `setup()` and the public `M.open/close/export/...` API; wires up
  autocmds that detect codediff.nvim sessions (`TabEnter`, `TabClosed`, `User CodeDiffOpen`).
- `lua/review/config.lua` - default config, `comment_types`, `keymaps` merge/validation.
- `lua/review/store.lua` - in-memory comment cache (add/edit/delete/list) keyed by file+line/range;
  reads are synchronous against the cache, writes go through `storage.lua`/`duckdb.lua` and update
  the cache on success. Loading persisted comments is async: `M.sync_from_storage(callback)`.
- `lua/review/storage.lua` - DuckDB-backed persistence to XDG data dir
  (`~/.local/share/nvim/review/{project-hash}-{branch}.duckdb`), scoped per git branch or per
  explicit revision range (`storage.set_revisions`). Owns schema bootstrap and the 7-day session
  sweep. `review_comments.color_dark`/`color_light` are `GENERATED ALWAYS AS` columns DuckDB
  computes at insert time (hash of `author` into a fixed WCAG-validated palette) — mirrored in
  `skills/review-nvim/main.py`'s own `SCHEMA_SQL` copy, keep both in sync.
- `lua/review/duckdb.lua` - runs every storage read/write as a short-lived `duckdb <db> -c "<sql>"`
  subprocess via `vim.system` (never a long-lived connection or FFI); `query_with_retry` retries on
  lock-contention errors only, per `specs/review-storage.allium`.
- `lua/review/comments.lua` - cursor/visual-selection comment creation, editing, listing.
- `lua/review/marks.lua` - signs, line highlights, and virtual-text rendering for comments.
- `lua/review/popup.lua` - the nui.nvim input popup used to add/edit a comment.
- `lua/review/picker.lua` - commit picker modal for `:Review commits`.
- `lua/review/hooks.lua` - integration hooks into codediff.nvim session lifecycle.
- `lua/review/keymaps.lua` - sets/clears the diff-view keymaps (readonly vs edit mode).
- `lua/review/export.lua` - Markdown generation and clipboard/sidekick/preview export.
- `lua/review/highlights.lua` - defines `ReviewNote`/`ReviewSuggestion`/`ReviewIssue`/`ReviewPraise`.
- `lua/review/utils.lua` - small shared helpers.
- `tests/` - plenary.nvim busted-style specs, one file per concern (see Common Commands).
- `doc/review.txt` - Vim helpfile (`:help review`), generated/maintained alongside README.
- `specs/review-storage.allium` - Allium behavioural spec for the storage backend (multi-writer
  guarantees, retry/reject rules); consult before changing `storage.lua`/`duckdb.lua` semantics.
- `docs/research/` - background research docs (DuckDB FFI vs CLI tradeoff, storage backend design,
  agent-comment-authoring) that motivated the storage migration; context, not authoritative spec.

## Setup
- Prerequisites: Neovim >= 0.11, [codediff.nvim](https://github.com/esmuellert/codediff.nvim),
  [nui.nvim](https://github.com/MunifTanjim/nui.nvim), the `duckdb` CLI on `$PATH` (comment
  storage), and [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) for running tests.
- Install as a plugin via your package manager (see README for a lazy.nvim example). There is no
  separate build step — it's plain Lua loaded directly by Neovim's runtime path.
- Tests clone plenary.nvim automatically into `/tmp/plenary.nvim` if `PLENARY_DIR` is unset (see
  `tests/minimal_init.lua`).

## Common Commands
| Command | Purpose |
|---------|---------|
| `make test` | Run the full plenary test suite headlessly (`tests/minimal_init.lua`) |
| `make test-file FILE=tests/store_spec.lua` | Run a single spec file |

There is no configured linter or formatter in this repo (no `.stylua.toml`/`.luacheckrc`) —
match the existing style in the file you're editing.

## Coding Conventions
- Modules return a table `M` and are required by full path, e.g. `require("review.store")`.
- Plugin-load guard: `plugin/review.lua` checks `vim.g.loaded_review` before registering the
  `:Review` command — don't remove this guard.
- `init.lua` uses `initialized` to make `setup()` idempotent; keep new setup-time side effects
  (autocmds, highlights) behind that guard too.
- codediff.nvim is an optional runtime dependency — always `pcall(require, "codediff...")` before
  using it, and `vim.notify(..., vim.log.levels.ERROR)` with title `"review.nvim"` on failure,
  matching the existing pattern in `init.lua`.
- Config/keymaps follow a merge-with-defaults pattern in `config.lua` — new options should be
  added to the defaults table there, not hardcoded in call sites.
- Comment types (`note`/`suggestion`/`issue`/`praise`) and their icons/highlight groups are
  data-driven from `config.comment_types` — adding a new type means updating that table plus the
  corresponding `Review<Type>` highlight in `highlights.lua`, not adding new branches elsewhere.
- Storage is intentionally scoped per git branch (or explicit revision range via
  `storage.set_revisions`) so comments don't leak across unrelated reviews — preserve that
  scoping when touching `storage.lua`.
- All storage access goes through short-lived `duckdb` CLI subprocess calls (`duckdb.lua`) — never
  add a long-lived DuckDB connection or libduckdb/FFI binding; see `specs/review-storage.allium`'s
  `CommentAuthor` surface `@guidance` for why (crash isolation + `vim.system`'s timeout/kill vs. an
  unrecoverable in-process FFI fault).
- `store.load()` was renamed to async `store.sync_from_storage(callback)` during the DuckDB
  migration (commit `3522e08` fixed one caller that missed the rename) — grep for `store.load(`
  before assuming any remaining caller is correct.
- Favor a functional style within Lua's constraints: pure helper functions over shared mutable
  state, and explicit tagged/discriminated shapes over overloaded optional fields wherever the
  domain has real algebraic structure (e.g. a `Comment`'s scope is really a sum type — file-level
  vs. single-line vs. range — even though it's currently modeled as loosely-related optional
  fields). This isn't cosmetic: `Comment.line_end` being an implicit optional field, combined with
  `vim.json.decode`'s default of turning JSON `null` into the `vim.NIL` sentinel instead of Lua
  `nil`, is exactly the shape of bug this convention exists to prevent — see
  `specs/review-storage.allium`'s `OptionalFieldsPersistAsAbsent` guarantee.

## Change Workflow
1. Make your change in the relevant `lua/review/*.lua` module.
2. Add/update a spec in `tests/` (one file per concern, following existing naming like
   `*_spec.lua`).
3. Run `make test` (or `make test-file FILE=tests/<name>_spec.lua` while iterating).
4. Update `README.md` (and `doc/review.txt` if user-facing commands/keymaps changed).
5. Keep diffs small and focused; do not commit secrets or credentials.

## Gotchas
- codediff.nvim session detection is timing-sensitive: `init.lua` uses `vim.defer_fn` retries
  (`try_setup`, up to 5 attempts at 100ms/200ms) waiting for the codediff session/buffers to exist
  before attaching hooks/keymaps. If review hooks aren't attaching, suspect this race rather than
  the hook logic itself.
- Comments persist to a DuckDB file per branch/revision-range in `~/.local/share/nvim/review/` and
  expire after 7 days — stale state during manual testing may come from a prior session rather
  than a bug.
- Tests run as separate concurrent `nvim --headless` subprocesses under plenary's
  `PlenaryBustedDirectory`. Each spec-file process must get an isolated `REVIEW_NVIM_TEST_DATA_DIR`
  (see `tests/minimal_init.lua`) — without it they race on the same real `.duckdb` file and hit
  DuckDB's single-writer lock ("Conflicting lock is held" IO Error) instead of running cleanly.
- Releases are automated via `release-please` (`.github/workflows/release-please.yml`,
  `release-please-config.json`, `.release-please-manifest.json`) — don't hand-edit `CHANGELOG.md`
  or version numbers; they're generated from Conventional Commit messages.
- DuckDB (confirmed on 1.5.5) rejects `ALTER TABLE ... ADD COLUMN ... GENERATED ALWAYS AS` on an
  existing table ("Adding generated columns after table creation is not supported yet"). Since
  `storage.lua`'s bootstrap is `CREATE TABLE IF NOT EXISTS` (a no-op on an existing file), adding a
  new generated column never reaches a `.duckdb` file created before that column existed — by
  design (see the `color_dark`/`color_light` decision above), not a bug. `:Review clear` is the
  reset path for a stale schema; there's deliberately no migration/backfill code.

## When You're Stuck
- Ask 1 targeted question instead of guessing
- If commands fail due to environment/tooling, report the exact error and STOP rather than looping
- Prefer the smallest reproducible check that validates the change
- When uncertain about architectural decisions, ask before implementing
