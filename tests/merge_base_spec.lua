local review = require("review")

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

describe("review merge-base", function()
  local repo, orig_cwd

  before_each(function()
    orig_cwd = vim.fn.getcwd()
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    git(repo, "init", "-q", "-b", "main")
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    vim.fn.delete(repo, "rf")
  end)

  describe("resolve_merge_base", function()
    it("returns the fork commit, ignoring commits added to the base since", function()
      local fork = commit(repo, "fork")
      git(repo, "checkout", "-q", "-b", "topic")
      commit(repo, "mine")
      git(repo, "checkout", "-q", "main")
      commit(repo, "theirs")

      local result = review.resolve_merge_base("main", "topic")

      assert.is_true(result.ok)
      assert.are.equal(fork, result.sha)
    end)

    it("reports unrelated histories as no common ancestor", function()
      commit(repo, "root")
      git(repo, "checkout", "-q", "--orphan", "unrelated")
      commit(repo, "other root")

      local result = review.resolve_merge_base("main", "unrelated")

      assert.is_false(result.ok)
      assert.truthy(result.err:match("no common ancestor between main and unrelated"))
    end)

    it("surfaces git's error for an unknown ref", function()
      commit(repo, "root")

      local result = review.resolve_merge_base("main", "nonexistent")

      assert.is_false(result.ok)
      assert.truthy(result.err:match("nonexistent"))
    end)
  end)

  describe("open_merge_base", function()
    local orig_resolve, orig_notify, notified

    before_each(function()
      orig_resolve = review.resolve_merge_base
      orig_notify = vim.notify
      notified = {}
      vim.notify = function(msg, level)
        table.insert(notified, { msg = msg, level = level })
      end
    end)

    after_each(function()
      review.resolve_merge_base = orig_resolve
      vim.notify = orig_notify
    end)

    it("warns with usage and resolves nothing when REV1 is missing", function()
      local called = false
      review.resolve_merge_base = function()
        called = true
        return { ok = false, err = "unreachable" }
      end

      review.open_merge_base(nil, nil)

      assert.is_false(called)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
      assert.truthy(notified[1].msg:match("Usage"))
    end)

    it("defaults REV2 to HEAD", function()
      local seen
      review.resolve_merge_base = function(rev1, rev2)
        seen = { rev1, rev2 }
        return { ok = false, err = "stop here" }
      end

      review.open_merge_base("origin/main")

      assert.are.same({ "origin/main", "HEAD" }, seen)
    end)

    it("notifies an error and opens nothing when resolution fails", function()
      review.resolve_merge_base = function()
        return { ok = false, err = "no common ancestor between a and b" }
      end

      review.open_merge_base("a", "b")

      assert.are.equal(vim.log.levels.ERROR, notified[1].level)
      assert.are.equal("no common ancestor between a and b", notified[1].msg)
    end)
  end)
end)
