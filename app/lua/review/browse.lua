local M = {}
local api = vim.api

local function views(state)
  local result = {}
  for _, window in ipairs({ state.left, state.right }) do
    if api.nvim_win_is_valid(window) then result[window] = api.nvim_win_call(window, vim.fn.winsaveview) end
  end
  return result
end

function M.close(state)
  local peek = state.peek
  if not peek then return end
  state.peek = nil
  pcall(vim.keymap.del, "n", "q", { buffer = peek.buffer })
  local current = views(state)
  local widths = {}
  for window in pairs(current) do
    widths[window] = api.nvim_win_get_width(window)
  end
  if api.nvim_win_is_valid(peek.window) then api.nvim_win_close(peek.window, true) end
  if state.list and api.nvim_win_is_valid(state.list) then api.nvim_win_set_width(state.list, peek.width) end
  for window, width in pairs(widths) do
    if api.nvim_win_is_valid(window) then api.nvim_win_set_width(window, width) end
  end
  for window, view in pairs(vim.deep_equal(current, peek.resized) and peek.views or current) do
    if api.nvim_win_is_valid(window) then
      api.nvim_win_call(window, function() vim.fn.winrestview(view) end)
    end
  end
  if state.right and api.nvim_win_is_valid(state.right) then api.nvim_set_current_win(state.right) end
end

function M.open(state, file)
  M.close(state)
  local path = state.session.path .. "/" .. file.path
  local stat = assert(vim.uv.fs_lstat(path), "File no longer exists: " .. vim.fn.strtrans(file.path))
  local buffer
  if stat.type == "link" or stat.type == "directory" then
    buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(
      buffer,
      0,
      -1,
      false,
      { stat.type == "link" and vim.uv.fs_readlink(path) or "Submodule" }
    )
    vim.bo[buffer].modifiable = false
    vim.bo[buffer].bufhidden = "wipe"
  else
    local disk = assert(io.open(path, "rb"))
    local sample = disk:read(8192) or ""
    disk:close()
    if sample:find("\0", 1, true) then
      buffer = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(buffer, 0, -1, false, { "Binary file" })
      vim.bo[buffer].modifiable = false
      vim.bo[buffer].bufhidden = "wipe"
    else
      buffer = vim.fn.bufadd(path)
      vim.fn.bufload(buffer)
      local filetype = vim.filetype.match({ filename = path })
      if filetype then vim.bo[buffer].filetype = filetype end
    end
  end
  local peek =
    { buffer = buffer, path = file.path, views = views(state), width = api.nvim_win_get_width(state.list) }
  peek.widths = {}
  for window in pairs(peek.views) do
    peek.widths[window] = api.nvim_win_get_width(window)
  end
  local height = math.max(4, math.min(14, math.floor(api.nvim_win_get_height(state.right) / 3)))
  api.nvim_set_current_win(state.right)
  vim.cmd("belowright split")
  peek.window = api.nvim_get_current_win()
  vim.cmd("diffoff")
  api.nvim_win_set_buf(peek.window, buffer)
  vim.cmd("wincmd J")
  api.nvim_set_current_win(state.list)
  vim.cmd("wincmd H")
  api.nvim_win_set_width(state.list, peek.width)
  api.nvim_win_set_height(peek.window, height)
  for window, width in pairs(peek.widths) do
    api.nvim_win_set_width(window, width)
  end
  api.nvim_set_current_win(peek.window)
  vim.wo.winfixheight = true
  vim.wo.number = true
  vim.wo.foldenable = false
  vim.wo.wrap = false
  vim.wo.cursorline = false
  vim.wo.winhighlight = ""
  vim.wo.winbar = " PEEK: " .. vim.fn.strtrans(file.path):gsub("%%", "%%%%") .. " %m %= q return to diff "
  vim.wo.signcolumn = vim.bo[buffer].filetype == "go" and "auto:1" or "no"
  peek.resized = views(state)
  state.peek = peek
  vim.keymap.set("n", "q", function() M.close(state) end, { buffer = buffer, silent = true })
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(peek.window),
    once = true,
    callback = function()
      if state.peek == peek then M.close(state) end
    end,
  })
  require("review.lsp").attach(buffer, state.session.path)
