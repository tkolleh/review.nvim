# Research: agent-authored review comments (review.nvim vs. tuicr)

Captured from a research session investigating whether an external AI agent can write review comments into `review.nvim` — either as a file written before a session opens, or live while a session is open — and how `tuicr` solves the same problem.

## 1. review.nvim's comment storage today

### Persistence model

- `lua/review/store.lua` holds an in-memory table `M.comments: table<file_path, Comment[]>`.
- `lua/review/storage.lua` persists that whole table to a single JSON file on every mutation (`store.persist()` calls `storage.save(M.comments)` from `store.add`/`store.update`/`store.delete` — `store.lua:27-29,78,171,189`).
- There is **no debounce/batching** — every add/edit/delete is an immediate, synchronous, whole-file overwrite.
- **No `VimLeave`/`VimLeavePre` autocmd exists anywhere in the plugin.** None is needed: because every mutation already persists immediately, there is no "dirty state" to flush on exit. Comments survive `:q`, `:qa`, closing the terminal, or a crash — the only loss window is a mutation that was in flight at the exact moment of a crash (in practice negligible, since `io.open`/`file:write`/`file:close` complete synchronously in the same Lua call).

### Storage path derivation (`storage.get_storage_path`, `storage.lua:59-83`)

```
~/.local/share/nvim/review/{hash(git_root)}-{safe_branch}.json
```

or, when reviewing an explicit commit/revision range (`storage.set_revisions`):

```
~/.local/share/nvim/review/{hash(git_root)}-{short_rev1}_{short_rev2}.json
```

- `hash()` is a simple base-31 rolling hash over the git root path (`storage.lua:44-50`) — trivial to reimplement in any language.
- `safe_branch` replaces everything outside `%w%-_` with `_`.
- Storage is **intentionally scoped per branch (or per revision range)** so comments from unrelated reviews don't leak into each other (documented intent, project `CLAUDE.md`).
- Files auto-expire after 7 days (`storage.lua:100`, `EXPIRY_SECONDS`), swept once per Neovim session via `cleanup_expired()` on the first `store.load()`.

### JSON schema

```jsonc
// table<file_path, Comment[]>
{
  "lua/review/init.lua": [
    {
      "id": "comment_<unix_ts>_<counter>",
      "file": "lua/review/init.lua",
      "line": 42,          // 1-indexed; 0 means "file-level comment"
      "line_end": 45,       // optional; omitted if equal to line
      "side": "new",        // "old" | "new"; defaults to "new"
      "type": "issue",      // "note" | "suggestion" | "issue" | "praise"
      "text": "comment body",
      "created_at": 1735000000
    }
  ]
}
```

Field notes:
- File-level comments use the sentinel `line == 0` rather than a separate container (`store.lua:114-122`, `marks.lua:82`) — every consumer has to know about this special case.
- One comment per line/range only — `comments.lua:20-24` explicitly refuses to add a second comment at an already-commented line/range ("Comment already exists at this line. Use edit instead.").
- No `author` field at all — the format assumes a single writer.

### Why writing comments requires a live UI session (not just a CLI call)

Every comment-creation entry point (`comments.add_at_cursor`, `file_comment`, `add_for_range`) goes through `hooks.get_cursor_position()` (`hooks.lua:102-147`), which requires:

