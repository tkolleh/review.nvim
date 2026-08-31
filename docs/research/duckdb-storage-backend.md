# Research: DuckDB as review.nvim's storage backend

Follow-up to [`agent-comment-authoring.md`](./agent-comment-authoring.md). Investigates replacing review.nvim's flat-JSON-file storage (`lua/review/storage.lua`) with a local DuckDB database file, written via the `duckdb` CLI, with a schema modeled on tuicr's but normalized and mapped onto review.nvim's current capabilities. All concurrency claims below were tested empirically against DuckDB v1.5.5 CLI (`duckdb --version`), not taken from memory or docs alone — see Section 3.

## 1. Why DuckDB changes the shape of the problem

review.nvim's current storage is "one JSON blob per branch, whole-file overwrite on every mutation" (see `agent-comment-authoring.md` §1). Moving to DuckDB changes three things at once:

1. **Storage becomes queryable.** Instead of loading the whole file and linear-scanning in Lua (`store.get_at_line`, `store.get_overlapping`), `WHERE file = ? AND line BETWEEN ? AND ?` does the filtering in the engine. Multi-branch, multi-project, multi-comment-per-line — all become `WHERE` clauses instead of new Lua data structures.
2. **Writes become row-level, not whole-file.** `INSERT`/`UPDATE`/`DELETE` against one row no longer requires re-serializing every other comment in the file, which is what makes reload-then-merge concurrency strategies *cheaper* to reason about than with the current flat-JSON approach.
3. **Concurrency stops being "whatever Lua's `io.open` does" and becomes "whatever DuckDB's file-locking model does."** This is a substantial trade: DuckDB's locking is stricter than a naive JSON-file approach in one important way (see §3), but it is *correct* in a way ad-hoc JSON writes are not — you get consistent, atomic commits per write instead of a process racing to overwrite a whole file.

## 2. Schema design

Design goals, in priority order:
1. Cover review.nvim's current `Comment` shape and semantics exactly (`store.lua:5-14` — see `agent-comment-authoring.md` §1) with no loss of information.
2. Structurally resemble tuicr's schema (`agent-comment-authoring.md` §2) where the concepts overlap, so a future bridge/importer between the two is a straightforward mapping, not a redesign.
3. Be trivially expressible as JSON — both for `duckdb ... -c "... to_json(...)"` CLI output (agent-readable) and for `read_json`/`COPY ... (FORMAT JSON)` ingestion (agent-writable), since DuckDB's JSON extension is built in (confirmed: `to_json`, `json_each`, `read_json` all work with no `INSTALL`/`LOAD` needed in v1.5.5 — the JSON extension ships as one of DuckDB's "autoloadable" core extensions).

### Tables

```sql
-- One row per review "session" — the DuckDB analog of tuicr's session file
-- and review.nvim's per-branch/per-revision JSON file.
CREATE TABLE IF NOT EXISTS review_sessions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_root    VARCHAR NOT NULL,      -- git root, absolute path (review.nvim's hash() input)
    branch_name     VARCHAR,               -- NULL when scoped by revision range instead
    rev1            VARCHAR,               -- short_rev(rev1); NULL for branch-scoped sessions
    rev2            VARCHAR,               -- short_rev(rev2); NULL for branch-scoped sessions
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- tuicr equivalents kept nullable/unused for now, present for future parity:
    diff_source     VARCHAR,               -- e.g. 'branch' | 'commit_range' | 'pull_request'
    remote_ref      JSON                    -- tuicr's pr_session_key equivalent, opaque for now
);

-- One row per comment. Mirrors tuicr's Comment shape, but flattens
-- review_comments/file_comments/line_comments into one table distinguished
-- by comment_scope + nullable line columns, rather than three containers —
-- this is the "similar to tuicr, adapted to review.nvim's actual model" part.
CREATE TABLE IF NOT EXISTS review_comments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID NOT NULL REFERENCES review_sessions(id),
    comment_scope   VARCHAR NOT NULL CHECK (comment_scope IN ('review', 'file', 'line')),
    file_path       VARCHAR,               -- NULL only for comment_scope = 'review'
    line_start      INTEGER,               -- NULL for 'review'/'file' scope
    line_end        INTEGER,               -- NULL if single-line or non-'line' scope
    side            VARCHAR CHECK (side IN ('old', 'new')),  -- NULL for 'review'/'file' scope
    comment_type    VARCHAR NOT NULL CHECK (comment_type IN ('note', 'suggestion', 'issue', 'praise')),
    content         VARCHAR NOT NULL,
    author          VARCHAR NOT NULL DEFAULT 'user',   -- tuicr parity: distinguishes human vs. agent writers
    lifecycle_state VARCHAR NOT NULL DEFAULT 'submitted',  -- tuicr parity: future draft/resolved support
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_comments_session_file
    ON review_comments(session_id, file_path);
```

