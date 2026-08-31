# Research: libduckdb (LuaJIT FFI) vs. `duckdb` CLI for review.nvim's own reads/writes

Follow-up to [`duckdb-storage-backend.md`](./duckdb-storage-backend.md) and
[`agent-comment-authoring.md`](./agent-comment-authoring.md), and downstream of
`specs/review-storage.allium`. Scope: **review.nvim's own reads/writes only** —
external agents are already decided to use the `duckdb` CLI regardless, per the
spec's mechanism-agnostic framing and the settled facts restated in the prompt
that produced this doc. This is a tradeoffs comparison, not a recommendation —
the final call is left to whoever implements the migration.

Everything below is either a directly-verified primary-source fact (with the
verification method stated) or explicitly labeled as inference/speculation.
Nothing here should be read as re-litigating the locking-model or schema
decisions already settled in the two prior research docs.

## 1. Performance

**What was actually measured, by whom:**

- `duckdb-storage-backend.md` §3 measured `duckdb` CLI subprocess latency
  empirically: ~29ms per invocation (open, `INSERT`, close), tested against
  DuckDB v1.5.5 CLI on the original research machine.
- As a rough, informal cross-check (not a rigorous benchmark — different
  machine, different load, small sample), I timed 10 sequential `duckdb
  <file> -c "INSERT ..."` invocations locally just now: ~41ms/invocation
  average (wall-clock, includes shell-loop overhead), against a bare `/bin/true`
  spawn baseline of ~27ms/invocation on the same machine under the same shell
  loop. The delta between "spawn a process at all" and "spawn `duckdb`
  specifically and have it open+write+close a database" was on the order of
  10-15ms on this machine — consistent in order of magnitude with the original
  ~29ms figure, but I want to flag explicitly that neither number should be
  treated as authoritative; both are single-machine, unisolated, small-sample
  timings, not a proper benchmark suite.
- **LuaJIT FFI call overhead**: I could not find any benchmark, discussion, or
  documented number — from LuaJIT's own site, DuckDB's GitHub issues/discussions,
  or elsewhere — that measures the cost of `ffi.cdef`/`ffi.load`, or the cost of
  a `duckdb_open`/`duckdb_connect`/`duckdb_close` round-trip via the C API, in
  isolation. LuaJIT's official FFI docs (`https://luajit.org/ext_ffi.html`,
  verified by fetching and grepping the raw page text) discuss FFI call
  performance only in the context of "calls to C functions can be inlined in
  JIT-compiled code, unlike calls to functions bound via the classic Lua/C API"
  and a data-structure micro-benchmark (FFI structs vs. Lua tables) — neither
  is a number for connection-open cost specifically.
- Searching `duckdb/duckdb`'s GitHub issues for connection-open/startup latency
  discussions (`gh search issues "connect open slow"`, `"duckdb_open"
  "startup time"`, both scoped to `repo:duckdb/duckdb`) returned zero results.
  I did not find anyone, anywhere, who has measured `duckdb_open`/`duckdb_connect`
  latency via the C API.

