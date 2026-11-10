local M = {}
local api = vim.api
local window, origin

function M.close(restore)
  local previous = origin
  if window and api.nvim_win_is_valid(window) then api.nvim_win_close(window, true) end
  window, origin = nil, nil
  if restore ~= false and previous and api.nvim_win_is_valid(previous) then
    api.nvim_set_current_win(previous)
  end
end

function M.toggle()
  if window and api.nvim_win_is_valid(window) then
    M.close()
    return
  end
  local lines = vim.split(
    [[Space shortcuts work in Normal mode. Press Esc to leave Insert mode.

REVIEW
  Space i               Show or hide these instructions
  Space f               Focus the changed files
  Space n               Mark this file viewed and open the next unviewed file
  Space p               Show the current repository's open PRs
  Space r               Refresh local changes in the open PR
  Space c c             Commit all saved worktree changes and push (asks first)
  Space q               Quit Review and protect unsaved edits

FILES AND LISTS
  j / k, Down / Up      Move through files or list entries
  Enter                 Open the selected repository, PR, file, or folder
  Tab (file tree)       Open a file or toggle a folder
  h / Left (file tree)  Collapse a folder or select its parent
  l / Right (file tree) Expand a folder, enter it, or open a file
  r                     Reload the current list or local file changes
  q                     Go back; quit from the repository list

EDIT AND SEARCH
  i                     Enter Insert mode to edit code
  Esc                   Return to Normal mode
  :w                    Save the current file
  :wall                 Save all open files before commit and push
  u / Ctrl-r            Undo / redo an edit
  /                     Search the current file or list
  n / N                 Next / previous search match
  :noh                  Clear search highlighting
  gg / G                Move to the first / last line
  Ctrl-d / Ctrl-u       Scroll down / up half a page

DIFF AND PANES
  ]c / [c               Next / previous changed block
  zo / zc               Open / close a folded code section
  zR                    Expand all folded code sections
  Ctrl-w h/j/k/l        Move between panes
  Ctrl-w w              Move to the next pane

COMMANDS
  :ReviewHelp           Show or hide these instructions
  :ReviewNext           Mark viewed and open the next unviewed file
  :ReviewCommitPush     Commit and push saved worktree changes (asks first)
  :ReviewQuit           Quit the whole application
  :q / :qall            Quit Review and protect unsaved edits
  :q!                   Quit Review and discard all unsaved edits

Save the current file before marking it viewed.
Viewed marks last for this Review session.
Completed folders collapse. Saving a viewed file makes it unviewed again.]],
    "\n",
    { plain = true }
  )
  local buffer = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buffer, "pr-review://instructions/" .. buffer)
  vim.bo[buffer].bufhidden = "wipe"
  api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  local width = math.min(86, math.max(1, vim.o.columns - 8))
  local height = math.min(#lines, math.max(1, vim.o.lines - 6))
  origin = api.nvim_get_current_win()
  window = api.nvim_open_win(buffer, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Review instructions ",
    title_pos = "center",
    footer = " Esc / q / Enter close · j/k scroll ",
    footer_pos = "center",
  })
  vim.cmd("diffoff")
  vim.wo.wrap = true
  vim.wo.cursorline = false
  vim.wo.winhighlight =
    "Normal:ReviewPanel,FloatBorder:ReviewBorder,FloatTitle:ReviewTitle,FloatFooter:ReviewMuted"
  local namespace = api.nvim_create_namespace("PRReviewHelp")
  for line, text in ipairs(lines) do
    if text:match("^[A-Z ]+$") then
      api.nvim_buf_set_extmark(buffer, namespace, line - 1, 0, { end_col = #text, hl_group = "ReviewAccent" })
    end
  end
  for _, key in ipairs({ "<Esc>", "q", "<CR>" }) do
    vim.keymap.set("n", key, M.close, { buffer = buffer, silent = true })
  end
  local current = window
  api.nvim_create_autocmd("WinLeave", {
    buffer = buffer,
    once = true,
    callback = function()
      vim.schedule(function()
        if window == current and api.nvim_get_current_win() ~= current then M.close(false) end
      end)
    end,
  })
end

return M
