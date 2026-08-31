local M = {}

-- store.lua's add/update/delete/resolve are callback-based (backed by
-- short-lived duckdb CLI subprocess calls, specs/review-storage.allium's
-- CommentAuthor @guidance). These helpers let specs keep an
-- assert-immediately-after style without becoming async-aware themselves.

local ADD_ARITY = 7

---@return Comment
function M.add(store, ...)
  local args = { ... }
  local comment, err
  local done = false

  args[ADD_ARITY + 1] = function(result, e)
    comment = result
    err = e
    done = true
  end
  store.add(unpack(args, 1, ADD_ARITY + 1))

  vim.wait(2000, function()
    return done
  end, 10)
  assert(done, "store.add callback did not fire within timeout")
  assert(comment, "store.add failed: " .. tostring(err))
  return comment
end

---@return boolean ok, string|nil err
function M.update(store, id, expected_prior_content, new_content, new_type)
  local ok, err
  local done = false

  store.update(id, expected_prior_content, new_content, new_type, function(result, e)
    ok = result
    err = e
    done = true
  end)

  vim.wait(2000, function()
    return done
  end, 10)
  assert(done, "store.update callback did not fire within timeout")
  return ok, err
end

---@return boolean ok, string|nil err
function M.delete(store, id, expected_prior_content)
  local ok, err
  local done = false

  store.delete(id, expected_prior_content, function(result, e)
    ok = result
    err = e
    done = true
  end)

  vim.wait(2000, function()
    return done
  end, 10)
  assert(done, "store.delete callback did not fire within timeout")
  return ok, err
end

---@return boolean
function M.resolve(store, id)
  local ok
  local done = false

  store.resolve(id, function(result)
    ok = result
    done = true
  end)

  vim.wait(2000, function()
    return done
  end, 10)
  assert(done, "store.resolve callback did not fire within timeout")
  return ok
end

return M
