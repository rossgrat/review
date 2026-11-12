package.path = "./lua/?.lua;" .. package.path
local api, core = vim.api, require("review.core")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME = root .. "/data", root .. "/state"
vim.env.GOPROXY, vim.env.GOSUMDB = "off", "off"
vim.env.GOTOOLCHAIN = "local"
local client
local ok, err = xpcall(function()
  local tools = vim.fn.stdpath("data") .. "/bin"
  vim.fn.mkdir(tools, "p")
  core.run({ "cp", assert(arg[1], "Pass the pinned gopls binary"), tools .. "/gopls" })
  vim.fn.writefile({ "module example.test/lsp", "", "go 1.25.0" }, root .. "/go.mod")
  local line = "\treturn strings.ToUpper(value)"
  vim.fn.writefile({
    "package example",
    'import "strings"',
    "func Example(value string) string {",
    line,
    "}",
    "var Broken = DoesNotExist",
  }, root .. "/example.go")
  require("review.lsp").setup()
  vim.cmd.edit(root .. "/example.go")
  vim.bo.filetype = "go"
  local buffer = api.nvim_get_current_buf()
  local id = assert(require("review.lsp").attach(buffer, root))
  client = assert(vim.lsp.get_client_by_id(id))
  assert(vim.wait(30000, function() return client.initialized end, 10), "gopls did not initialize")
  local function request(method, prefix)
    local start = assert(line:find(prefix, 1, true))
    local response = assert(client:request_sync(method, {
      textDocument = { uri = vim.uri_from_bufnr(buffer) },
      position = { line = 3, character = start - 1 + #prefix },
    }, 15000, buffer))
    assert(not response.err, vim.inspect(response.err))
    return response.result
  end
  local completion = request("textDocument/completion", "strings.To")
  local found = false
  for _, item in ipairs(completion.items or completion) do
    if item.label:find("ToUpper", 1, true) then found = true end
  end
  assert(found, "gopls did not complete strings.ToUpper")
  local hover = request("textDocument/hover", "strings.ToUp")
  assert(hover.contents)
  local hint = assert(request("textDocument/signatureHelp", "strings.ToUpper("))
  assert(hint.signatures[1].label:find("ToUpper", 1, true))
  assert(
    vim.wait(15000, function() return #vim.diagnostic.get(buffer) > 0 end, 10),
    "gopls did not publish diagnostics"
  )
  local undefined = false
  for _, diagnostic in ipairs(vim.diagnostic.get(buffer)) do
    if diagnostic.message:find("DoesNotExist", 1, true) then undefined = true end
  end
  assert(undefined, "gopls did not report the undefined identifier")
  print("PASS real gopls completion, hover, parameter hints, and diagnostics")
end, debug.traceback)
if client then
  client:stop()
  vim.wait(2000, function() return client:is_stopped() end, 10)
end
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
