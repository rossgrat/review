package.path = "./lua/?.lua;" .. package.path
local core = require("review.core")
local source = assert(arg[1], "Pass a local GitHub clone")
local number = assert(tonumber(arg[2]), "Pass an open PR number")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_DATA_HOME = root .. "/data"
local ok, err = xpcall(function()
  local origin = vim.trim(core.git(source, { "remote", "get-url", "origin" }))
  core.run({ "git", "clone", "--bare", "--shared", source, root .. "/repo.git" })
  local repo = { path = root .. "/repo.git", common = root .. "/repo.git" }
  core.git(repo.path, { "remote", "set-url", "origin", origin })
  local found = false
  for _, pr in ipairs(core.pull_requests(repo)) do
    if pr.number == number then found = true end
  end
  assert(found, "PR is absent from the live open PR list")
  local pr = core.pull_request(repo, number)
  local started = vim.uv.hrtime()
  local session = core.prepare(repo, pr, root .. "/worktrees")
  print(string.format("First PR preparation: %.0f ms", (vim.uv.hrtime() - started) / 1e6))
  started = vim.uv.hrtime()
  local reopened = core.prepare(repo, pr, root .. "/worktrees")
  assert(vim.uv.fs_realpath(reopened.path) == vim.uv.fs_realpath(session.path))
  print(string.format("Repeated PR preparation: %.0f ms", (vim.uv.hrtime() - started) / 1e6))
  local files = core.changes(session)
  assert(#files > 0, "Live PR contains no local changes")
  for _, file in ipairs(files) do
    core.original(session, file)
  end
  print(
    string.format(
      "LIVE PASS %s #%d: %s -> %s; %d files; local %d ahead, %d behind",
      repo.slug,
      number,
      pr.head.ref,
      pr.base.ref,
      #files,
      session.ahead,
      session.behind
    )
  )
end, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
