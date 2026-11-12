local M = {}
local api = vim.api
local pending, configured = {}, {}
local missing = false

local popup = { border = "rounded", max_width = 72, max_height = 12, silent = true }

local function signature()
  local window = vim.b.lsp_floating_preview
  if window and api.nvim_win_is_valid(window) then api.nvim_win_close(window, true) end
  vim.lsp.buf.signature_help(vim.tbl_extend("force", popup, {
    focusable = false,
    close_events = { "InsertLeave", "BufLeave" },
  }))
end

local function changed(buffer)
  pending[buffer] = (pending[buffer] or 0) + 1
  local generation = pending[buffer]
  vim.defer_fn(function()
    if
      pending[buffer] ~= generation
      or api.nvim_get_current_buf() ~= buffer
      or vim.fn.mode():sub(1, 1) ~= "i"
    then
      return
    end
    local prefix = api.nvim_get_current_line():sub(1, api.nvim_win_get_cursor(0)[2])
    if prefix:match("[%w_%.]$") and vim.fn.pumvisible() == 0 then vim.lsp.completion.get() end
    if prefix:match("[(,)]%s*$") then signature() end
  end, 120)
end

local function attached(client, buffer)
  client.server_capabilities.semanticTokensProvider = nil
  vim.bo[buffer].tagfunc = ""
  vim.lsp.completion.enable(true, client.id, buffer, { autotrigger = true })
  if configured[buffer] then return end
  configured[buffer] = true
  local opts = { buffer = buffer, silent = true }
  vim.keymap.set("n", "K", function() vim.lsp.buf.hover(popup) end, opts)
  vim.keymap.set(
    "n",
    "<leader>d",
    function() vim.diagnostic.open_float(nil, { scope = "line", border = "rounded", focusable = false }) end,
    opts
  )
  vim.keymap.set("i", "<C-Space>", vim.lsp.completion.get, opts)
  vim.keymap.set("i", "<C-s>", signature, opts)
  vim.keymap.set("i", "<CR>", function()
    if vim.fn.pumvisible() == 1 then
      return vim.fn.complete_info({ "selected" }).selected >= 0 and "<C-y>" or "<C-e><CR>"
    end
    return "<CR>"
  end, vim.tbl_extend("force", opts, { expr = true }))
  for _, key in ipairs({ "<Tab>", "<Esc>" }) do
    vim.keymap.set(
      "i",
      key,
      function() return (vim.fn.pumvisible() == 1 and "<C-e>" or "") .. key end,
      vim.tbl_extend("force", opts, { expr = true })
    )
  end
  api.nvim_create_autocmd("TextChangedI", {
    group = "PRReviewLsp",
    buffer = buffer,
    callback = function() changed(buffer) end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = "PRReviewLsp",
    buffer = buffer,
    once = true,
    callback = function()
      pending[buffer], configured[buffer] = nil, nil
    end,
  })
end

function M.attach(buffer, checkout)
  if vim.bo[buffer].filetype ~= "go" or vim.bo[buffer].buftype ~= "" or not vim.bo[buffer].modifiable then
    return
  end
  local command = vim.fn.stdpath("data") .. "/bin/gopls"
  if vim.fn.executable(command) ~= 1 then
    if not missing then
      missing = true
      vim.notify("Go language support is not installed. Run Review's installer again.", vim.log.levels.WARN)
    end
    return
  end
  local root = vim.fs.root(api.nvim_buf_get_name(buffer), { "go.work", "go.mod" })
  if not root or root ~= checkout and root:sub(1, #checkout + 1) ~= checkout .. "/" then root = checkout end
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.workspace.didChangeWatchedFiles = { dynamicRegistration = false }
  return vim.lsp.start({
    name = "review-gopls",
    cmd = { command },
    root_dir = root,
    capabilities = capabilities,
    on_attach = attached,
    settings = { gopls = { usePlaceholders = true, completeUnimported = true } },
  }, { bufnr = buffer })
end

function M.reset()
  pending = {}
  for _, client in ipairs(vim.lsp.get_clients({ name = "review-gopls" })) do
    client:stop()
  end
end

function M.setup()
  api.nvim_create_augroup("PRReviewLsp", { clear = true })
  vim.opt.completeopt = { "menuone", "noselect", "popup" }
  vim.opt.pumheight = 10
  vim.opt.pumborder = "rounded"
  vim.diagnostic.config({
    virtual_text = false,
    virtual_lines = false,
    underline = false,
    update_in_insert = false,
    severity_sort = true,
    signs = { text = { "E", "W", "I", "H" }, severity = { min = vim.diagnostic.severity.WARN } },
    float = { border = "rounded", source = "if_many" },
  })
  for _, key in ipairs({ "grr", "gri", "grt", "grn", "gra", "grx", "gO" }) do
    pcall(vim.keymap.del, "n", key)
  end
end

return M
