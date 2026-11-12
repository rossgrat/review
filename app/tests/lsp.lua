package.path = "./lua/?.lua;" .. package.path
local api, core = vim.api, require("review.core")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME = root .. "/data", root .. "/state"
vim.env.PR_REVIEW_LSP_TEST_LOG = root .. "/requests.jsonl"
vim.g.mapleader = " "
require("review.theme").setup()
require("review.lsp").setup()
local ui, passed = require("review.ui"), 0

local function equal(actual, expected)
  assert(
    vim.deep_equal(actual, expected),
    "Expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
end
local function put(path, contents) vim.fn.writefile(vim.split(contents, "\n", { plain = true }), path) end
local function wait(condition) assert(vim.wait(5000, condition, 10), "Language support operation timed out") end
local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
end
local function floats()
  local result = {}
  for _, window in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(window).relative ~= "" then result[#result + 1] = window end
  end
  return result
end
local function text(window)
  return table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(window), 0, -1, false), "\n")
end
local function close_floats()
  for _, window in ipairs(floats()) do
    api.nvim_win_close(window, true)
  end
end
local function requests()
  local result = {}
  for _, line in ipairs(vim.fn.readfile(vim.env.PR_REVIEW_LSP_TEST_LOG)) do
    result[#result + 1] = vim.json.decode(line)
  end
  return result
end
local function choose(path)
  api.nvim_set_current_win(ui.state.list)
  for line, row in pairs(ui.state.tree_rows) do
    if row.path == path then
      api.nvim_win_set_cursor(0, { line, 0 })
      vim.fn.maparg("<CR>", "n", false, true).callback()
      wait(function() return not ui.state.busy end)
      return
    end
  end
  error("Missing file: " .. path)
end
local function insert(keys, checks)
  local failure
  _G.review_lsp_check = function(index)
    if failure then return end
    api.nvim_exec_autocmds("TextChangedI", { buffer = api.nvim_get_current_buf() })
    local ok, err = pcall(checks[index])
    if not ok then failure = err end
  end
  keys = keys:gsub("{(%d+)}", function(index) return "<Cmd>lua review_lsp_check(" .. index .. ")<CR>" end)
  api.nvim_feedkeys(vim.keycode(keys .. "<Esc>"), "xt", false)
  vim.wait(30, function() return false end)
  api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  _G.review_lsp_check = nil
  assert(not failure, failure)
end

local ok, err = xpcall(function()
  local tools = vim.fn.stdpath("data") .. "/bin"
  vim.fn.mkdir(tools, "p")
  local server = vim.fn.fnamemodify("tests/lsp_server.lua", ":p")
  put(
    tools .. "/gopls",
    "#!/bin/sh\nexec "
      .. vim.fn.shellescape(vim.v.progpath)
      .. " --headless --noplugin -i NONE -u NONE -l "
      .. vim.fn.shellescape(server)
  )
  vim.uv.fs_chmod(tools .. "/gopls", 493)
  local checkout = root .. "/repo"
  core.run({ "git", "init", "--initial-branch=main", checkout })
  core.git(checkout, { "config", "user.name", "Review Test" })
  core.git(checkout, { "config", "user.email", "review-test@example.invalid" })
  core.git(checkout, { "config", "commit.gpgsign", "false" })
  put(checkout .. "/go.mod", "module example.test/review\n\ngo 1.25.0")
  put(checkout .. "/main.go", "package main\n\nfunc main() {\n\t\n}")
  put(checkout .. "/other.go", "package main")
  put(checkout .. "/reference.go", "package main\n\nvar Reference = true")
  core.git(checkout, { "add", "--", "go.mod", "main.go", "other.go", "reference.go" })
  core.git(checkout, { "commit", "-m", "Base" })
  local base = vim.trim(core.git(checkout, { "rev-parse", "HEAD" }))
  core.git(checkout, { "switch", "-c", "feature" })
  put(checkout .. "/main.go", "package main\n\nfunc main() {\n\t\n}\n\nvar Updated = true")
  put(checkout .. "/other.go", "package main\n\nvar Other = true")
  put(checkout .. "/notes.txt", "Notes")
  core.git(checkout, { "add", "--", "main.go", "other.go", "notes.txt" })
  core.git(checkout, { "commit", "-m", "PR" })
  local project = { full_name = "example/review" }
  local pr = {
    number = 1,
    title = "Go changes",
    state = "open",
    base = { ref = "main", sha = base, repo = project },
    head = { ref = "feature", sha = vim.trim(core.git(checkout, { "rev-parse", "HEAD" })), repo = project },
  }
  local repository = { path = checkout, common = checkout .. "/.git", slug = project.full_name }
  core.pull_request = function() return pr end
  ui.start(checkout)
  wait(function() return not ui.state.busy end)

  test("Go support starts with editable code and reuses a server across files", function()
    equal(#vim.lsp.get_clients(), 0)
    ui.state.repo = repository
    ui.open(pr)
    wait(function() return not ui.state.busy end)
    wait(function() return #vim.lsp.get_clients({ bufnr = api.nvim_win_get_buf(ui.state.right) }) == 1 end)
    local client = vim.lsp.get_clients()[1]
    wait(
      function() return client.initialized and vim.bo[api.nvim_win_get_buf(ui.state.right)].omnifunc ~= "" end
    )
    equal(#vim.lsp.get_clients({ bufnr = api.nvim_win_get_buf(ui.state.left) }), 0)
    equal(#vim.lsp.get_clients({ bufnr = ui.state.file_buffer }), 0)
    equal(client.server_capabilities.semanticTokensProvider, nil)
    equal(vim.bo[api.nvim_win_get_buf(ui.state.right)].tagfunc, "")
    equal(vim.fn.maparg("grr", "n"), "")
    choose("other.go")
    equal(vim.lsp.get_clients({ bufnr = api.nvim_win_get_buf(ui.state.right) })[1].id, client.id)
    choose("notes.txt")
    equal(#vim.lsp.get_clients({ bufnr = api.nvim_win_get_buf(ui.state.right) }), 0)
    choose("main.go")
    local starts = 0
    for _, request in ipairs(requests()) do
      if request.method == "initialize" then
        starts = starts + 1
        equal(request.params.capabilities.workspace.didChangeWatchedFiles.dynamicRegistration, false)
      end
    end
    equal(starts, 1)
  end)

  test("the docked Go editor reuses language support without moving the review", function()
    local client = vim.lsp.get_clients({ bufnr = api.nvim_win_get_buf(ui.state.right) })[1]
    ui.toggle_files()
    wait(function() return not ui.state.busy end)
    choose("reference.go")
    local peek = assert(ui.state.peek)
    wait(function() return #vim.lsp.get_clients({ bufnr = peek.buffer }) == 1 end)
    equal(vim.lsp.get_clients({ bufnr = peek.buffer })[1].id, client.id)
    equal(ui.state.selected, "main.go")
    equal(vim.wo[peek.window].diff, false)
    equal(vim.bo[peek.buffer].modifiable, true)
    vim.cmd("ReviewClosePeek")
    ui.toggle_files()
    wait(function() return not ui.state.busy end)
  end)

  local buffer = api.nvim_win_get_buf(ui.state.right)
  local original = api.nvim_buf_get_lines(buffer, 0, -1, false)
  local function reset()
    api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    vim.snippet.stop()
    close_floats()
    api.nvim_set_current_win(ui.state.right)
    api.nvim_buf_set_lines(buffer, 0, -1, false, original)
    vim.bo[buffer].modified = false
    api.nvim_win_set_cursor(0, { 4, 0 })
  end
  test("completion appears while typing and acceptance applies imports and placeholders", function()
    reset()
    insert("APro{1}<C-n>{2}<CR>", {
      function()
        wait(function() return vim.fn.pumvisible() == 1 end)
        equal(vim.fn.complete_info({ "selected" }).selected, -1)
      end,
      function()
        wait(function()
          for _, window in ipairs(floats()) do
            if text(window):find("Processes a value", 1, true) then return true end
          end
        end)
      end,
    })
    wait(
      function()
        return table
          .concat(api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
          :find('import "example.test/support"', 1, true) ~= nil
      end
    )
    assert(table.concat(api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"):find("Process(value)", 1, true))
    equal(api.nvim_get_current_win(), ui.state.right)
  end)
  test("Enter with no selected suggestion inserts a newline", function()
    reset()
    insert("APro{1}<CR>", {
      function()
        wait(function() return vim.fn.pumvisible() == 1 end)
      end,
    })
    local contents = table.concat(api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    assert(contents:find("Pro\n", 1, true))
    assert(not contents:find("Process", 1, true))
    equal(api.nvim_buf_line_count(buffer), #original + 1)
  end)
  test("Tab indents and Escape dismisses a selected completion without accepting it", function()
    for _, key in ipairs({ "<Tab>", "<Esc>" }) do
      reset()
      insert("APro{1}<C-n>" .. key, {
        function()
          wait(function() return vim.fn.pumvisible() == 1 end)
        end,
      })
      local contents = table.concat(api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
      assert(not contents:find("Process", 1, true))
      assert(not contents:find("import", 1, true))
      if key == "<Tab>" then assert(contents:find("Pro\t", 1, true)) end
    end
  end)
  test("function hints update the active argument and close after the call", function()
    reset()
    insert("AProcess({1}value, {2}){3}", {
      function()
        wait(function() return #floats() > 0 end)
        assert(text(floats()[1]):find("value string", 1, true))
        equal(vim.wo[floats()[1]].diff, false)
        equal(api.nvim_get_current_win(), ui.state.right)
      end,
      function()
        vim.wait(180, function() return false end)
        wait(function() return #floats() > 0 end)
        local marks = api.nvim_buf_get_extmarks(
          api.nvim_win_get_buf(floats()[1]),
          api.nvim_create_namespace("nvim.lsp.signature_help"),
          0,
          -1,
          { details = true }
        )
        assert(#marks > 0)
      end,
      function()
        wait(function() return #floats() == 0 end)
      end,
    })
  end)
  test("hover and diagnostic details use popups while diff colors remain intact", function()
    reset()
    api.nvim_feedkeys("K", "xt", false)
    wait(function() return #floats() > 0 end)
    assert(text(floats()[1]):find("Processes a value", 1, true))
    equal(vim.wo[floats()[1]].diff, false)
    close_floats()
    api.nvim_win_set_cursor(ui.state.right, { 1, 0 })
    api.nvim_feedkeys(" d", "xt", false)
    wait(function() return #floats() > 0 end)
    assert(text(floats()[1]):find("Example error", 1, true))
    local config = vim.diagnostic.config()
    equal(config.virtual_text, false)
    equal(config.virtual_lines, false)
    equal(config.underline, false)
    assert(vim.wo[ui.state.right].winhighlight:find("DiffChange:ReviewDiffAdd", 1, true))
    assert(vim.wo[ui.state.left].winhighlight:find("DiffChange:ReviewDiffRemove", 1, true))
    local signs = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })) do
      if mark[4].sign_text then signs[vim.trim(mark[4].sign_text)] = true end
    end
    assert(signs.E and signs.W)
    for _, request in ipairs(requests()) do
      assert(request.method ~= "textDocument/semanticTokens/full")
    end
    reset()
  end)
  test("pulling reloads Go support for the updated checkout", function()
    local previous = vim.lsp.get_clients({ bufnr = buffer })[1].id
    ui.open(pr, true)
    wait(function() return not ui.state.busy end)
    wait(function()
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = api.nvim_win_get_buf(ui.state.right) })) do
        if client.id ~= previous and client.initialized then return true end
      end
    end)
    equal(ui.state.selected, "main.go")
    assert(vim.fn.maparg("<CR>", "i", false, true).expr == 1)
  end)
end, debug.traceback)

for _, client in ipairs(vim.lsp.get_clients()) do
  client:stop()
end
vim.wait(1000, function() return #vim.lsp.get_clients() == 0 end, 10)
if not ok then
  io.stderr:write(err .. "\n")
  local log = vim.fn.stdpath("state") .. "/lsp.log"
  if vim.fn.filereadable(log) == 1 then io.stderr:write(table.concat(vim.fn.readfile(log), "\n") .. "\n") end
  vim.fn.delete(root, "rf")
  vim.cmd("cquit 1")
end
vim.fn.delete(root, "rf")
print(string.format("%d language support tests passed", passed))
