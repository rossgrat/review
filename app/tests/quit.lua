local ui = require("review.ui")
local started = false
vim.schedule(function() started = true end)
assert(vim.wait(5000, function() return started and not ui.state.busy end, 10))
vim.cmd("vsplit")
vim.cmd("vsplit")
local scenario = arg[1]
if scenario ~= "clean" then
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buffer, vim.fn.tempname())
  vim.api.nvim_win_set_buf(0, buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "unsaved edit" })
end
vim.api.nvim_feedkeys(":q" .. (scenario == "force" and "!" or "") .. "\r", "xt", false)
if scenario == "dirty" then
  assert(#vim.api.nvim_list_wins() == 3, "Quit must not close a pane when edits are unsaved")
  assert(vim.bo.modified, "Quit must preserve the unsaved buffer")
  vim.cmd("qall!")
end
vim.cmd("cquit 1")