end

function M.close_finder(state)
  local finder = state.finder
  if not finder then return end
  state.finder = nil
  vim.cmd("stopinsert")
  for _, window in ipairs({ finder.window, finder.results }) do
    if api.nvim_win_is_valid(window) then api.nvim_win_close(window, true) end
  end
  if api.nvim_win_is_valid(finder.origin) then api.nvim_set_current_win(finder.origin) end
end

function M.find(state, files, select)
  M.close_finder(state)
  local width = math.max(12, math.min(90, vim.o.columns - 8))
  local height = math.max(2, math.min(12, vim.o.lines - 9))
  local row, col =
    math.max(0, math.floor((vim.o.lines - height - 5) / 3)), math.floor((vim.o.columns - width) / 2)
  local input, results = api.nvim_create_buf(false, true), api.nvim_create_buf(false, true)
  for _, buffer in ipairs({ input, results }) do
    vim.bo[buffer].bufhidden = "wipe"
  end
  local finder = { origin = api.nvim_get_current_win(), input = input, matches = files, index = 1 }
  finder.window = api.nvim_open_win(input, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = " Find file · all project files ",
  })
  finder.results = api.nvim_open_win(results, false, {
    relative = "editor",
    row = row + 3,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = false,
    footer = " Ctrl-n/p select · Enter open · Esc cancel ",
  })
  state.finder = finder
  for _, window in ipairs({ finder.window, finder.results }) do
    api.nvim_win_call(window, function() vim.cmd("diffoff") end)
    vim.wo[window].winhighlight =
      "Normal:ReviewPanel,FloatBorder:ReviewBorder,FloatTitle:ReviewTitle,FloatFooter:ReviewMuted"
    vim.wo[window].wrap = false
  end
  local namespace = api.nvim_create_namespace("PRReviewFind")
  local function render()
    local query = api.nvim_buf_get_lines(input, 0, 1, false)[1] or ""
    finder.matches = query == "" and files or vim.fn.matchfuzzy(files, query, { key = "path", limit = 100 })
    finder.index = math.max(1, math.min(finder.index, #finder.matches))
    local lines, start = {}, math.max(1, finder.index - height + 1)
    for index = start, math.min(#finder.matches, start + height - 1) do
      local file = finder.matches[index]
      lines[#lines + 1] = " " .. (file.status or "·") .. "  " .. vim.fn.strtrans(file.path)
    end
    if #lines == 0 then lines = { " No files match." } end
    vim.bo[results].modifiable = true
    api.nvim_buf_set_lines(results, 0, -1, false, lines)
    vim.bo[results].modifiable = false
    api.nvim_buf_clear_namespace(results, namespace, 0, -1)
    if #finder.matches > 0 then
      api.nvim_buf_set_extmark(
        results,
        namespace,
        finder.index - start,
        0,
        { line_hl_group = "ReviewSelection" }
      )
    end
    vim.bo[input].modified = false
  end
  api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, { buffer = input, callback = render })
  for _, key in ipairs({ "<Esc>", "<C-c>" }) do
    vim.keymap.set({ "i", "n" }, key, function() M.close_finder(state) end, { buffer = input, silent = true })
  end
  for key, offset in pairs({ ["<C-n>"] = 1, ["<Down>"] = 1, ["<C-p>"] = -1, ["<Up>"] = -1 }) do
    vim.keymap.set({ "i", "n" }, key, function()
      finder.index = finder.index + offset
      render()
    end, { buffer = input, silent = true })
  end
  vim.keymap.set({ "i", "n" }, "<CR>", function()
    render()
    local file = finder.matches[finder.index]
    if not file then return end
    M.close_finder(state)
    select(file)
  end, { buffer = input, silent = true })
  render()
  vim.cmd("startinsert")
end

return M
