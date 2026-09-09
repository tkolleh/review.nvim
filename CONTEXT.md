# review.nvim

Neovim plugin for annotating diffs with review comments (Note/Suggestion/Issue/Praise), persisted
per git branch to a shared, multi-writer DuckDB store.

## Language

**Comment Clear**:
The `clear_comments` keymap action. Soft-deletes every comment (all authors) for the current
branch by stamping `deleted_at`, without touching the underlying storage file. Recoverable via
direct DuckDB access until the Hard-Delete Sweep runs.
_Avoid_: "wipe", "reset" (see Storage Reset — a different, unrecoverable operation)

**Storage Reset** (`:Review clear`):
Full deletion of the per-branch `.duckdb` file itself. The only path that can recover from a
stale/incompatible schema (e.g. a missing generated column). Not recoverable.
_Avoid_: "clear" alone — ambiguous with Comment Clear, which is row-level and recoverable

**Soft-deleted comment**:
A comment row with `deleted_at` set to the epoch time it was cleared. Excluded from all normal
reads (list, export, edit/delete staleness checks) but still physically present in the DuckDB file
until the Hard-Delete Sweep removes it.
_Avoid_: "deleted comment" alone — ambiguous with a row that's already been hard-deleted

**Retention window**:
The 7-day period after which expired data is permanently removed. Applies to both a soft-deleted
comment's `deleted_at` and an inactive per-branch storage file's mtime. Governed by
`session_retention_seconds` in config.

**Hard-delete sweep**:
The row-level pass that permanently removes comments whose `deleted_at` is older than the
Retention window.

**Session retention sweep**:
The existing file-level pass (`cleanup_expired_now`) that deletes an entire per-branch storage
file once its mtime exceeds the Retention window.