**Conclusion for this section, stated plainly:** the CLI subprocess path has an
approximate, informally-corroborated latency figure (tens of milliseconds per
operation, dominated by fork+exec and process startup more than DuckDB's own
init, based on the `/bin/true` baseline comparison). The FFI path's equivalent
number — cost of `ffi.load` (paid once) plus `duckdb_open`/`duckdb_connect`
(paid per operation, if following the "open only for the duration of one
mutation" spec guarantee) — is **not measured anywhere I could find**. A
reasonable inference (labeled explicitly as such, not a documented fact) is
that an in-process C API call avoiding fork+exec should be faster per-operation
than a subprocess launch, since it skips OS process creation entirely — but
"how much faster" is unknown, and DuckDB's own connection/database
initialization work (parsing/validating the file, catalog load, etc.) still
happens on every `duckdb_open` regardless of API, so the gap may be smaller
than "no fork+exec" alone would suggest. This should be measured directly
before being used to justify a choice, not assumed.

## 2. Implementation complexity for a Lua/Neovim plugin

**Size and stability of the C API surface**, verified directly from the local
Homebrew-installed header (`/opt/homebrew/Cellar/duckdb/1.5.5/include/duckdb.h`,
DuckDB v1.5.5, 6294 lines):

- `grep -c "^DUCKDB_C_API" duckdb.h` → **546 function declarations** in the
  full C API.
- The header documents a versioned stability model: `DUCKDB_API_VERSION_MAJOR
  1` / `_MINOR 5`, with `DUCKDB_API_ALLOW_DEPRECATED` and
  `DUCKDB_API_ALLOW_UNSTABLE` compile-time switches, and per-function
  stable/unstable/deprecated annotations in the doc comments. This means the
  full surface is not something you'd hand-declare in bulk casually — it's
  large, versioned, and has functions in three different stability tiers.
- **You do not need anywhere close to all 546 functions.** A real, working
  precedent — `hello-world-bfree/nvim-duckdb` (a LuaJIT-FFI-based Neovim
  plugin for ad hoc SQL-on-buffers, MIT-adjacent public repo, 3 stars, created
  Nov 2025, still receiving commits as of Jul 2026) — hand-writes its
  `ffi.cdef` block covering roughly **65 function declarations** (open/close,
  connect/disconnect, query, result/data-chunk/vector accessors, prepared
  statements, appender, a handful of type/logical-type introspection
  functions) plus the enum/struct type definitions those functions need. This
  was verified by downloading and reading
  `lua/duckdb/ffi.lua` from that repo directly (`gh api
  repos/hello-world-bfree/nvim-duckdb/contents/lua/duckdb/ffi.lua`) — it is
  **hand-written**, not generated from `duckdb.h`, with an explicit comment
  citing `https://github.com/duckdb/duckdb/blob/main/src/include/duckdb.h` as
  the source it was transcribed from, and a version-pinned comment ("Modern
  API - v1.5.4"). review.nvim's needs (`INSERT`/`UPDATE`/`DELETE`/`SELECT` on a
  small number of typed columns, no nested LIST/STRUCT/MAP types per the
  schema in `duckdb-storage-backend.md` §2) would need a comparable or smaller
  subset — likely under 20 functions (open/close, connect/disconnect,
  query-or-prepare+bind+execute, result-error retrieval, a few column-value
  accessors) since the schema has no complex nested types to unpack via the
  Data Chunk/Vector API.
- **Existing bindings that could be adapted or vendored, checked directly:**
  - `hello-world-bfree/nvim-duckdb`'s `lua/duckdb/ffi.lua` is real, working,
    MIT-style-licensed-looking (no explicit LICENSE file found in the repo
    tree, worth checking before vendoring verbatim), hand-maintained LuaJIT
    FFI cdef code that could plausibly be adapted (trimmed to review.nvim's
    subset) rather than written from scratch. It also ships a companion
    `tests/plenary/ffi_cleanup_spec.lua` (downloaded and read directly) that
    is instructive: it explicitly tests connection double-close safety,
    "library not loaded" error paths, and repeated create/close cycling under
    `collectgarbage('collect')` — i.e., real FFI resource-lifecycle
    discipline that review.nvim would also need to replicate if it went this
    route, not just the `ffi.cdef` string itself.
  - `rousbound/luasql-duckdb` (found via `gh search repos "luasql duckdb"`,
    confirmed via `gh api repos/rousbound/luasql-duckdb`) is a **different
    binding style** — a compiled C Lua extension in the classic `luasql`
    driver pattern (`language: C`, not Lua/FFI), last pushed August 2024, 0
    stars. This is not directly adaptable to a pure-Lua-source Neovim plugin
    like review.nvim without introducing a compiled-artifact build step,
    which the project's own `CLAUDE.md` explicitly says review.nvim does not
    have today ("plain Lua loaded directly by Neovim's runtime path"). It's
    also packaged in Ubuntu (`lua-sql-duckdb`/`lua-sql-duckdb-dev`, confirmed
    via Ubuntu's package search), which is notable only as evidence the
    C-extension approach exists and is distributed somewhere, not as a
    realistic dependency for this plugin.
  - No LuaJIT-FFI-specific binding beyond `nvim-duckdb`'s own module was found
    via GitHub repo search (`luajit duckdb ffi` → 0 results).

**CLI + `vim.system` complexity, for comparison:**

- `vim.system(cmd, opts, on_exit)` is a stable, documented Neovim 0.10+ API
  (verified from the local Neovim 0.12.5 runtime help,
  `share/nvim/runtime/doc/lua.txt`). Shelling out to `duckdb <file> -c "..."`
  and parsing `-json`/`-csv` output requires no `ffi.cdef`, no type
  marshaling, no manual connection-object lifecycle, and no per-symbol
  stability tracking against DuckDB's own API surface — the "API" being
  depended on is CLI flags and output format, which is a much smaller,
  more stable surface than 546 (or even 20-65) individual C functions with
  per-function stability tiers.
- The tradeoff is real, not free: CLI output still needs parsing (JSON via
  `vim.json.decode`, which is standard/trivial; CSV would need manual
  escaping-aware parsing, so `-json` is the only output mode worth using),
  and the async-vs-sync question flagged in `duckdb-storage-backend.md` §3/§4
  applies identically regardless of which of these two options is chosen —
  it's a consequence of "connection open only for one mutation," not of
  CLI-vs-FFI specifically.

**Net comparison for this section:** FFI implementation complexity is
concretely bounded (not "546 functions," but a real precedent shows ~65 is
enough for a fuller feature set than review.nvim needs, and review.nvim's own
subset is smaller still) and there is a real, inspectable, hand-written
reference implementation to adapt from rather than starting from the raw
header. But it is still meaningfully more code and more failure surface
(manual `ffi.cdef`, manual struct layout for `duckdb_string_t`'s inline/pointer
union, manual connection/result lifecycle with double-free/leak risk) than
shelling out and parsing JSON, which needs none of that.

## 3. Distribution/install burden on the end user

**Directly verified on this machine (macOS, Homebrew):**

```
$ brew info duckdb
duckdb: stable 1.5.5 (bottled)
...
$ ls /opt/homebrew/Cellar/duckdb/1.5.5/bin/
duckdb  duckdb_cli
$ ls /opt/homebrew/Cellar/duckdb/1.5.5/lib/ | grep libduckdb
libduckdb.dylib
libduckdb_static.a
$ ls /opt/homebrew/Cellar/duckdb/1.5.5/include/
duckdb  duckdb_extension.h  duckdb.h  duckdb.hpp
```

**A single `brew install duckdb` on macOS installs the CLI binary, the shared
library, and the C headers all at once.** This confirms the framing in the
task prompt: on macOS via Homebrew, distribution burden between "install the
CLI" and "install libduckdb for FFI" is **not a differentiator** — one command
satisfies both.

**Linux, checked via Ubuntu's package search:** Ubuntu's repository ships
`duckdb` (CLI), `libduckdb-dev` (headers + `.so` symlink for linking), and
`libduckdb1.5` (the runtime shared library) as **separate packages** from the
same source package. This means on Debian/Ubuntu, unlike Homebrew, there
*could* be a real split: a user who only ran `apt install duckdb` would have
the CLI but not necessarily the dev/runtime shared-library packages
installed as a side effect (`apt install duckdb` pulling in `libduckdb1.5` as
a runtime dependency of the CLI itself is likely, since the CLI binary must
link against something, but I did not verify whether `libduckdb-dev` — which
provides the headers `ffi.cdef` would be hand-transcribed from, not runtime-
required by FFI — is pulled in automatically; FFI only needs the `.so`/`.dylib`
runtime library to be *loadable*, not the `-dev` headers, since `ffi.cdef` is
Lua-side source, not a compile-time include). This is a real platform
asymmetry versus the macOS case and should be verified with `apt-cache
depends duckdb` in a real Debian/Ubuntu environment before being treated as
settled — I do not have a Linux machine available to check this directly
in this session, so I'm flagging it as unverified rather than asserting it.

**Precedent for user-facing install instructions**, directly read from
`hello-world-bfree/nvim-duckdb`'s `lua/duckdb/health.lua` (`:checkhealth`
implementation, downloaded and read in full):

```
'Please install DuckDB 1.5.0 or later:',
'  - Ubuntu/Debian: sudo apt install libduckdb-dev',
'  - macOS: brew install duckdb',
'  - Arch Linux: sudo pacman -S duckdb',
'  - Or download from: https://duckdb.org/docs/installation/',
```

This is an existing, real Neovim plugin's own user-facing guidance for the
FFI path, and it already treats macOS as "one command, done" and Debian/Ubuntu
as needing the explicit `-dev` package by name — independent corroboration of
the Linux/macOS asymmetry flagged above, from a source that had to solve this
exact problem already.

**CLI-only distribution burden**, for comparison: the settled facts already
state the `duckdb` CLI ships as per-platform SHA256-checksummed archives
(linux-amd64/arm64 glibc+musl, osx-amd64/arm64/universal, windows-amd64/arm64)
with no mason.nvim registry package. So the CLI-only path's realistic install
instruction is the same `brew install duckdb` / `apt install duckdb` / manual
archive download — i.e., install burden for "get the CLI" is identical
regardless of whether FFI is also used, since `brew`/`apt install duckdb`
already gets you the library too (macOS) or nearly does (Linux, modulo the
`-dev` package question above). **The FFI path's install burden is not "CLI
install plus something extra" on macOS — it's the same command.** On Linux it
may require the user to know to ask for `libduckdb-dev` specifically rather
than just `duckdb`, which is a real, if small, incremental burden unique to
the FFI path.

## 4. Error handling and observability

**CLI subprocess path:**

- `vim.system(...):wait()` (or the async callback form) returns a
  `vim.SystemCompleted` table with `code`, `signal`, `stdout`, `stderr` fields
  — verified from the local Neovim 0.12.5 `lua.txt` help docs. A failed
  `duckdb -c "INSERT ..."` (e.g., the "conflicting lock" `IO Error` documented
  in `duckdb-storage-backend.md` §3) surfaces as a non-zero `code` plus a
  human-readable error string in `stderr` (e.g. `IO Error: Could not set lock
  on file "...": Conflicting lock is held...`), which the original research
  doc already confirmed can be pattern-matched by substring to distinguish
  "expected, retryable lock contention" from other failures.
- This is coarse-grained: you get a process exit code and an unstructured
  text blob. Distinguishing error *categories* (constraint violation vs. I/O
  error vs. syntax error) means parsing DuckDB's own human-readable error
  message text, which is not a stable machine-readable contract — DuckDB
  could reword an error message between versions without that being
  considered a breaking API change, since the CLI's textual error output
  isn't the same kind of versioned surface as the C API's `duckdb_error_type`
  enum (see below). This is a reasonable inference from how CLI tools
  generally version their human-readable output, not something I found
  explicitly documented as a DuckDB CLI stability guarantee (or
  non-guarantee).

**FFI/C API path:**

- Every mutating C API call returns a `duckdb_state` (`DuckDBSuccess = 0` /
  `DuckDBError = 1`, confirmed directly in the local header and mirrored
  identically in `nvim-duckdb`'s hand-written cdef). On error, `duckdb_result`
  carries a retrievable error string via `duckdb_result_error()`, and
  additionally a **structured, versioned enum** `duckdb_error_type`
  (confirmed in both the local `duckdb.h` and `nvim-duckdb`'s transcription:
  43 distinct categories as of v1.5.4/1.5.5 — `DUCKDB_ERROR_CONSTRAINT`,
  `DUCKDB_ERROR_IO`, `DUCKDB_ERROR_SYNTAX`, `DUCKDB_ERROR_CONNECTION`, etc.)
  retrievable via `duckdb_result_error_type()`. This is a materially better
  observability primitive than CLI stderr text: catching "this was a lock/IO
  contention error, retry it" vs. "this was a constraint violation, don't
  retry it" becomes an integer comparison against a stable enum instead of a
  substring match against a human-readable sentence.
- The cost of that better signal is more moving parts to get right from Lua:
  the caller must remember to check `duckdb_state` on every call, call the
  right accessor function (`duckdb_result_error`, `duckdb_prepare_error`,
  `duckdb_pending_error`, `duckdb_appender_error` — these are *not* unified
  into one function; the accessor differs by which handle type produced the
  error, confirmed from the local header's function list), and manage the
  lifetime of the returned error string/result object correctly (DuckDB's own
  doc comment on `duckdb_open_ext`, read directly from the header: "Note that
  the error message must be freed using `duckdb_free`" for the *out_error*
  path specifically — a manual-memory-management footgun that has no analog
  in reading a subprocess's `stderr` string, which Lua/Neovim's GC already
  owns).

**Net comparison:** FFI gives strictly more structured error information
(a stable, versioned category enum vs. free-text pattern matching), but
extracting it correctly requires more disciplined, per-call-site code (check
`duckdb_state`, call the matching `_error` accessor for that handle type,
manage `duckdb_free` where required) than reading `obj.stderr` after
`vim.system():wait()`. Whether that's "easier to get right" depends on how
much the retry/error-classification logic in `specs/review-storage.allium`
(the bounded-retry-on-contention vs. reject-on-stale-modification distinction)
actually needs the finer-grained enum — if a stderr substring match is
sufficient to distinguish "lock contention, retry" from "everything else,
surface to caller" (which is all the spec currently requires), the CLI path's
coarser signal may already be adequate, and the FFI path's extra structure
would be unused precision. This is my own inference connecting the spec's
actual needs to the two error-handling shapes, not a documented tradeoff
anyone else has written down.

## 5. Failure isolation

This is the one dimension where the evidence is least ambiguous.

**FFI path — verified directly from LuaJIT's own official documentation**
(`https://luajit.org/ext_ffi.html`, "No Hand-holding!" section, fetched and
grepped from the raw page text to confirm exact wording, not paraphrased):

> "The FFI library provides no memory safety, unlike regular Lua code. It
> will happily allow you to dereference a NULL pointer, to access arrays out
> of bounds or to misdeclare C functions. If you make a mistake, your
> application might crash, just like equivalent C code would."

and, later on the same page:

> "the FFI library is not safe for use by untrusted [Lua code]"

There is no sandboxing, no process boundary, and no isolation between an FFI
call and the LuaJIT process it runs inside — `libduckdb`, loaded via
`ffi.load`, executes **in the same process as Neovim itself**. A segfault, an
infinite loop inside DuckDB's C++ engine, a misdeclared function signature in
review.nvim's own `ffi.cdef` (wrong argument types/count silently doing the
wrong thing rather than erroring, since — per the same LuaJIT doc — "there's
no way to detect misdeclarations of C functions, since shared libraries only
provide symbol names, but no type information"), or a genuine DuckDB bug that
corrupts memory takes down the entire Neovim process, along with whatever
unsaved buffers/state the user had open. This is a real architectural
exposure, not a style concern: it means a DuckDB-internal fault (crash, or a
hang inside a query with no way to interrupt it short of `duckdb_interrupt`
being called from a *different* thread than the one blocked in the C call —
Neovim's Lua is single-threaded, so nothing else can run to issue that
interrupt while the blocking `duckdb_query` call hasn't returned) can crash or
freeze the editor itself.

**CLI subprocess path — verified from Neovim's own runtime docs**
(`share/nvim/runtime/doc/lua.txt`, `vim.system()`/`SystemObj:kill()`,
local Neovim 0.12.5):

- `vim.system(cmd, { timeout = N }, on_exit)` supports a `timeout` option:
  "Run the command with a time limit in ms. Upon timeout the process is sent
  the TERM signal (15) and the exit code is set to 124." This is a built-in,
  documented, Neovim-managed mechanism for bounding how long a `duckdb` CLI
  invocation can hang before Neovim reclaims control — with no equivalent
  available for a blocking in-process FFI call.
- `SystemObj:kill(signal)` additionally lets calling code send an arbitrary
  signal to the child process on demand (not just on timeout), independent of
  Neovim's own event loop or main thread.
- If a `duckdb` CLI subprocess itself segfaults or corrupts its own memory,
  that fault is contained within the child process (it dies, `vim.system`'s
  `on_exit`/`:wait()` reports a nonzero `signal`/`code`) and **Neovim keeps
  running** — this is the ordinary OS process-isolation guarantee, not
  something specific to DuckDB, but it's the direct architectural
  consequence of "subprocess" vs. "in-process library" that matters here.

**Net comparison, stated as plainly as the evidence supports:** yes, a
libduckdb FFI fault (crash or hang) is capable of taking the Neovim process
down or freezing it with it, per LuaJIT's own documented "no memory safety,"
"application might crash" language, and per the single-threaded-Lua
consequence that a blocking FFI call has no side channel to interrupt it. A
`duckdb` CLI subprocess fault is isolated to the child process by ordinary OS
process boundaries, and Neovim has a documented, built-in mechanism
(`vim.system`'s `timeout` option and `SystemObj:kill()`) to bound and recover
from a hung or runaway child without needing anything DuckDB-specific. This is
a genuine, evidence-backed architectural safety asymmetry between the two
options, not a style preference — whether it matters enough to outweigh the
performance/complexity tradeoffs above is a judgment call for whoever decides,
not something this research resolves.

## Summary table

| Dimension | libduckdb via LuaJIT FFI | `duckdb` CLI via `vim.system` |
|---|---|---|
| Measured performance | No connection-open benchmark found anywhere (LuaJIT docs, DuckDB GitHub, general search) | ~29-41ms/invocation, measured twice on two different machines (informal, not rigorous) |
| API surface size | 546 total C API functions (measured); ~65 needed per real precedent (`nvim-duckdb`); review.nvim's subset likely <20 | CLI flags + JSON output parsing; no per-function surface to track |
| Existing bindings to adapt | `nvim-duckdb`'s hand-written `ffi.cdef` (real, working, inspectable) | N/A — `vim.system` + `vim.json.decode` is stdlib |
| macOS install burden | Same `brew install duckdb` as CLI-only (verified: one formula, both artifacts) | `brew install duckdb` |
| Linux install burden | Possibly needs explicit `libduckdb-dev`/`libduckdb1.5` beyond `apt install duckdb` (unverified on a real machine; flagged by `nvim-duckdb`'s own health-check instructions) | `apt install duckdb` |
| Error granularity | Structured `duckdb_state` + versioned `duckdb_error_type` enum (43 categories) | Exit code + free-text stderr, pattern-matchable but not versioned |
| Error-handling code burden | Per-call-site state checks, handle-type-specific `_error` accessors, manual `duckdb_free` in one documented path | Single `obj.stderr`/`obj.code` check after `:wait()` |
| Failure isolation | No process boundary — LuaJIT's own docs: FFI faults "might crash" the host process; blocking calls can't be interrupted from single-threaded Lua | OS process boundary; `vim.system` has a built-in `timeout` + `SystemObj:kill()` to bound/recover from hangs |

## Sources consulted directly (not recalled from training data)

- `https://duckdb.org/docs/stable/connect/concurrency` — cited as already
  verified in `duckdb-storage-backend.md`; the live page is a JS-rendered SPA
  that WebFetch/curl cannot statically read, so this doc relies on the prior
  doc's already-empirical verification rather than re-fetching it.
- Local Homebrew-installed DuckDB v1.5.5: `duckdb.h` (6294 lines,
  `/opt/homebrew/Cellar/duckdb/1.5.5/include/duckdb.h`), `duckdb --version`,
  `duckdb -c "SELECT name, description FROM duckdb_settings() WHERE name ILIKE
  '%access_mode%'"`, `brew info duckdb`, `ls` of the Cellar `bin/`/`lib/`/
  `include/` directories.
- `https://luajit.org/ext_ffi_semantics.html` and
  `https://luajit.org/ext_ffi.html` — fetched raw and grepped for exact
  wording (the "No Hand-holding!" safety quote was verified verbatim against
  the raw HTML after an initial WebFetch summary needed confirmation).
- `hello-world-bfree/nvim-duckdb` (GitHub, default branch `master`) —
  `lua/duckdb/ffi.lua`, `lua/duckdb/health.lua`, and
  `tests/plenary/ffi_cleanup_spec.lua` downloaded and read in full via `gh
  api .../contents/...`.
- `rousbound/luasql-duckdb` (GitHub) — metadata only (`gh api
  repos/rousbound/luasql-duckdb`), to confirm it is a C-extension binding
  distinct from the FFI approach.
- Local Neovim 0.12.5 runtime docs
  (`/opt/homebrew/Cellar/neovim/0.12.5/share/nvim/runtime/doc/lua.txt`) for
  `vim.system()` and `SystemObj:kill()`.
- Ubuntu package search (via WebFetch) for `duckdb`/`libduckdb-dev`/
  `libduckdb1.5`/`lua-sql-duckdb` package names — noted as unverified against
  a live Debian/Ubuntu machine (no such machine available this session), so
  treated as directional evidence rather than a settled fact where the
  WebFetch summary could not be independently re-confirmed the way the
  LuaJIT quote was.
- `gh search issues`/`gh search repos` against `duckdb/duckdb` and general
  GitHub, to confirm the *absence* of connection-open benchmarks and of any
  other LuaJIT-FFI-DuckDB binding project.