1. A live `codediff.ui.lifecycle` session already attached to the tabpage (set only by `hooks.on_session_created`, itself only triggered by `init.lua`'s `TabEnter`/`User CodeDiffOpen` autocmds).
2. A real Neovim window with a live cursor position.
3. codediff.nvim having already parsed the diff and created its buffers.

There is no session-independent public API (e.g. a `:Review addcomment <file> <line> <type> <text>` command) that bypasses cursor/session state. `store.add()` itself has no such requirement — the constraint is entirely in the comment-creation layer (`comments.lua`/`hooks.lua`), not the store.

**Conclusion:** headless `nvim --headless -c ... +qa` is not a practical way for an agent to add comments — it would require scripting the entire async UI bring-up sequence (open Neovim, `:CodeDiff`, wait for codediff's session, position a cursor, then call the Lua function), which is exactly the kind of timing-fragile sequence this repo's own `CLAUDE.md` Gotchas section warns about for `init.lua`'s `try_setup` retry loop.

### The multi-writer race (current design)

`store.persist()` writes the **entire in-memory table**, unconditionally, with no read-before-write and no lock. Consequences:

- **Agent writes JSON before Neovim opens a session on that branch/file:** safe. There is no in-memory copy yet to clobber it; `store.load()` reads the file fresh on the next `:Review open`.
- **Agent writes JSON while a review.nvim session is already open on the same file:** unsafe. Neovim's `store.comments` has no idea the file changed (no watcher, no polling). The next local mutation inside Neovim calls `persist()` and overwrites the whole file with Neovim's stale in-memory copy, silently discarding whatever the agent wrote.

## 2. How tuicr solves the same problem

Verified from tuicr v0.19.1's real on-disk data (`~/Library/Application Support/tuicr/reviews/`) and binary strings (`/opt/homebrew/Cellar/tuicr/0.19.1/bin/tuicr`), not from the GitHub README.

### Storage layout

```
~/Library/Application Support/tuicr/reviews/
├── index.json                  # session-key -> [{path, kind, updated_at, display}, ...]
├── active_sessions.json        # registry of currently-live sessions
├── active_sessions.json.tuicr.lock   # lockfile guarding the registry
└── sessions/
    └── <opaque-hash>.json      # one file per review session
```

- `index.json` keys sessions by a stable identity string, e.g. `gh:owner/repo/pr/278` for PR reviews (local checkouts presumably get an analogous local key). Each entry points at a `sessions/<hash>.json` file plus display metadata (comment/file counts).
- The session filename hash is **not** derived from branch name the way review.nvim's is — session identity is tracked via `index.json`, not via a reproducible filename scheme.

### Session JSON schema (observed, real file)

```jsonc
{
  "id": "uuid",
  "version": "1.3",
  "repo_path": "forge:host/owner/repo",
  "branch_name": "...",
  "base_commit": "...",
  "diff_source": "pull_request",       // or local/commit-range equivalents
  "commit_range": null,
  "pr_session_key": {
    "repository": { "kind": "git_hub", "host": "...", "owner": "...", "name": "..." },
    "number": 278,
    "head_sha": "..."
  },
  "remote_comments_visibility": "unresolved",
  "commit_selection_range": null,
  "created_at": "2026-07-29T19:39:23.736466Z",
  "updated_at": "2026-07-29T19:59:40.387210Z",
  "review_comments": [ /* Comment[], review-level/unanchored */ ],
  "files": {
    "<path>": {
      "path": "<path>",
      "reviewed": false,
      "status": "modified",             // added | modified | ...
      "file_comments": [ /* Comment[] */ ],
      "line_comments": {                 // keyed by STRING line number
        "157": [ /* Comment[] */ ],
        "88":  [ /* Comment[] */ ]
      },
      "reviewed_hunks": [],
      "content_hash": 17033717964755953149
    }
  }
}
```

### Comment shape (observed, real data)

```jsonc
{
  "id": "uuid",
  "content": "comment body",
  "comment_type": "issue",             // issue | suggestion | note | praise
  "created_at": "2026-07-29T19:42:18.887555Z",
  "line_context": null,
  "side": "new",                        // "old" | "new" | null
  "line_range": { "start": 75, "end": 88 } | null,
  "author": "Augment Agent",
  "lifecycle_state": "submitted",
  "remote_review_id": 2904346,
  "remote_comment_id": null,
  "commit_id": null
}
```

### Structural differences from review.nvim

1. **Line-keyed dict of arrays vs. flat array with a `line` field.** `line_comments` is `table<line_number_string, Comment[]>` — real hash lookup by line, and a *list* per line (multiple comments per line are supported). review.nvim's store is a flat per-file array (`store.get_at_line` linear-scans it, `store.lua:128-139`) and explicitly forbids a second comment on an already-commented line/range.
2. **Three distinct containers** (`review_comments`, `file_comments`, `line_comments`) instead of review.nvim's single array with a `line == 0` sentinel for file-level comments. More schema surface, no magic numbers.
3. **Built for round-tripping with a real PR review API** — `pr_session_key`, `remote_review_id`, `remote_comment_id`, `lifecycle_state` have no review.nvim equivalent; review.nvim's storage is purely local-first and disposable (7-day TTL).
4. **`author` field exists** — multiple humans/agents can share one session distinguishably. review.nvim has no such field; every comment is anonymous/single-writer by design.

### The multi-writer solution itself

Three mechanisms, confirmed from binary strings (not the GitHub README):

1. **The CLI is the only mutation path.** `tuicr review add --session <slug> ...` is the same binary the TUI runs. An agent never writes the session JSON directly — reads/writes go through one program's logic instead of two independent writers racing on a shared file. This is the single biggest structural difference from review.nvim, which has no CLI mutation path at all.
2. **A real lockfile guards the shared registry**: `.tuicr.lock` sits next to `active_sessions.json` (confirmed string: `...reviews/active_sessions.json.tuicr.lock`). This is the contention point across concurrent `tuicr` CLI invocations — not a per-session lock; the bulk per-session files rely on mechanism 3 instead.
3. **Poll-and-reload, not read-once-trust-forever.** A documented config key `review_watch_interval_ms` drives a periodic reload cycle in the running TUI. Confirmed error/status strings:
   - `"comment reload failed"` / `"Comment reload failed"`
   - `"Failed to reload changes: "`
   - `"Discarded stale submit result (PR was reloaded)"`
   - `"Use :reload from the command line in PR mode"`

   The TUI re-reads session state from disk on an interval (and via a manual `:reload` command), and explicitly discards stale in-flight results that are superseded by a fresher reload — the opposite of review.nvim's unconditional whole-file overwrite on every local mutation.

### CLI surface relevant to agent authorship

```
tuicr review add [OPTIONS] --session <SESSION> [COMMENT]
  --session <SESSION>       session slug or path to session JSON
  --input <JSON|@FILE|->    structured input (literal JSON / file / stdin)
  --repo <PATH|OWNER/REPO>  repo selector, default "."
  --type <TYPE>             comment_types classification (default: none)
  --target-file <PATH>      omit for a review-level comment
  --line <LINE>             requires --target-file
  --end-line <LINE>         requires --line (range comment)
  --side <SIDE>             old | new (default: new)
  --username <NAME>         explicit author stamp — recommended for agents
                             ("Pass an explicit value when invoking from an
                             agent ... so human and agent comments are
                             visually distinguished")
```

`tuicr review comments --repo <path> --session <slug>` reads comments back out as JSON for an agent to consume; there is no push notification, so the `tuicr` skill's guidance to poll this command (~every 30s) during a live review mirrors the same poll-based consistency model the TUI itself uses internally.

## 3. Implications / open design questions for review.nvim

- **The "write JSON before opening a review" workflow already works today, with zero code changes**, as long as the external writer replicates review.nvim's path-derivation and comment schema exactly (see Section 1). This was the scope explicitly chosen in this research session.
- **The "write live while a session is open" workflow does not work today** and would require review.nvim to adopt something like tuicr's model:
  - a lockfile around `storage.save`/`storage.load`,
  - a reload-on-interval or manual `:Review reload` mechanism (`store.reset()` + `store.load()` + `marks.refresh()`),
  - and critically, changing `store.persist()` from an unconditional whole-table overwrite to a reload-then-merge (or at least a read-modify-write against the latest on-disk state) to avoid clobbering concurrent writers.

  This is a real, scoped feature addition, not implemented as part of this research.
- **tuicr's schema and review.nvim's schema are not directly compatible.** Field names, nesting (line-keyed dict vs. flat array), and file-level vs. line-level comment representation all differ. An agent that already speaks tuicr's format (via the `tuicr` CLI/skill) cannot point at review.nvim's JSON file and expect it to work, or vice versa. Bridging them would need either a translation/adapter step, or picking one schema as canonical for agent-authored notes and treating the other as an export target only.
- **No skill document or written spec for review.nvim's JSON schema exists anywhere in this repo.** The only on-disk documentation is `doc/review.txt`'s `review-storage` section (`doc/review.txt:229-235`), which states only the file path pattern and the 7-day expiry — not the schema, hash algorithm, or branch-sanitization rule. Everything in Section 1 above was reverse-engineered from `store.lua`/`storage.lua` source, not from existing documentation.
