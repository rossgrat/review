local ui = require("review.ui")
local started = false
vim.schedule(function() started = true end)
assert(vim.wait(5000, function() return started and not ui.state.busy end, 10))
local list = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local left = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local right = vim.api.nvim_get_current_win()
local scenario, peeking = arg[1]:gsub("^peek%-", ""), arg[1]:match("^peek%-")
if peeking then
  local path = vim.fn.tempname()
  vim.fn.writefile({ "Saved reference" }, path)
  ui.state.list, ui.state.left, ui.state.right = list, left, right
  ui.state.session = { path = vim.fs.dirname(path) }
  require("review.browse").open(ui.state, { path = vim.fs.basename(path) })
  vim.api.nvim_create_autocmd("VimLeavePre", { once = true, callback = function() vim.fn.delete(path) end })
end
if scenario ~= "clean" then
  local buffer = peeking and vim.api.nvim_get_current_buf() or vim.api.nvim_create_buf(true, false)
  if not peeking then
    vim.api.nvim_buf_set_name(buffer, vim.fn.tempname())
    vim.api.nvim_win_set_buf(0, buffer)
  end
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "unsaved edit" })
end
vim.api.nvim_feedkeys(":q" .. (scenario == "force" and "!" or "") .. "\r", "xt", false)
if scenario == "dirty" then
  assert(
    #vim.api.nvim_list_wins() == (peeking and 4 or 3),
    "Quit must not close a pane when edits are unsaved"
  )
  assert(vim.bo.modified, "Quit must preserve the unsaved buffer")
  vim.cmd("qall!")
end
vim.cmd("cquit 1")