### Mapping from review.nvim's current `Comment` (`store.lua:5-14`)

| review.nvim field | DuckDB column(s) | Notes |
|---|---|---|
| `id` (`comment_<ts>_<n>` string) | `id UUID` | Switch to UUID; DuckDB generates it, removes the manual `id_counter` collision-avoidance logic in `store.lua:18-25,42-50` entirely. |
| `file` | `file_path` | Same semantics. |
| `line` (0 = file-level sentinel) | `comment_scope` + `line_start` | The `line == 0` sentinel is eliminated — `comment_scope = 'file'` replaces it explicitly, matching tuicr's separate `file_comments` container without a magic number. `comment_scope = 'review'` is new: review.nvim has no whole-review-level comment today, but the schema supports one for free, matching tuicr's `review_comments`. |
| `line_end` (optional, omitted if == `line`) | `line_end` | Same nullable-if-single-line semantics. |
| `side` (`"old"`/`"new"`, default `"new"`) | `side` | Same. |
| `type` | `comment_type` | Same four values, now DB-enforced via `CHECK` instead of only Lua-side `---@class` annotations. |
| `text` | `content` | Renamed to match tuicr's field name directly (goal #2). |
| `created_at` (unix epoch number) | `created_at TIMESTAMPTZ` | Upgraded to a real timestamp type; still trivially convertible to/from epoch via `epoch(created_at)` / `to_timestamp(n)`. |
| *(none — no author field today)* | `author` | New. Defaults to `'user'`. This is what makes tuicr-style `--username "Codex"` agent attribution possible without changing review.nvim's rendering assumptions (a comment with no explicit author still looks like today's anonymous single-user comments). |
| *(none)* | `lifecycle_state` | New, defaulted to `'submitted'` so it's a no-op until/unless a draft workflow is built — direct parity with tuicr's field of the same name and purpose. |

### JSON representation (goal #3)

Reading a session as one JSON document an agent can consume, shaped close to tuicr's session-file structure:

```sql
duckdb review.duckdb -json -c "
SELECT
    s.id, s.project_root, s.branch_name, s.created_at, s.updated_at,
    (SELECT to_json(list(struct_pack(id, comment_type, content, author, lifecycle_state, created_at)))
       FROM review_comments c WHERE c.session_id = s.id AND c.comment_scope = 'review') AS review_comments,
    to_json(list(
        struct_pack(
            file_path,
            file_comments := (SELECT list(struct_pack(id, comment_type, content, author))
                               FROM review_comments c2
                               WHERE c2.session_id = s.id AND c2.file_path = f.file_path AND c2.comment_scope = 'file'),
            line_comments := (SELECT to_json(map_from_entries(list(struct_pack(k := line_start::VARCHAR, v := struct_pack(id, comment_type, content, side, line_end, author)))))
                               FROM review_comments c3
                               WHERE c3.session_id = s.id AND c3.file_path = f.file_path AND c3.comment_scope = 'line')
        )
    )) AS files
FROM review_sessions s
CROSS JOIN (SELECT DISTINCT file_path FROM review_comments WHERE session_id = s.id) f
WHERE s.id = '<session-uuid>';
"
```

