---
name: review-nvim
description: >-
  Read and write review.nvim code-review comments directly via the duckdb CLI, for an
  AI agent collaborating with human or other-agent reviewers without opening Neovim.
  Use whenever the user asks to check, read, add, or reply to review comments on a
  branch, wants an agent to leave feedback in a code review thread, or mentions
  review.nvim, codediff.nvim review comments, or a review database/duckdb file under
  ~/.local/share/nvim/review.
license: MIT
compatibility: "duckdb CLI, python3, git"
metadata:
  audience: developers
  domain: code-review
  version: "1.1.0"
  tools: "duckdb, python3, main.py"
---

# review-nvim

Talk to the same comment thread a human is using in Neovim, from the CLI — no Neovim
required. `review.nvim` stores comments in a per-git-branch DuckDB file; this skill
reads and appends rows in that exact file via short-lived `duckdb <path> -json -c
"<sql>"` subprocess calls, mirroring `review.nvim`'s own Lua storage layer
(`lua/review/duckdb.lua`, `storage.lua`, `store.lua`) byte-for-byte in path derivation,
schema, and SQL shape. A comment added here shows up in Neovim's next
`store.sync_from_storage`, and vice versa.

## When to use / not use

- **Use:** reading existing review comments on the current branch (all, filtered by
  file, or filtered by author), adding a new comment (file-scope or line-scope) so a
  human or another agent sees it in their own `review.nvim` session.
- **Do not use:** editing, deleting, or resolving an existing comment — not supported
  in v1 (see Non-goals below). Don't reach for raw `duckdb` calls yourself once this
  skill is available; `main.py` already has the correct schema bootstrap, escaping, and
  retry behavior baked in.

## Author convention

Every `add` call requires `--author`. Pick **one** name per agent session and reuse it
for every comment you add in that session — do not invent a new name per call. Use the
form `agent:<tool-name>`, e.g. `agent:claude-code`. This form exists specifically so
agent-authored comments are visually distinguishable at a glance from the human default
author (`user`) or a human's real name — never pass `user` or a bare human name as
`--author`.

## Usage

Run from anywhere inside the `review.nvim`-tracked git repo whose branch you want to
read or comment on — the skill resolves the repo root and current branch itself via
`git`, the same way `review.nvim` does. `main.py` lives at `skills/review-nvim/` in
this repo (and is symlinked from `.claude/skills/review-nvim/` for auto-discovery) —
invoke it via that path, or whatever path it resolves to.

```bash
python3 skills/review-nvim/main.py read
python3 skills/review-nvim/main.py read --file src/foo.py
python3 skills/review-nvim/main.py read --author agent:claude-code

python3 skills/review-nvim/main.py add \
  --file src/foo.py --content "This whole module could use a docstring." \
  --author agent:claude-code --type note

python3 skills/review-nvim/main.py add \
  --file src/foo.py --line 42 --content "This branch is unreachable." \
  --author agent:claude-code --type issue

python3 skills/review-nvim/main.py add \
  --file src/foo.py --line 10 --line-end 15 --side old \
  --content "Consider extracting this into a helper." \
  --author agent:claude-code --type suggestion
```

Omit `--line` for a file-scope comment (attached to the file as a whole, not a
specific line). Pass `--line` alone for a single-line comment, or `--line` +
`--line-end` for a range. `--side` (`old`/`new`) only applies to line-scoped comments
and defaults to `new`.

`--type` is one of `note`, `suggestion`, `issue`, `praise` — matching `review.nvim`'s
own comment types; there is no fifth type and no free-text type.

## Output

Every call prints exactly one JSON object to stdout, success or failure — parse stdout,
don't scrape stderr or a traceback.

- `read` → `{"status": "success", "comments": [...]}` — the raw `review_comments` rows
  (field names: `id`, `comment_scope`, `file_path`, `line_start`, `line_end`, `side`,
  `comment_type`, `content`, `author`, `color_dark`, `color_light`, `lifecycle_state`,
  `created_at`, `updated_at`). `color_dark`/`color_light` are hex strings DuckDB derives
  deterministically from `author` (same author always yields the same colors) — informational
  only, not something `add` accepts as an argument.
- `add` → `{"status": "success", "id": ..., "created_at": ...}`.
- Any failure (not in a git repo, `duckdb` not installed, a query error) →
  `{"status": "error", "reason": "...", "stage": "read"|"add"}`, and the process exits
  with a non-zero status.

## Non-goals (v1)

- **No edit, delete, or resolve.** Modifying an existing comment requires correctly
  resolving which comment is meant when more than one exists at the same file/line
  (the disambiguation rule in `specs/review-storage.allium`'s
  `SelectingAmbiguousComment`), plus an optimistic-concurrency check
  (`expected_prior_content`) so a stale edit can't silently clobber another writer's
  change in between. That's real complexity this skill's conversational read/add use
  case doesn't need. If you need to change or remove a comment, do it from Neovim.
- **No revision-range scope.** Only the per-branch storage path is supported; a review
  session scoped to an explicit revision range (`storage.set_revisions` in
  `review.nvim`) isn't handled.

## Source of truth

This skill's schema, path derivation, and SQL must stay consistent with
`review.nvim`'s own storage layer. If `review.nvim`'s schema or path scheme ever
changes, re-derive this skill's `main.py` from these files, relative to this repo's
root:

- `lua/review/duckdb.lua` — CLI invocation contract, lock-contention retry.
- `lua/review/storage.lua` — storage path derivation, schema DDL.
- `lua/review/store.lua` — INSERT/SELECT SQL shapes, value-escaping.
- `specs/review-storage.allium` — the formal behavioral contract (scope-field
  invariants, read-your-writes guarantee, CLI-only/no-FFI rationale).
