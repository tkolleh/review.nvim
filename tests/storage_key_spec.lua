local storage = require("review.storage")

local function git(dir, ...)
  local out = vim.system({
    "git", "-C", dir,
    "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
    ...,
  }, { text = true }):wait()
  assert.are.equal(0, out.code, out.stderr)
  return vim.trim(out.stdout)
end

local function commit(dir, msg)
  git(dir, "commit", "--allow-empty", "-m", msg)
  return git(dir, "rev-parse", "HEAD")
end

-- The "<rev1>_<rev2>" part of ".../<project-hash>-<rev1>_<rev2>.duckdb".
local function key_of(path)
  local filename = path:match("([^/]+)%.duckdb$")
  return filename:match("^[^%-]+%-(.+)$")
end

describe("review.storage revision keys", function()
  local repo, orig_cwd

  before_each(function()
    orig_cwd = vim.fn.getcwd()
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    git(repo, "init", "-q", "-b", "feat/x")
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
  end)

  after_each(function()
    storage.clear_revisions()
    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    vim.fn.delete(repo, "rf")
  end)

  it("keys a literal REV2 HEAD on the branch name", function()
    local fork = commit(repo, "fork")

    storage.set_revisions(fork, "HEAD")

    assert.are.equal(fork:sub(1, 8) .. "_feat_x", key_of(storage.get_storage_path()))
  end)

  it("keys a literal REV2 HEAD on the short SHA when detached", function()
    local fork = commit(repo, "fork")
    git(repo, "checkout", "-q", "--detach")

    storage.set_revisions(fork, "HEAD")

    assert.are.equal(fork:sub(1, 8) .. "_" .. fork:sub(1, 8), key_of(storage.get_storage_path()))
  end)

  it("pins HEAD-relative REV1 to a commit so each reviewed commit keeps its own file", function()
    commit(repo, "one")
    storage.set_revisions("HEAD^", "HEAD")
    local before = storage.get_storage_path()

    commit(repo, "two")
    storage.set_revisions("HEAD^", "HEAD")

    assert.are_not.equal(before, storage.get_storage_path())
  end)

  it("keys REV1 HEAD^ on the commit and only the REV2 tip on the branch", function()
    local tip = commit(repo, "one")

    storage.set_revisions("HEAD^", "HEAD")

    assert.are.equal(tip:sub(1, 8) .. "_feat_x", key_of(storage.get_storage_path()))
  end)

  it("keeps digit-only tags on different commits apart", function()
    local c1 = commit(repo, "one")
    git(repo, "tag", "1234567890", c1)
    local c2 = commit(repo, "two")
    git(repo, "tag", "1234567891", c2)

    storage.set_revisions("1234567890", "x")
    local p1 = storage.get_storage_path()
    storage.set_revisions("1234567891", "x")

    assert.are_not.equal(p1, storage.get_storage_path())
  end)

  it("gives an abbreviated and a full SHA of the same commit the same key", function()
    local sha = commit(repo, "one")

    storage.set_revisions(sha, "x")
    local full = storage.get_storage_path()
    storage.set_revisions(sha:sub(1, 12), "x")

    assert.are.equal(full, storage.get_storage_path())
  end)

  it("does not move the key when the checkout changes mid-session", function()
    local fork = commit(repo, "fork")
    storage.set_revisions(fork, "HEAD")
    local before = storage.get_storage_path()

    git(repo, "checkout", "-q", "-b", "other")

    assert.are.equal(before, storage.get_storage_path())
  end)

  it("does not shell-interpret or option-parse a hostile revision", function()
    commit(repo, "one")

    storage.set_revisions("--all", "$(touch pwned)")

    assert.is_nil(vim.uv.fs_stat(repo .. "/pwned"))
    assert.truthy(storage.get_storage_path():match("%.duckdb$"))
  end)
end)