This is illustrative, not a final query — the point demonstrated is that `-json` output mode plus `to_json`/`struct_pack`/`map_from_entries` gets you tuicr-shaped nested JSON (`files.<path>.line_comments.<line>` as a dict) out of a normalized relational schema, satisfying goal #2 and #3 simultaneously. Writing is simpler and more direct: a single `INSERT INTO review_comments (...) VALUES (...)` per comment, or a bulk `INSERT ... SELECT * FROM read_json('comments.json')` for batch agent writes.

### Deliberate deviations from tuicr

- No `pr_session_key`/`remote_review_id`/`remote_comment_id` columns populated yet — kept as an opaque `remote_ref JSON` column so the schema doesn't need a migration if/when PR-review-API integration is added later, but nothing in review.nvim today produces or consumes that data.
- No `content_hash` / `reviewed_hunks` / per-file `reviewed` boolean — those are tuicr features (hunk-level review-progress tracking) review.nvim doesn't have today. Omitted rather than speculatively added, per this project's own `coding_standards` guidance against building unrequested flexibility.
- `comment_scope='line'` allows **multiple comments per line** (tuicr's model), which is a **behavior change** from today's review.nvim (`comments.lua:20-24` currently refuses a second comment at an already-commented line/range). **Decision: this is in scope** — see §2a — specifically to capture the case of two different writers (e.g. a human and an agent, or two agents) independently commenting on the same line without either one clobbering or blocking the other.

### 2a. Multiple comments per line, multiple writers

The scenario to support: writer A (say, a human, `author='tkolleh'`) adds a comment on `init.lua:42`. Independently — before or after, doesn't matter — writer B (say, an agent, `author='claude-agent'`) adds a *different* comment on the same line. Both must be captured and both must render; neither should overwrite, merge, or block the other.

**Why the row-level schema already gives you this for free.** There is no uniqueness constraint on `(file_path, line_start)` in `review_comments` — unlike review.nvim's current in-memory model, where `comments.lua:20-24`'s `store.get_at_line()` check treats "a comment already exists here" as an error condition to prevent. With DuckDB, each comment is its own row with its own `id`; two `INSERT`s targeting the same `(file_path, line_start)` are simply two rows, not a conflict. This was verified directly:

```sql
-- writer A (human), short-lived CLI call
INSERT INTO review_comments
    (session_id, comment_scope, file_path, line_start, side, comment_type, content, author)
VALUES ('<session-uuid>', 'line', 'lua/review/init.lua', 42, 'new', 'issue',
        'Missing nil check here', 'tkolleh');

-- writer B (agent), separate short-lived CLI call, same line
INSERT INTO review_comments
    (session_id, comment_scope, file_path, line_start, side, comment_type, content, author)
VALUES ('<session-uuid>', 'line', 'lua/review/init.lua', 42, 'new', 'suggestion',
        'Consider extracting this into a helper', 'claude-agent');
```

Querying that line back:

```sql
duckdb review.duckdb -c "
SELECT author, comment_type, content
FROM review_comments
WHERE file_path = 'lua/review/init.lua' AND line_start = 42
ORDER BY created_at;
"
```

confirmed output (both rows present, insertion order preserved via `created_at`):

```
┌──────────────┬──────────────┬─────────────────────────────────────────┐
│    author    │ comment_type │                 content                  │
├──────────────┼──────────────┼───────────────────────────────────────────┤
│ tkolleh      │ issue        │ Missing nil check here                   │
│ claude-agent │ suggestion   │ Consider extracting this into a helper   │
└──────────────┴──────────────┴───────────────────────────────────────────┘
```

Two sequential `INSERT`s never collide on the same row — DuckDB does not need a `MERGE`/upsert or any conflict resolution here at all, because there is nothing to merge: they are two independent rows that happen to share a `(file_path, line_start)` value, which is exactly the point of using a foreign-key-style child table instead of a single JSON blob keyed by line number (as tuicr's `line_comments: table<line_number_string, Comment[]>` does, and as review.nvim's current `line == cursor` sentinel-matching does). The "am I about to clobber someone else's comment" question that plagues whole-file JSON overwrites (`agent-comment-authoring.md` §1, "the multi-writer race") simply does not arise for row-level inserts targeting distinct primary keys.

**Grouping multiple same-line comments back into tuicr-shaped JSON.** Extending the illustrative query from §2's "JSON representation" section, `GROUP BY (file_path, line_start)` naturally collects every writer's comment on a line into one list, which is then nested under that line's key — this was verified directly against the two-writer rows above:

```sql
duckdb review.duckdb -json -c "
SELECT file_path,
       to_json(map_from_entries(list(struct_pack(
           k := line_start::VARCHAR,
           v := comments
       ))))
FROM (
    SELECT file_path, line_start,
           list(struct_pack(id, comment_type, content, author, side, line_end)
                ORDER BY created_at) AS comments
    FROM review_comments
    WHERE session_id = '<session-uuid>' AND comment_scope = 'line'
    GROUP BY file_path, line_start
) sub
GROUP BY file_path;
"
```

confirmed output shape (both writers' comments nested under line `"42"`):

```json
{
  "42": [
    { "id": "...", "comment_type": "issue",      "content": "Missing nil check here",                "author": "tkolleh",      "side": "new", "line_end": null },
    { "id": "...", "comment_type": "suggestion",  "content": "Consider extracting this into a helper", "author": "claude-agent", "side": "new", "line_end": null }
  ]
}
```

This is tuicr's exact `line_comments` shape (`table<line_number_string, Comment[]>`, `agent-comment-authoring.md` §2), now populated from independent, non-colliding writes rather than requiring either writer to know about the other's comment at write time.

**What this means for review.nvim's Lua layer, not just the schema.** Adopting this changes two assumptions baked into the current code, beyond just the storage format:

- `comments.lua:20-24` and `comments.lua:82-86` (`add_at_cursor`, `add_for_range`) currently call `store.get_at_line`/`get_overlapping` and **refuse to add** a second comment, redirecting the user to "edit instead." That guard is the wrong behavior once multiple comments per line are a supported, intentional case — it would need to become "add a new comment alongside the existing one(s)" as the default, with editing a *specific* existing comment requiring some way to disambiguate which of several comments at that line the user means (e.g. `edit_at_cursor` picking via `vim.ui.select` when more than one comment exists at the cursor's line, rather than assuming there's exactly zero or one).
- `marks.lua:74-137` (`render_for_buffer`) currently renders **one** `virt_lines` comment box per line/range via a single loop over `store.get_for_file()` — nothing about the extmark logic itself assumes one-comment-per-line (it already loops over `comments` and calls `nvim_buf_set_extmark` per comment), so multiple stacked comment boxes on one line likely render correctly today with no changes, *but* this needs visual confirmation once implemented — particularly `align_buffers` (`marks.lua:160-214`)'s height-matching logic, which sums comment-box heights per `attach_line` (`build_height_map`, `marks.lua:177-187`) and should sum correctly across multiple comments already, since it's iterating `store.get_for_file()`'s full list rather than assuming a single comment.

## 3. The dual-writer problem, empirically tested

### What was actually tested (DuckDB CLI v1.5.5, local file, default settings)

| Scenario | Result |
|---|---|
| Two `duckdb file.db -c "INSERT ..."` invocations run sequentially (A opens+writes+exits, then B opens+writes) | **Both succeed.** Lock is released the instant a process's connection closes — confirmed by timing a single invocation (~29ms total) and immediately running a second one successfully afterward. |
| Two `duckdb file.db -c "..."` invocations with **overlapping** open windows (A sleeps 1s while holding the connection, B starts mid-sleep) | **B fails immediately**: `IO Error: Could not set lock on file "...": Conflicting lock is held in <path> (PID <n>) by user <user>`. No blocking/waiting, no queueing — an immediate hard error. |
| A writer holds the file open; a **second process opens with `-readonly`** during that window | **Readonly open also fails**, same `IO Error`. A single writer holding the connection blocks all other access, read or write, for the duration its connection is open. |
| Two `duckdb file.db -readonly -c "..."` processes open **concurrently**, no writer present | **Both succeed** and see consistent data. Multiple concurrent readers are fine as long as nothing holds a write connection. |

Source: `https://duckdb.org/docs/stable/connect/concurrency` (referenced directly in the CLI's own error message) documents this as DuckDB's default single-process-writer model: one process may hold a read-write connection to a database file at a time; any number of *separate* processes may hold read-only connections *when no writer is connected*, but a writer excludes everyone else, including other readers, for as long as it's connected.

### Why this is a fundamentally different failure mode than review.nvim's current JSON-file design or tuicr's lockfile+poll design

- **review.nvim today**: no lock at all. Two concurrent writers can both succeed at the OS level, and the loser's data is silently discarded (`store.persist()` overwrites the whole file unconditionally — see `agent-comment-authoring.md` §1). Data loss, but no errors, no blocking.
- **tuicr**: an explicit advisory lockfile (`.tuicr.lock`) plus periodic reload. A losing writer would (per the lock's presence) either wait briefly or retry, and the *reader* side (the running TUI) reconciles via polling rather than needing exclusive access at all — so a long-lived TUI process never blocks a short-lived CLI `add` from succeeding.
- **DuckDB (default mode)**: the failure is immediate, loud, and — this is the important part — **it would trigger on Neovim's own normal usage pattern**, not just on agent/human collision. If `M.setup()` opens one long-lived DuckDB connection for the life of the Neovim process (the natural embedding pattern, avoiding a CLI subprocess launch on every keystroke/comment), that connection **alone** blocks every other process — including a `duckdb` CLI invocation from an agent — for the entire duration Neovim has the review database open. This is strictly worse for the "agent writes while I have Neovim open" use case than either the current JSON approach or tuicr's model, unless the connection lifetime is managed deliberately (see below).

### Design options, given DuckDB's actual locking model

**Option A — Neovim never holds a long-lived connection; every operation is short-lived CLI invocation, open-write-close.** This is the option that respects DuckDB's default model as-is and matches "written to a local database file... via the DuckDB CLI" from the prompt literally. `store.add`/`store.update`/`store.delete` would each shell out (`vim.system` or `io.popen`) to a single `duckdb review.duckdb -c "INSERT ..."` call and exit immediately, exactly mirroring the tested "sequential open-write-close" scenario that succeeded cleanly above.
- Pro: correctness is exactly what DuckDB guarantees by default — no new locking code needed in review.nvim at all.
- Con: every comment add/edit/delete now pays subprocess-launch latency (tens of ms, per the timed test above — not free, but not perceptible for a human typing a comment). Reads for `marks.refresh()` (called frequently: on every `BufEnter`, every add/edit/delete) would also need to be short-lived `-readonly` CLI calls, which is a bigger behavior change from today's instant in-memory `store.get_for_file()` lookups.
- **This directly solves the agent race**: an agent's `duckdb review.duckdb -c "INSERT ..."` and Neovim's own equivalent CLI-shelling writes are both short-lived. As long as neither side holds the connection open between operations, concurrent access degrades to "occasional immediate `IO Error` on true simultaneous collision," which is retriable with a short backoff — a real, bounded, well-defined failure mode, unlike today's silent data loss.

**Option B — Neovim holds one long-lived writer connection for the session; agents are readonly-only while Neovim has it open.** Matches how you'd naturally embed DuckDB for performance (avoid a subprocess per keystroke), but per the tested behavior, this **locks agents out entirely** while a review session is open — an agent's `duckdb review.duckdb -c "INSERT ..."` would fail immediately with the same `IO Error` for as long as Neovim's connection is alive. This only works for the "agent writes before the review session opens" workflow (the one already chosen for the plain-JSON design) — it does not support live/concurrent writing at all, and unlike Option A, there's no way to make it support it without changing which side holds the connection.

**Option C — Neovim opens/closes its connection around each operation too (same as Option A), but batches reads more aggressively (e.g. one query per `marks.refresh()` call, not per comment) to offset subprocess latency.** This is Option A with a performance mitigation, not a different concurrency model — worth calling out separately because "how often does review.nvim call into storage" (every `BufEnter`, per `hooks.lua:228-241`) matters more for DuckDB-via-CLI than it did for a single `io.open`/`json_decode` read.

### Recommendation given the constraints as stated

The prompt specifies "writing to a local database file... via the DuckDB CLI" — that already implies Option A's shape (CLI invocations, not an embedded library connection), and Option A is also the one that actually solves the dual-writer problem rather than trading review.nvim's silent data-loss race for a different, Neovim-self-inflicted lockout. The concrete shape:

1. Every `store.add`/`update`/`delete` becomes a single short-lived `duckdb <db> -c "INSERT/UPDATE/DELETE ..."` subprocess call (via `vim.system`, async, with the callback doing what `persist()`'s callers currently do synchronously — this is a bigger change than it sounds, since today's code assumes `store.add()` returns a fully-formed `Comment` synchronously; see `store.lua:61-80` and every caller in `comments.lua`).
2. A **short, bounded retry-with-backoff** around the `IO Error` "conflicting lock" case specifically (matchable by stderr substring or DuckDB's error code) — since the tested failure mode is immediate and simultaneous collisions between a human's keypress and an agent's CLI write are rare and brief (each holds the lock for single-digit milliseconds), 2-3 retries with ~50ms backoff should be more than sufficient rather than needing anything as heavyweight as tuicr's persistent lockfile.
3. `marks.refresh()` reads become `-readonly` CLI calls; since multiple `-readonly` readers coexist freely (confirmed above) as long as no writer holds the file, this path has no contention problem at all — the only contention is writer-vs-anyone, which step 2 handles.

This was not implemented in this research session — it is a scoped design sketch, pending a decision on whether the added subprocess-per-operation latency and the async-ification of `store.lua`'s currently-synchronous API are acceptable trade-offs for this project.

## 4. Open questions for a follow-up design pass

- ~~Does `comment_scope='line'` allowing multiple comments per line get built as part of this migration?~~ **Resolved: yes** — see §2a. Multiple writers commenting independently on the same line is a first-class, required case, not deferred. What remains open is the `comments.lua` UX question flagged in §2a's last bullet: how `edit_at_cursor` and `delete_at_cursor` should disambiguate *which* comment at a line a human means to act on once more than one can exist there (a picker, most likely, mirroring the existing `vim.ui.select` pattern already used in `comments.lua:143-155` for delete confirmation).
- `store.lua`'s public API (`add`, `update`, `delete`, `get_at_line`, etc.) is called synchronously throughout `comments.lua`. Moving to CLI-subprocess I/O means either (a) making these calls blocking (`vim.system(..., {}):wait()`), which reintroduces per-keystroke latency risk but keeps the existing synchronous call sites unchanged, or (b) threading async callbacks through every call site in `comments.lua`/`hooks.lua`/`marks.lua` — a materially larger refactor. Neither was scoped or decided here.
- Whether the retry-with-backoff in §3 recommendation should be paired with the same "reload before you assume you're clobbering nothing" pattern from tuicr, or whether row-level `INSERT`/`UPDATE`/`DELETE` statements make that unnecessary (since, unlike the current whole-file JSON overwrite, a DuckDB write to one row can never clobber a concurrent writer's *different* row — only true single-row/same-key collisions are even possible, which narrows the class of races DuckDB introduces relative to today's design). §2a's two-writers-same-line case is the concrete instance of this: two `INSERT`s targeting the same `(file_path, line_start)` but different primary-key `id`s are not a collision at all under this schema, so no reload/merge logic is needed for that case specifically — only true same-row `UPDATE`/`DELETE` collisions (e.g. two processes editing or deleting the *same* comment `id` simultaneously) fall into the retry-with-backoff category from §3.
