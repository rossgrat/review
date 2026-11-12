package.path = "./lua/?.lua;" .. package.path
local api, core = vim.api, require("review.core")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME = root .. "/data", root .. "/state"
vim.env.PR_REVIEW_DESCRIPTION_STATE = root .. "/github.json"
vim.env.PR_REVIEW_DESCRIPTION_LOG = root .. "/requests.jsonl"
vim.opt.hidden, vim.opt.splitright = true, true
vim.opt.runtimepath = { vim.fn.fnamemodify(".", ":p"), vim.env.VIMRUNTIME }
vim.opt.packpath = {}
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
require("review.theme").setup()
require("review.lsp").setup()
local ui, description = require("review.ui"), require("review.description")
local passed, errors, approve = 0, {}, false
local function equal(actual, expected)
  assert(
    vim.deep_equal(actual, expected),
    "Expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
end
local function put(path, body)
  local file = assert(io.open(path, "wb"))
  file:write(body)
  file:close()
end
local function read(path)
  local file = assert(io.open(path, "rb"))
  local body = file:read("*a")
  file:close()
  return body
end
local function state() return vim.json.decode(read(vim.env.PR_REVIEW_DESCRIPTION_STATE)) end
local function remote(value) put(vim.env.PR_REVIEW_DESCRIPTION_STATE, vim.json.encode(value)) end
local function finish()
  assert(vim.wait(10000, function() return not ui.state.busy end, 10), "PR operation timed out")
end
local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
end
local function calls()
  local result = {}
  for line in read(vim.env.PR_REVIEW_DESCRIPTION_LOG):gmatch("[^\n]+") do
    result[#result + 1] = vim.json.decode(line)
  end
  return result
end
local function writes()
  local result = {}
  for _, call in ipairs(calls()) do
    if call.args[1] == "pr" then result[#result + 1] = call end
  end
  return result
end
local function edit(body)
  api.nvim_buf_set_lines(ui.state.description.buffer, 0, -1, false, vim.split(body, "\n", { plain = true }))
end
local function body()
  return table.concat(api.nvim_buf_get_lines(ui.state.description.buffer, 0, -1, false), "\n")
end
local function submit()
  vim.cmd("write")
  finish()
end

local select, notify = vim.ui.select, vim.notify
vim.ui.select = function(choices, opts, done)
  equal(choices, { "Update and mark ready", "Cancel" })
  assert(opts.prompt:find("example/description #17", 1, true))
  done(approve and choices[1] or choices[2])
end
vim.notify = function(message, level)
  if level == vim.log.levels.ERROR then errors[#errors + 1] = message end
end
local ok, err = xpcall(function()
  local bin, repo = root .. "/bin", root .. "/repo"
  vim.fn.mkdir(bin, "p")
  put(
    bin .. "/gh",
    "#!/bin/sh\nexec "
      .. vim.fn.shellescape(vim.v.progpath)
      .. " --headless --noplugin -i NONE -u NONE -l "
      .. vim.fn.shellescape(vim.fn.fnamemodify("tests/pr_gh.lua", ":p"))
      .. ' "$@"\n'
  )
  vim.uv.fs_chmod(bin .. "/gh", 493)
  vim.env.PATH = bin .. ":" .. vim.env.PATH
  core.run({ "git", "init", "--initial-branch=main", repo })
  local function git(args) return core.git(repo, args) end
  git({ "config", "user.name", "Review Test" })
  git({ "config", "user.email", "review-test@example.invalid" })
  git({ "config", "commit.gpgsign", "false" })
  put(repo .. "/code.txt", "Original code\n")
  git({ "add", "--", "code.txt" })
  git({ "commit", "-m", "Base" })
  local base = vim.trim(git({ "rev-parse", "HEAD" }))
  git({ "switch", "-c", "feature" })
  put(repo .. "/code.txt", "Changed code\n")
  git({ "add", "--", "code.txt" })
  git({ "commit", "-m", "PR" })
  local project = { full_name = "example/description" }
  local pr = {
    number = 17,
    title = "Description fixture",
    state = "open",
    draft = true,
    body = "## Summary\n\nExisting `description`.\n",
    head = { ref = "feature", sha = vim.trim(git({ "rev-parse", "HEAD" })), repo = project },
    base = { ref = "main", sha = base, repo = project },
  }
  remote({ pr = pr })
  put(vim.env.PR_REVIEW_DESCRIPTION_LOG, "")
  local repository = { path = repo, common = repo .. "/.git", slug = project.full_name }
  ui.start(repo)
  finish()
  ui.state.repo = repository
  ui.open(pr)
  finish()
  local code = api.nvim_win_get_buf(ui.state.right)
  local view = api.nvim_win_call(ui.state.right, vim.fn.winsaveview)

  test("the description editor loads current Markdown and cancel performs no GitHub writes", function()
    api.nvim_feedkeys(" e", "xt", false)
    finish()
    local editor = assert(ui.state.description)
    equal(vim.v.errmsg, "")
    equal(body(), pr.body)
    equal(vim.bo[editor.buffer].filetype, "markdown")
    equal(vim.wo[editor.window].diff, false)
    edit("Unpublished edit")
    local window = editor.window
    ui.ready()
    equal(ui.state.description.window, window)
    api.nvim_feedkeys("q", "xt", false)
    equal(description.valid(editor), false)
    equal(#writes(), 0)
    equal(state().pr.body, pr.body)
    equal(state().pr.draft, true)
  end)
  test("canceling publication keeps the editor and text without GitHub writes", function()
    ui.ready()
    finish()
    edit("Keep this edit")
    submit()
    equal(#writes(), 0)
    equal(body(), "Keep this edit")
    equal(vim.bo[ui.state.description.buffer].modifiable, true)
    description.close(ui.state.description)
  end)
  local updated = '## Change\n\nUse `value` and $(touch "'
    .. root
    .. '/must-not-exist") literally.\n\n```go\nvalue := "\\n"\n```\n'
  test(
    "submission updates exact Markdown before marking ready and preserves code edits and review position",
    function()
      api.nvim_buf_set_lines(code, -1, -1, false, { "Unsaved code edit" })
      ui.state.pr_cache[repository.common] = { loaded = 1 }
      ui.ready()
      finish()
      edit(updated)
      approve = true
      submit()
      local operations = writes()
      equal(#operations, 2)
      equal(operations[1].args[2], "edit")
      equal(operations[2].args[2], "ready")
      equal(operations[1].body, updated)
      equal(state().pr.body, updated)
      equal(state().pr.draft, false)
      equal(vim.uv.fs_stat(root .. "/must-not-exist"), nil)
      equal(api.nvim_get_current_win(), ui.state.right)
      equal(ui.state.selected, "code.txt")
      equal(vim.bo[code].modified, true)
      equal(api.nvim_win_call(ui.state.right, vim.fn.winsaveview), view)
      equal(read(repo .. "/code.txt"), "Changed code\n")
      equal(ui.state.session.pr.draft, false)
      equal(ui.state.pr_cache[repository.common], nil)
      api.nvim_buf_set_lines(code, 0, -1, false, { "Changed code" })
      vim.bo[code].modified = false
    end
  )
  test("an already-ready PR updates its description without another readiness write", function()
    local count = #writes()
    ui.ready()
    finish()
    edit("Updated ready PR")
    submit()
    equal(#writes(), count + 1)
    equal(writes()[#writes()].args[2], "edit")
    equal(state().pr.body, "Updated ready PR")
  end)
  test("a description update failure leaves the draft unchanged and keeps text for retry", function()
    local value = state()
    value.pr.draft = true
    value.fail = "edit"
    remote(value)
    ui.ready()
    finish()
    edit("Retry the description")
    local count = #writes()
    submit()
    equal(#writes(), count + 1)
    equal(state().pr.draft, true)
    equal(state().pr.body, "Updated ready PR")
    equal(body(), "Retry the description")
    assert(errors[#errors]:find("edit rejected", 1, true))
    equal(vim.bo[ui.state.description.buffer].modifiable, true)
    value = state()
    value.fail = nil
    remote(value)
    submit()
    equal(state().pr.draft, false)
    equal(state().pr.body, "Retry the description")
  end)
  test("a failed readiness update can retry without publishing the body twice", function()
    local value = state()
    value.pr.draft = true
    value.fail = "ready"
    remote(value)
    ui.ready()
    finish()
    edit("Body succeeds first")
    local count = #writes()
    submit()
    equal(state().pr.body, "Body succeeds first")
    equal(state().pr.draft, true)
    equal(body(), "Body succeeds first")
    assert(errors[#errors]:find("Description saved", 1, true))
    value = state()
    value.fail = nil
    remote(value)
    submit()
    local operations = writes()
    equal(#operations, count + 3)
    equal(operations[count + 1].args[2], "edit")
    equal(operations[count + 2].args[2], "ready")
    equal(operations[count + 3].args[2], "ready")
    equal(state().pr.draft, false)
  end)
  test("concurrent description edits and closed PRs stop before any writes", function()
    for _, closed in ipairs({ false, true }) do
      ui.ready()
      finish()
      edit("Local draft text")
      local value = state()
      if closed then
        value.pr.state = "closed"
      else
        value.pr.body = "A newer remote description"
      end
      remote(value)
      local count = #writes()
      submit()
      equal(#writes(), count)
      equal(body(), "Local draft text")
      assert(errors[#errors]:find(closed and "no longer open" or "changed on GitHub", 1, true))
      description.close(ui.state.description)
      value.pr.state = "open"
      remote(value)
    end
  end)
  test("an empty GitHub description can be submitted through Ctrl-s", function()
    local value = state()
    value.pr.body = vim.NIL
    value.pr.draft = true
    remote(value)
    vim.cmd("ReviewReady")
    finish()
    equal(body(), "")
    edit("Description from an empty body")
    vim.fn.maparg("<C-s>", "n", false, true).callback()
    finish()
    equal(state().pr.body, "Description from an empty body")
    equal(state().pr.draft, false)
  end)
end, debug.traceback)
vim.ui.select, vim.notify = select, notify
api.nvim_create_autocmd("VimLeavePre", { once = true, callback = function() vim.fn.delete(root, "rf") end })
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print(string.format("%d PR description tests passed", passed))
