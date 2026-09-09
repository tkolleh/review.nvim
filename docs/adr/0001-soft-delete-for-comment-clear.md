# Soft-delete comments on Comment Clear; hard-delete after the retention window

`clear_comments` (bound to `<C-r>`) previously reached `os.remove` on the entire per-branch DuckDB
file with no confirmation — an unrecoverable action that destroyed every author's comments and any
other state in the file, reachable via a single keystroke inside a locked review buffer. We instead
mark all rows via a `deleted_at` epoch column (`UPDATE review_comments SET deleted_at = now() WHERE
deleted_at IS NULL`), exclude soft-deleted rows from every read and staleness-check path, and let
the Hard-delete sweep remove them permanently once they exceed the Retention window (7 days) —
the same window the pre-existing but previously-unwired Session retention sweep uses for whole
files. `:Review clear` (Storage Reset) keeps `os.remove` semantics, since it's the one path that
legitimately needs the file itself gone (recovering from a stale/incompatible schema).

**Considered and rejected:**
- Keep `os.remove` on the file, just add a confirmation prompt — still destroys structural state
  (schema, indices) and every author's data in one shot; recoverability was the actual goal.
- Unscoped `DELETE FROM` with no soft-delete column — stops corrupting the file, but still
  destroys all authors' comments immediately with no recovery window.
