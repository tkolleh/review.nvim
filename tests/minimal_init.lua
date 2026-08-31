local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
local is_not_a_directory = vim.fn.isdirectory(plenary_dir) == 0
if is_not_a_directory then
  vim.fn.system({ "git", "clone", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end

-- Isolate this process's review.storage data dir from the real XDG path.
-- PlenaryBustedDirectory runs each spec file as its own concurrent
-- `nvim --headless` subprocess (plenary/test_harness.lua), each re-running
-- this file via `-u tests/minimal_init.lua`. A child subprocess inherits
-- REVIEW_NVIM_TEST_DATA_DIR from whatever launched it (the outer
-- `PlenaryBustedDirectory` process), so checking "already set" before
-- generating one would make every spec file share the outer process's one
-- temp dir -- the exact same collision as the real XDG path, just moved.
-- Always mint a fresh one here so each subprocess gets its own.
vim.fn.setenv("REVIEW_NVIM_TEST_DATA_DIR", vim.fn.tempname())

vim.opt.rtp:append(".")
vim.opt.rtp:append(plenary_dir)

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
