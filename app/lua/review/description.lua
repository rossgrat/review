local M = {}
local api = vim.api

function M.valid(editor)
  return editor
    and api.nvim_win_is_valid(editor.window)
    and api.nvim_buf_is_valid(editor.buffer)
    and api.nvim_win_get_buf(editor.window) == editor.buffer
end

function M.lock(editor, locked)
  editor.saving = locked
  if M.valid(editor) then vim.bo[editor.buffer].modifiable = not locked end
end

function M.close(editor)
  if not M.valid(editor) or editor.saving then return end
  vim.cmd("stopinsert")
  api.nvim_win_close(editor.window, true)
  if api.nvim_win_is_valid(editor.origin) then api.nvim_set_current_win(editor.origin) end
end

function M.open(repo, pr, submit)
  local buffer = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buffer, "pr-review://description/" .. repo.slug .. "/" .. pr.number)
  vim.bo[buffer].buftype = "acwrite"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(pr.body, "\n", { plain = true }))
  vim.bo[buffer].modified = false
  local width, height =
    math.max(12, math.min(96, vim.o.columns - 8)), math.max(3, math.min(26, vim.o.lines - 8))
  local editor = { buffer = buffer, origin = api.nvim_get_current_win() }
  editor.window = api.nvim_open_win(buffer, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. repo.slug .. " #" .. pr.number .. " · PR description ",
    footer = " :w / Ctrl-s submit · q cancel ",
  })
  vim.cmd("diffoff")
  vim.cmd("noautocmd setlocal filetype=markdown")
  vim.bo.syntax = "markdown"
  vim.wo.wrap, vim.wo.linebreak, vim.wo.foldenable = true, true, false
  vim.wo.winhighlight =
    "Normal:ReviewPanel,FloatBorder:ReviewBorder,FloatTitle:ReviewTitle,FloatFooter:ReviewMuted"
  local function publish()
    if not editor.saving then
      submit(editor, table.concat(api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"))
    end
  end
  api.nvim_create_autocmd("BufWriteCmd", { buffer = buffer, callback = publish })
  vim.keymap.set({ "n", "i" }, "<C-s>", publish, { buffer = buffer, silent = true })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() M.close(editor) end, { buffer = buffer, silent = true })
  end
  return editor
end

return M
