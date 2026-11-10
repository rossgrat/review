package.path = "./lua/?.lua;" .. package.path
local core = require("review.core")
local run = core.run
local calls, subprocess_ms = 0, 0
core.run = function(...)
  calls = calls + 1
  local started = vim.uv.hrtime()
  local output, code = run(...)
  subprocess_ms = subprocess_ms + (vim.uv.hrtime() - started) / 1e6
  return output, code
end
local function measure(name, fn)
  calls, subprocess_ms = 0, 0
  local started = vim.uv.hrtime()
  local ok, result = pcall(fn)
  print(
    string.format(
      "%s: %.0f ms, %d processes, %.0f ms in processes%s",
      name,
      (vim.uv.hrtime() - started) / 1e6,
      calls,
      subprocess_ms,
      ok and "" or " ERROR " .. tostring(result)
    )
  )
  return ok and result or nil
end
local repos = measure("Repositories", function() return core.discover(assert(arg[1], "Pass a directory")) end)
if repos then print(string.format("%d repositories", #repos)) end
if arg[2] then
  local repo = { path = arg[2] }
  local prs = measure("PR list", function() return core.pull_requests(repo) end)
  if prs and prs[1] then
    local pr = measure("PR detail", function() return core.pull_request(repo, prs[1].number) end)
    if pr then
      local paths = core.git(repo.path, { "ls-tree", "-r", "--name-only", pr.base.sha })
      local path = paths:match("[^\n]+")
      if path then
        local session = { path = repo.path, base = pr.base.sha }
        local file = { status = "M", path = path, old_path = path }
        measure("Base file first read", function() return core.original(session, file) end)
        measure("Base file reread x30", function()
          for _ = 1, 30 do
            core.original(session, file)
          end
        end)
      end
      measure("Local PR objects", function()
        for _, sha in ipairs({ pr.base.sha, pr.head.sha }) do
          local _, code = core.git(repo.path, { "cat-file", "-e", sha .. "^{commit}" }, true)
          print(sha:sub(1, 8) .. (code == 0 and " present" or " missing"))
        end
      end)
      measure(
        "GitHub SSH connection",
        function() return core.git(repo.path, { "ls-remote", "origin", "refs/heads/" .. pr.base.ref }) end
      )
    end
  end
end
