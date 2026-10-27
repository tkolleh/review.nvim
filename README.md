# review.nvim 🧐

Code review annotations optimized for AI feedback loops.

> **Hard fork** of [georgeguimaraes/review.nvim](https://github.com/georgeguimaraes/review.nvim) as of `v2.0.0`: storage was rewritten onto DuckDB (multi-writer safe), and the focus is now general-purpose multi-author commenting.

## Scope

review.nvim reviews local diffs (working tree, commits, revision ranges) — it does not integrate with GitHub/GitLab pull or merge requests. For reviewing and commenting on PRs/MRs from within Neovim, see [octo.nvim](https://github.com/pwntester/octo.nvim).

## Features

- Add comments to specific lines in diff view (Note, Suggestion, Issue, Praise)
- Comment borders are colored per author and adapt to `:set background`
- Comments persist per branch in a local DuckDB file (`~/.local/share/nvim/review/`), safe for concurrent writers (e.g. you and an AI agent)
- An AI agent can read and add comments in that file via a bundled [skill](skills/review-nvim), without opening Neovim
- Auto-export comments to clipboard when closing
- Send comments directly to [sidekick.nvim](https://github.com/folke/sidekick.nvim) for AI chat
- Commit picker modal to select specific commits to review
- Built on top of codediff.nvim

## Requirements

- Neovim >= 0.11
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- [`duckdb`](https://duckdb.org) CLI on your `$PATH` (used for comment storage)

## Installation

Using lazy.nvim:

```lua
{
  "tkolleh/review.nvim",
  dependencies = {
    "esmuellert/codediff.nvim",
    "MunifTanjim/nui.nvim",
  },
  cmd = { "Review" },
  keys = {
    { "<leader>r", "<cmd>Review<cr>", desc = "Review" },
    { "<leader>R", "<cmd>Review commits<cr>", desc = "Review commits" },
  },
  opts = {},
}
```

## Usage

```vim
:Review              " Open codediff with comment keymaps (default)
:Review open         " Same as above
:Review commits      " Select commits to review (picker modal)
:Review commits SHA  " Review a single commit (diffs SHA^ against SHA)
:Review commits REV1 REV2  " Review specific revision range (skips picker)
:Review merge-base REV1 [REV2]  " Review REV2 (default HEAD) since its merge base with REV1, like a PR
:Review close        " Close and export comments to clipboard
:Review export       " Export comments to clipboard
:Review preview      " Preview exported markdown in split
:Review sidekick     " Send comments to sidekick.nvim
:Review list         " List all comments
:Review clear        " Clear all comments
```

## Workflow

Open a review with `:Review` (staged/unstaged changes) or `:Review commits` (pick specific commits). For a PR-style review run `:Review merge-base origin/main`; to diff the working tree against any ref, run `:CodeDiff REF` — review's keymaps attach to any codediff session. The diff opens in a new tab, locked against edits, with a file panel on the left.

Navigate with codediff's `]f`/`[f` (files), `<leader>b` (file panel), `t` (side-by-side/inline), `<C-w>h`/`<C-w>l` (old/new pane). Press `<localleader>c` on a line to comment; pick a type (note, suggestion, issue, praise) from the menu. The comment renders as a box below the line with a sign in the gutter.

Visually select a range before `<localleader>c` for a multi-line comment, or press `<localleader>f` for a file-level comment. Left-side (old) and right-side (new) comments only show on their own side.

Use `]n`/`[n` to jump between comments, `<localleader>e` to edit, `<localleader>d` to delete, `c` to list and jump to any comment.

Press `q` to close the review — this copies all comments to the clipboard as structured markdown (see [Export Format](#export-format)) and shows a preview, ready to paste into Claude Code, sidekick.nvim (`S`), or any AI chat. Comments persist per branch and survive closing Neovim, expiring after 7 days.

Author border colors are computed by DuckDB (a `GENERATED ALWAYS AS` column), so they only apply to sessions created after upgrading; run `:Review clear` to reset an older session file.

## Agent comments

An AI agent can read and add comments in the same DuckDB file from the CLI, so you and an agent can converse in one review thread without opening Neovim. Install the bundled [skill](skills/review-nvim) with [`npx skills`](https://skills.sh):

```bash
npx skills@latest add https://github.com/tkolleh/review.nvim/tree/main/skills/review-nvim
```

## Keybindings and configuration (in diff view)

The diff is always locked against edits, so review.nvim's own keys never shadow a Vim motion. Each key is an option under `opts.keymaps`; set it to `false` to disable it.

| Key | Option | Action |
|-----|--------|--------|
| `<localleader>c` | `add_comment` | Add comment (pick type from menu) |
| `<localleader>f` | `add_file_comment` | Add file-level comment |
| `<localleader>e` | `edit_comment` | Edit comment at cursor |
| `<localleader>d` | `delete_comment` | Delete comment at cursor |
| `]n` / `[n` | `next_comment` / `prev_comment` | Jump to next/previous comment |
| `c` | `list_comments` | List all comments |
| `C` | `export_clipboard` | Export to clipboard and show preview |
| `S` | `send_sidekick` | Send comments to sidekick.nvim |
| `<C-r>` | `clear_comments` | Clear all comments |
| `q` | `close` | Close and export comments to clipboard |
| `?` | `show_help` | Show review.nvim keymap help |

Courtesy of codediff.nvim itself: `]f`/`[f` (next/previous file), `<leader>b` (toggle file panel),
`t` (toggle side-by-side/inline layout), `g?` (codediff help).

**Comment popup** (when adding/editing):
| Key | Option | Action |
|-----|--------|--------|
| `Enter` | — | Insert newline (multi-line comments supported) |
| `Ctrl+s` | `popup_submit` | Submit comment |
| `Tab` | `popup_cycle_type` | Cycle comment type |
| `Esc` / `q` | `popup_cancel` | Cancel (normal mode) |


## Export Format

Comments are exported as Markdown optimized for AI consumption:

```markdown
I reviewed your code and have the following comments. Please address them.

Comment types: ISSUE (problems to fix), SUGGESTION (improvements), NOTE (observations), PRAISE (positive feedback)

1. **[ISSUE]** `src/components/Button.tsx:23` - Wrapping onClick creates a new function every render
2. **[SUGGESTION]** `src/utils/api.ts:~45` - The old implementation was cleaner
3. **[PRAISE]** `src/hooks/useAuth.ts:12-18` - Clean implementation of the auth flow
```

Lines prefixed with `~` (e.g. `:~45`) refer to the old (left) side of the diff. Range comments use `start-end` notation.

## Running Tests

```bash
just test
```


## 🌟 Credits

The PR review panel is heavily inspired by [tuicr](https://github.com/agavra/tuicr).
