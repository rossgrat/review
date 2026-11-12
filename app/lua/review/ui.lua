local core = require("review.core")
local tree = require("review.tree")
local help = require("review.help")
local browse = require("review.browse")
local description = require("review.description")
local M = {}
local api = vim.api
local state = { pr_cache = {}, reviews = {}, review_history = {}, generated_expanded = {} }
local decorations = api.nvim_create_namespace("PRReviewPresentation")
local selection = api.nvim_create_namespace("PRReviewSelection")

local function highlight(buffer, line, group, start_col, end_col)
  api.nvim_buf_set_extmark(buffer, decorations, line - 1, start_col or 0, {
    end_col = end_col or #api.nvim_buf_get_lines(buffer, line - 1, line, false)[1],
    hl_group = group,
  })
end

local function map(buffer, key, callback)
  vim.keymap.set("n", key, callback, { buffer = buffer, silent = true })
end

local function write(buffer, lines)
  vim.bo[buffer].modifiable = true
  api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].modified = false
end

local function scratch(name, text)
  local buffer = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buffer, "pr-review://" .. name .. "/" .. buffer)
  vim.bo[buffer].bufhidden = "wipe"
  write(buffer, vim.split(text or "", "\n", { plain = true }))
  return buffer
end

local function task(label, fn, dialog, on_success)
  if state.busy then return end
  help.close()
  browse.close_finder(state)
  state.busy = true
  local loading
  if dialog then
    local width = math.min(56, vim.o.columns - 4)
    loading = api.nvim_open_win(scratch("loading", "\n  " .. label .. "\n"), false, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - 5) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = 3,
      style = "minimal",
      border = "rounded",
      focusable = false,
    })
    vim.wo[loading].winhighlight = "Normal:ReviewPanel,FloatBorder:ReviewBorder"
    state.loading = loading
    vim.cmd("redraw")
  end
  vim.schedule(function()
    coroutine.wrap(function()
      local ok, result = pcall(fn)
      if loading and api.nvim_win_is_valid(loading) then api.nvim_win_close(loading, true) end
      state.loading = nil
      state.busy = false
      if not ok then
        vim.notify(tostring(result), vim.log.levels.ERROR)
      else
        vim.cmd("echo ''")
        if on_success then on_success(result) end
      end
    end)()
  end)
end

local function saved(message)
  for _, buffer in ipairs(api.nvim_list_bufs()) do
    if vim.bo[buffer].modified then
      vim.notify(message or "Save your edits before changing PRs.", vim.log.levels.WARN)
      return false
    end
  end
  return true
end

local function page(title, context, summary, items, format, select, back, refresh)
  browse.close(state)
  state.session, state.list, state.selected = nil, nil, nil
  api.nvim_create_augroup("PRReviewRefresh", { clear = true })
  vim.cmd("silent only")
  vim.cmd("diffoff!")
  local margin = "   "
  local lines = {
    "",
    margin .. "PR REVIEW",
    "",
    margin .. title,
    margin .. context,
    margin .. summary,
    "",
    margin .. string.rep("─", math.min(100, vim.o.columns - 8)),
    "",
  }
  local rows, records = {}, {}
  for _, item in ipairs(items) do
    local record = { item = item, first = #lines + 1 }
    for _, text in ipairs(format(item)) do
      lines[#lines + 1] = margin .. vim.fn.strtrans(text)
      rows[#lines] = record
    end
    record.last = #lines
    records[#records + 1] = record
    lines[#lines + 1] = ""
  end
  if #items == 0 then lines[#lines + 1] = margin .. "No results." end
  local buffer = scratch("picker", table.concat(lines, "\n"))
  api.nvim_win_set_buf(0, buffer)
  vim.wo.number = false
  vim.wo.cursorline = false
  vim.wo.wrap = false
  vim.wo.winfixwidth = false
  vim.wo.winhighlight = "Normal:ReviewPanel,EndOfBuffer:ReviewPanel"
  vim.wo.winbar = ""
  vim.wo.statusline = " PR Review %= Space-i help  Enter open  / search  r refresh  q back "
  state.picker_rows = rows
  highlight(buffer, 2, "ReviewAccent")
  highlight(buffer, 4, "ReviewTitle")
  for _, line in ipairs({ 5, 6 }) do
    highlight(buffer, line, "ReviewMuted")
  end
  highlight(buffer, 8, "ReviewBorder")
  for _, record in ipairs(records) do
    for line = record.first, record.last do
      highlight(buffer, line, line == record.first and "ReviewTitle" or "ReviewMuted")
      local start_col, end_col = lines[line]:find("DRAFT", 1, true)
      if start_col then highlight(buffer, line, "ReviewChanged", start_col - 1, end_col) end
      start_col, end_col = lines[line]:find("OPEN", 1, true)
      if start_col then highlight(buffer, line, "ReviewAdded", start_col - 1, end_col) end
      local target = lines[line]:find("→ ", 1, true)
      if target then highlight(buffer, line, "ReviewAdded", target + #"→ " - 1, #lines[line]) end
    end
  end
  local function select_record()
    api.nvim_buf_clear_namespace(buffer, selection, 0, -1)
    local record = rows[api.nvim_win_get_cursor(0)[1]]
    if record then
      for line = record.first, record.last do
        api.nvim_buf_set_extmark(buffer, selection, line - 1, 0, { line_hl_group = "ReviewSelection" })
      end
    end
  end
  local function move(direction)
    local current = api.nvim_win_get_cursor(0)[1]
    local record = rows[current]
    local threshold = record and (direction > 0 and record.last or record.first) or current
    for step = 1, #records do
      local candidate = records[direction > 0 and step or #records - step + 1]
      if direction > 0 and candidate.first > threshold or direction < 0 and candidate.first < threshold then
        api.nvim_win_set_cursor(0, { candidate.first, #margin })
        return
      end
    end
  end
  api.nvim_create_autocmd("CursorMoved", { buffer = buffer, callback = select_record })
  api.nvim_win_set_cursor(0, { records[1] and records[1].first or #lines, #margin })
  select_record()
  for _, key in ipairs({ "j", "<Down>" }) do
    map(buffer, key, function() move(1) end)
  end
  for _, key in ipairs({ "k", "<Up>" }) do
    map(buffer, key, function() move(-1) end)
  end
  map(buffer, "<CR>", function()
    local record = rows[api.nvim_win_get_cursor(0)[1]]
    if record then select(record.item) end
  end)
  map(buffer, "q", back)
  map(buffer, "r", refresh)
end

function M.repositories()
  if not saved() then return end
  task("Finding repositories...", function()
    local repos = core.discover(state.directory)
    page(
      "Repositories",
      vim.fn.fnamemodify(state.directory, ":~"),
      string.format("%d %s", #repos, #repos == 1 and "repository" or "repositories"),
      repos,
      function(repo)
        local path = vim.fs.relpath(vim.uv.fs_realpath(state.directory), repo.path) or repo.path
        return { repo.name, path .. "   ·   " .. repo.branch }
      end,
      M.pull_requests,
      function() vim.cmd("confirm qall") end,
      M.repositories
    )
  end, true)
end

function M.pull_requests(repo, force)
  if not saved() then return end
  local key = repo.common or repo.path
  local cached = state.pr_cache[key]
  if force or cached and vim.uv.hrtime() - cached.loaded > 30e9 then cached = nil end
  task("Reading open PRs from GitHub...", function()
    state.repo = repo
    if not cached then
      cached = { prs = core.pull_requests(repo), slug = repo.slug, loaded = vim.uv.hrtime() }
      state.pr_cache[key] = cached
    end
    repo.slug = cached.slug
    local prs = cached.prs
    local drafts = 0
    for _, pr in ipairs(prs) do
      if pr.draft then drafts = drafts + 1 end
    end
    page(
      "Open pull requests",
      repo.slug,
      string.format("%d open   ·   %d %s", #prs, drafts, drafts == 1 and "draft" or "drafts"),
      prs,
      function(pr)
        return {
          string.format("#%d  %s", pr.number, pr.title),
          (pr.draft and "DRAFT" or "OPEN")
            .. "   ·   @"
            .. (pr.user and pr.user.login or "unknown")
            .. (pr.updated_at and "   ·   updated " .. pr.updated_at:sub(1, 10) or ""),
          pr.head.ref .. " → " .. pr.base.ref,
        }
      end,
      M.open,
      M.repositories,
      function() M.pull_requests(repo, true) end
    )
  end, not cached)
end

local function fold_generated(file)
  if not file.generated then return end
  for _, window in ipairs({ state.left, state.right }) do
    api.nvim_win_call(window, function()
      vim.wo.foldmethod = "manual"
      vim.wo.foldenable = true
      vim.wo.foldminlines = 0
      vim.wo.foldtext = "'Generated file · Space g to expand/collapse both panes'"
      vim.cmd("normal! zE")
      vim.cmd("1,$fold")
      vim.wo.foldlevel = state.generated_open[file.path] and 99 or 0
    end)
  end
end

local function show_file(file, keep_peek)
  if not keep_peek then browse.close(state) end
  local original = core.original(state.session, file)
  local absolute = state.session.path .. "/" .. file.path
  local stat = vim.uv.fs_lstat(absolute)
  local symlink = stat and stat.type == "link"
  local disk = not symlink and io.open(absolute, "rb")
  local sample = disk and disk:read(8192) or ""
  if disk then disk:close() end
  local binary = original:find("\0", 1, true) or sample:find("\0", 1, true)
  local left = scratch("base", binary and "Binary file" or original:gsub("\n$", ""))
  local right
  if symlink then
    right = scratch("local", vim.uv.fs_readlink(absolute))
  elseif binary or file.status == "D" or vim.fn.isdirectory(absolute) == 1 then
    right = scratch("local", binary and "Binary file" or file.status == "D" and "" or "Submodule")
  else
    right = vim.fn.bufadd(absolute)
    vim.fn.bufload(right)
  end
  vim.cmd("diffoff!")
  api.nvim_win_set_buf(state.left, left)
  api.nvim_win_set_buf(state.right, right)
  local filetype = vim.filetype.match({ filename = absolute })
  if filetype then
    vim.bo[left].filetype = filetype
    vim.bo[right].filetype = filetype
  end
  for _, window in ipairs({ state.left, state.right }) do
    api.nvim_win_call(window, function()
      vim.wo.foldtext = "foldtext()"
      vim.wo.foldminlines = 1
      vim.cmd("diffthis")
    end)
  end
  vim.wo[state.left].winhighlight =
    "DiffAdd:ReviewDiffRemove,DiffChange:ReviewDiffRemove,DiffText:ReviewDiffOldText,DiffTextAdd:ReviewDiffOldText,DiffDelete:ReviewDiffFiller"
  vim.wo[state.right].winhighlight =
    "DiffAdd:ReviewDiffAdd,DiffChange:ReviewDiffAdd,DiffText:ReviewDiffNewText,DiffTextAdd:ReviewDiffNewText,DiffDelete:ReviewDiffFiller"
  fold_generated(file)
  vim.wo[state.left].winbar = " Base: " .. state.session.pr.base.ref:gsub("%%", "%%%%") .. " (merge base)"
  vim.wo[state.right].winbar = " Local: " .. vim.fn.strtrans(file.path):gsub("%%", "%%%%") .. " %m"
  state.selected = file.path
  for line, row in pairs(state.tree_rows) do
    if row.file and row.file.path == file.path then
      api.nvim_win_set_cursor(state.list, { line, 0 })
      break
    end
  end
  map(right, "<leader>f", function() api.nvim_set_current_win(state.list) end)
  api.nvim_set_current_win(state.right)
  vim.wo.signcolumn = filetype == "go" and vim.bo[right].buftype == "" and "auto:1" or "no"
  require("review.lsp").attach(right, state.session.path)
end

local function collapsed() return state.all_files and state.project_collapsed or state.collapsed end

local function project_files()
  if not state.project then
    state.project = core.project_files(state.session, state.files)
    for _, row in ipairs(tree.rows(state.project, {})) do
      if row.directory and state.project_collapsed[row.path] == nil then
        state.project_collapsed[row.path] = true
      end
    end
  end
  return state.project
end

local function expand_parent(path)
  local parent = path and vim.fs.dirname(path)
  while parent and parent ~= "." do
    collapsed()[parent .. "/"] = false
    parent = vim.fs.dirname(parent)
  end
end

local function render_files(focus)
  local current = state.tree_rows and state.tree_rows[api.nvim_win_get_cursor(state.list)[1]]
  focus = focus or current and current.path or state.selected
  local added, modified, deleted, viewed = 0, 0, 0, 0
  for _, file in ipairs(state.files) do
    if state.viewed[file.path] then viewed = viewed + 1 end
    if file.status == "A" or file.status == "?" then
      added = added + 1
    elseif file.status == "D" then
      deleted = deleted + 1
    else
      modified = modified + 1
    end
  end
  local lines = {
    "",
    state.all_files and " Changes   [All files]" or " [Changes]   All files",
    " #" .. state.session.pr.number .. " · " .. vim.fs.basename(state.repo.path),
    state.all_files and string.format(" %d files · %d changed", #state.project, #state.files)
      or string.format(
        " %d %s   +%d  ~%d  -%d",
        #state.files,
        #state.files == 1 and "file" or "files",
        added,
        modified,
        deleted
      ),
    string.format(" %d / %d viewed", viewed, #state.files),
    "",
  }
  state.tree_rows = {}
  local cursor = 7
  for _, row in ipairs(tree.rows(state.all_files and state.project or state.files, collapsed(), state.viewed)) do
    lines[#lines + 1] = row.text
    state.tree_rows[#lines] = row
    if row.path == focus then cursor = #lines end
  end
  if #state.files == 0 then lines[#lines + 1] = "No changes." end
  write(state.file_buffer, lines)
  api.nvim_buf_clear_namespace(state.file_buffer, decorations, 0, -1)
  highlight(state.file_buffer, 2, "ReviewTitle")
  highlight(state.file_buffer, 3, "ReviewMuted")
  highlight(state.file_buffer, 4, "ReviewMuted")
  highlight(state.file_buffer, 5, "ReviewMuted")
  for line, row in pairs(state.tree_rows) do
    local complete = row.changed > 0 and row.viewed == row.changed
    highlight(
      state.file_buffer,
      line,
      complete and "ReviewMuted"
        or row.directory and "ReviewAccent"
        or row.file.status and "ReviewFile"
        or "ReviewMuted"
    )
    highlight(state.file_buffer, line, "ReviewBorder", 0, row.guides)
    local status = row.directory
        and (row.changed > 0 and string.format("%d/%d", row.viewed, row.changed) or "")
      or (row.file.status or ""):sub(1, 1)
    if complete then status = "✓ " .. status end
    local group = complete and "ReviewAdded"
      or row.directory and "ReviewMuted"
      or status == "D" and "ReviewDeleted"
      or (status == "A" or status == "?") and "ReviewAdded"
      or "ReviewChanged"
    if row.generated == row.count then status = "gen " .. status end
    api.nvim_buf_set_extmark(state.file_buffer, decorations, line - 1, 0, {
      virt_text = { { " " .. status .. " ", group } },
      virt_text_pos = "right_align",
    })
  end
  api.nvim_win_set_cursor(state.list, { cursor, 0 })
end

local function file_stamp(file)
  local stat = vim.uv.fs_lstat(state.session.path .. "/" .. file.path)
  return table.concat({
    state.session.base,
    stat and stat.mode or 0,
    stat and stat.size or 0,
    stat and stat.mtime.sec or 0,
    stat and stat.mtime.nsec or 0,
  }, ":")
end

local function update_viewed()
  local present = {}
  for _, file in ipairs(state.files) do
    present[file.path] = true
    if state.viewed[file.path] and state.viewed[file.path] ~= file_stamp(file) then
      state.viewed[file.path] = nil
    end
  end
  for path in pairs(state.viewed) do
    if not present[path] then state.viewed[path] = nil end
  end
  for _, row in ipairs(tree.rows(state.files, {}, state.viewed)) do
    if row.directory then
      if row.viewed == row.count then
        state.collapsed[row.path], state.auto_collapsed[row.path] = true, true
      elseif state.auto_collapsed[row.path] then
        state.collapsed[row.path], state.auto_collapsed[row.path] = false, nil
      end
      if row.generated == row.count and not state.generated_dirs[row.path] then
        state.collapsed[row.path], state.generated_dirs[row.path] = true, true
      end
    end
  end
end

local function files()
  state.files = core.changes(state.session)
  state.project = nil
  if state.all_files then project_files() end
  update_viewed()
  render_files()
end

local function open_review_file(file)
  expand_parent(file.path)
  render_files(file.path)
  show_file(file)
end

function M.next_file()
  if not state.session or state.busy then return end
  browse.close(state)
  if vim.bo[api.nvim_win_get_buf(state.right)].modified then
    vim.notify("Save the current file before marking it viewed.", vim.log.levels.WARN)
    return
  end
  task("Next file", function()
    local ordered, current = {}, 0
    for _, row in ipairs(tree.rows(state.files, {}, state.viewed)) do
      if row.file then
        ordered[#ordered + 1] = row.file
        if row.file.path == state.selected then current = #ordered end
      end
    end
    local step
    if current > 0 then
      step = {
        path = state.selected,
        viewed = state.viewed[state.selected],
        cursor = api.nvim_win_get_cursor(state.right),
      }
      state.viewed[state.selected] = file_stamp(ordered[current])
    end
    update_viewed()
    local next_file
    for offset = 1, #ordered do
      local file = ordered[(current + offset - 1) % #ordered + 1]
      if not state.viewed[file.path] then
        next_file = file
        break
      end
    end
    if step and (step.viewed ~= state.viewed[step.path] or next_file and next_file.path ~= step.path) then
      state.history[#state.history + 1] = step
    end
    if next_file then
      open_review_file(next_file)
      return
    end
    render_files()
    vim.schedule(function() vim.notify("All files viewed.") end)
  end)
end

function M.undo_next()
  if not state.session or state.busy then return end
  browse.close(state)
  task("Undo next file", function()
    local step = table.remove(state.history)
    if not step then
      vim.schedule(function() vim.notify("No review step to undo.") end)
      return
    end
    for _, file in ipairs(state.files) do
      if file.path == step.path then
        state.viewed[file.path] = step.viewed
        update_viewed()
        open_review_file(file)
        local buffer = api.nvim_win_get_buf(state.right)
        local row = math.min(step.cursor[1], api.nvim_buf_line_count(buffer))
        local line = api.nvim_buf_get_lines(buffer, row - 1, row, false)[1]
        api.nvim_win_set_cursor(state.right, { row, math.min(step.cursor[2], #line) })
        return
      end
    end
    vim.schedule(function() vim.notify("The previous file is no longer in the diff.") end)
  end)
end

function M.toggle_generated()
  if not state.session or state.busy then return end
  for _, file in ipairs(state.files) do
    if file.path == state.selected and file.generated then
      task("Toggle generated diff", function()
        state.generated_open[file.path] = not state.generated_open[file.path]
        fold_generated(file)
      end)
      return
    end
  end
end

function M.commit_push()
  if not state.session or state.busy or not saved("Save your edits before committing and pushing.") then
    return
  end
  local session = state.session
  task(
    "Preparing commit and push...",
    function() return core.commit_plan(session, core.pull_request(state.repo, session.pr.number)) end,
    true,
    function(plan)
      local function confirm(message)
        if message == nil and #plan.files > 0 then return end
        if message and vim.trim(message) == "" then return end
        local prompt = string.format("Commit %d changed files and push to %s?", #plan.files, plan.destination)
        if #plan.files == 0 then
          prompt = "No changes to commit. Push existing commits to " .. plan.destination .. "?"
        end
        if message then prompt = prompt .. "\nMessage: " .. message end
        vim.ui.select({ "Commit and push", "Cancel" }, { prompt = prompt }, function(choice)
          if
            choice ~= "Commit and push"
            or state.session ~= session
            or not saved("Save your edits before committing and pushing.")
          then
            return
          end
          task(
            "Committing and pushing...",
            function()
              local commit = core.commit_and_push(session, plan, message)
              session.ahead, session.behind, session.pr.head.sha = 0, 0, commit
              for _, win in ipairs({ state.list, state.left, state.right }) do
                vim.wo[win].statusline = state.statusline
              end
              state.pr_cache[state.repo.common or state.repo.path] = nil
              return commit
            end,
            true,
            function(commit)
              M.refresh(false)
              vim.notify("Pushed " .. commit:sub(1, 8) .. " to " .. plan.destination)
            end
          )
        end)
      end
      if #plan.files == 0 then
        confirm(nil)
      else
        vim.ui.input({ prompt = "Commit message: " }, confirm)
      end
    end
  )
end

function M.ready()
  if not state.session or state.busy then return end
  if description.valid(state.description) then
    api.nvim_set_current_win(state.description.window)
    return
  end
  local session, repo = state.session, state.repo
  task(
    "Loading PR description...",
    function() return core.pull_request(repo, session.pr.number) end,
    true,
    function(pr)
      if state.session ~= session then return end
      state.description = description.open(repo, pr, function(editor, body)
        if state.busy or state.session ~= session then return end
        description.lock(editor, true)
        vim.ui.select({ "Update and mark ready", "Cancel" }, {
          prompt = string.format(
            "Update the description and mark %s #%d ready?\n%s",
            repo.slug,
            pr.number,
            pr.title
          ),
        }, function(choice)
          if choice ~= "Update and mark ready" or state.session ~= session then
            description.lock(editor, false)
            return
          end
          task(
            "Updating PR description and readiness...",
            function()
              local ok, result = pcall(core.publish_description, repo, pr, body)
              description.lock(editor, false)
              if not ok then error(result, 0) end
              return result
            end,
            true,
            function(published)
              session.pr.body, session.pr.draft, session.pr.updated_at =
                published.body, published.draft, published.updated_at
              state.pr_cache[repo.common or repo.path] = nil
              description.close(editor)
              state.description = nil
              vim.notify(string.format("Updated %s #%d. The PR is ready for review.", repo.slug, pr.number))
            end
          )
        end)
      end)
    end
  )
end

function M.toggle_files()
  if not state.session or state.busy then return end
  task("Loading project files...", function()
    state.all_files = not state.all_files
    if state.all_files then project_files() end
    local focus = state.peek and state.peek.path or state.selected
    expand_parent(focus)
    render_files(focus)
  end)
end

local function open_path(file)
  task("Opening " .. file.path, function()
    if file.status then
      open_review_file(file)
    else
      browse.open(state, file)
    end
  end)
end

function M.find_file()
  if not state.session or state.busy then return end
  task(
    "Loading project files...",
    project_files,
    false,
    function(files) browse.find(state, files, open_path) end
  )
end

local function tree_action(action)
  local row = state.tree_rows[api.nvim_win_get_cursor(state.list)[1]]
  if not row then return end
  if action == "parent" then
    if row.directory and not collapsed()[row.path] then
      collapsed()[row.path] = true
      render_files(row.path)
    elseif row.parent then
      render_files(row.parent)
    end
  elseif row.directory then
    if action == "expand" and not collapsed()[row.path] then
      api.nvim_win_set_cursor(state.list, { api.nvim_win_get_cursor(state.list)[1] + 1, 0 })
    else
      if action == "expand" then
        collapsed()[row.path] = false
      else
        collapsed()[row.path] = not collapsed()[row.path]
      end
      render_files(row.path)
    end
  else
    open_path(row.file)
  end
end

function M.refresh(remote)
  if not state.session then return end
  if remote ~= false then
    M.open(state.session.pr, true)
    return
  end
  task("Refreshing local changes...", function()
    local views = {}
    for _, window in ipairs({ state.left, state.right }) do
      views[window] = api.nvim_win_call(window, vim.fn.winsaveview)
    end
    files()
    local selected
    for _, file in ipairs(state.files) do
      if file.path == state.selected then selected = file end
    end
    if selected then
      local current = api.nvim_get_current_win()
      show_file(selected, true)
      for window, view in pairs(views) do
        api.nvim_win_call(window, function() vim.fn.winrestview(view) end)
      end
      api.nvim_set_current_win(current)
    else
      vim.cmd("diffoff!")
      api.nvim_win_set_buf(state.left, scratch("base"))
      api.nvim_win_set_buf(state.right, scratch("local"))
      state.selected = nil
    end
  end)
end

local function review(session, position)
  browse.close(state)
  state.session = session
  state.selected, state.tree_rows, state.collapsed = nil, nil, {}
  state.all_files, state.project, state.project_collapsed = false, nil, {}
  local key = (state.repo.common or state.repo.path) .. "/" .. session.pr.number
  state.reviews[key] = state.reviews[key] or {}
  state.viewed, state.auto_collapsed = state.reviews[key], {}
  state.generated_expanded[key] = state.generated_expanded[key] or {}
  state.generated_open, state.generated_dirs = state.generated_expanded[key], {}
  if position then
    state.collapsed, state.auto_collapsed = position.collapsed, position.auto_collapsed
    state.all_files, state.project_collapsed = position.all_files, position.project_collapsed
  end
  local history = state.review_history[key]
  if not history or history.base ~= session.base then
    history = { base = session.base, steps = {} }
    state.review_history[key] = history
  end
  state.history = history.steps
  vim.cmd("silent only")
  state.list = api.nvim_get_current_win()
  state.file_buffer = scratch("files")
  api.nvim_win_set_buf(state.list, state.file_buffer)
  vim.cmd("vsplit")
  state.left = api.nvim_get_current_win()
  vim.cmd("vsplit")
  state.right = api.nvim_get_current_win()
  api.nvim_win_set_buf(state.left, scratch("base"))
  api.nvim_win_set_buf(state.right, scratch("local"))
  api.nvim_win_set_width(state.list, math.max(28, math.min(38, math.floor(vim.o.columns * 0.27))))
  vim.wo[state.list].winfixwidth = true
  vim.wo[state.list].winbar = " FILES   Space a: toggle"
  vim.wo[state.list].cursorline = true
  vim.wo[state.list].winhighlight = "Normal:ReviewPanel,EndOfBuffer:ReviewPanel,CursorLine:ReviewSelection"
  for _, win in ipairs({ state.left, state.right }) do
    vim.wo[win].number = true
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].winhighlight = ""
  end
  local status = string.format(
    " %s #%d  %%<%s → %s",
    state.repo.slug,
    session.pr.number,
    session.pr.head.ref,
    session.pr.base.ref
  )
  vim.o.statusline = status:gsub("%%", "%%%%"):gsub("%%%%<", "%%<")
    .. " %= Space: i help  b back  n next  cc commit/push  q quit "
  state.statusline = vim.o.statusline
  if session.behind > 0 or session.ahead > 0 then
    vim.o.statusline = vim.o.statusline
      .. string.format("  [local: %d ahead, %d behind GitHub]", session.ahead, session.behind)
  end
  for _, win in ipairs({ state.list, state.left, state.right }) do
    vim.wo[win].statusline = vim.o.statusline
  end
  map(state.file_buffer, "<CR>", function() tree_action("open") end)
  map(state.file_buffer, "<Tab>", function() tree_action("open") end)
  for _, key in ipairs({ "h", "<Left>" }) do
    map(state.file_buffer, key, function() tree_action("parent") end)
  end
  for _, key in ipairs({ "l", "<Right>" }) do
    map(state.file_buffer, key, function() tree_action("expand") end)
  end
  map(state.file_buffer, "q", function() M.pull_requests(state.repo) end)
  map(state.file_buffer, "r", M.refresh)
  files()
  local first
  for _, row in ipairs(tree.rows(state.files, {}, state.viewed)) do
    if row.file and position and row.path == position.path then
      first = row.file
      break
    elseif row.file and not (position and position.path) and not state.viewed[row.path] and not first then
      first = row.file
    end
  end
  local missing_selection = position and position.path and not first
  if not missing_selection and (first or state.files[1]) then show_file(first or state.files[1]) end
  if position then
    if position.list_path then
      for line, row in pairs(state.tree_rows) do
        if row.path == position.list_path then
          api.nvim_win_set_cursor(state.list, { line, 0 })
          break
        end
      end
    end
    if state.selected == position.path then
      local buffer = api.nvim_win_get_buf(state.right)
      local row = math.min(position.cursor[1], api.nvim_buf_line_count(buffer))
      local line = api.nvim_buf_get_lines(buffer, row - 1, row, false)[1]
      api.nvim_win_set_cursor(state.right, { row, math.min(position.cursor[2], #line) })
    end
    api.nvim_set_current_win(state[position.focus])
  end
  local group = api.nvim_create_augroup("PRReviewRefresh", { clear = true })
  api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function()
      if state.session == session and api.nvim_win_is_valid(state.list) then M.refresh(false) end
    end,
  })
end

local function reload_buffers(path)
  local prefix = vim.uv.fs_realpath(path) .. "/"
  vim.cmd("diffoff!")
  for _, buffer in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buffer)
    local real = vim.uv.fs_realpath(name)
    if
      api.nvim_buf_is_loaded(buffer)
      and vim.bo[buffer].buftype == ""
      and not vim.bo[buffer].modified
      and real
      and real:sub(1, #prefix) == prefix
      and vim.fn.filereadable(name) == 1
    then
      api.nvim_buf_call(buffer, function() vim.cmd("silent edit") end)
    end
  end
end

function M.open(pr, keep_position, worktree_root)
  if not saved(keep_position and "Save your edits before pulling PR updates." or nil) then return end
  help.close()
  local repo, position = state.repo, nil
  local function before_update()
    if not saved("Save your edits before pulling PR updates.") then
      error("Pull stopped because edits became unsaved.", 0)
    end
  end
  if keep_position then
    browse.close(state)
    local current = api.nvim_get_current_win()
    local selected_row = state.tree_rows[api.nvim_win_get_cursor(state.list)[1]]
    position = {
      list_path = selected_row and selected_row.path,
      path = state.selected,
      cursor = api.nvim_win_get_cursor(state.right),
      focus = current == state.list and "list" or current == state.left and "left" or "right",
      collapsed = vim.deepcopy(state.collapsed),
      auto_collapsed = vim.deepcopy(state.auto_collapsed),
      all_files = state.all_files,
      project_collapsed = vim.deepcopy(state.project_collapsed),
    }
  end
  task(
    "Preparing PR #" .. pr.number .. "...",
    function()
      local fresh = core.pull_request(repo, pr.number)
      before_update()
      local session = core.prepare(repo, fresh, worktree_root, before_update)
      if session.needs_worktree then return session end
      before_update()
      require("review.lsp").reset()
      reload_buffers(session.path)
      vim.cmd.cd(vim.fn.fnameescape(session.path))
      review(session, position)
      if session.warning then
        vim.schedule(function() vim.notify(session.warning, vim.log.levels.WARN) end)
      elseif session.backup then
        vim.schedule(
          function() vim.notify("Updated to GitHub. Previous local commits are saved on " .. session.backup) end
        )
      end
    end,
    true,
    function(pending)
      if not pending then return end
      vim.ui.select({ "Cancel", "Create worktree" }, {
        prompt = "No clean existing checkout is available. Create " .. pending.path .. "?",
      }, function(choice)
        if choice == "Create worktree" and state.repo == repo then M.open(pr, keep_position, pending.root) end
      end)
    end
  )
end

function M.start(directory)
  state.directory = vim.fs.normalize(vim.fn.fnamemodify(directory, ":p"))
  vim.g.mapleader = " "
  api.nvim_create_user_command("ReviewQuit", "qall<bang>", { bang = true, force = true })
  api.nvim_create_user_command("ReviewNext", M.next_file, { force = true })
  api.nvim_create_user_command("ReviewBack", M.undo_next, { force = true })
  api.nvim_create_user_command("ReviewGenerated", M.toggle_generated, { force = true })
  api.nvim_create_user_command("ReviewPull", function() M.refresh() end, { force = true })
  api.nvim_create_user_command("ReviewFiles", M.toggle_files, { force = true })
  api.nvim_create_user_command("ReviewFind", M.find_file, { force = true })
  api.nvim_create_user_command("ReviewClosePeek", function() browse.close(state) end, { force = true })
  api.nvim_create_user_command("ReviewCommitPush", M.commit_push, { force = true })
  api.nvim_create_user_command("ReviewReady", M.ready, { force = true })
  local function instructions()
    if not state.busy then help.toggle() end
  end
  api.nvim_create_user_command("ReviewHelp", instructions, { force = true })
  vim.cmd([[cnoreabbrev <expr> q getcmdtype() == ':' && getcmdline() ==# 'q' ? 'ReviewQuit' : 'q']])
  vim.keymap.set("n", "<leader>q", function()
    help.close()
    vim.cmd("ReviewQuit")
  end, { silent = true })
  vim.keymap.set("n", "<leader>i", instructions, { silent = true })
  vim.keymap.set("n", "<leader>n", M.next_file, { silent = true })
  vim.keymap.set("n", "<leader>b", M.undo_next, { silent = true })
  vim.keymap.set("n", "<leader>g", M.toggle_generated, { silent = true })
  vim.keymap.set("n", "<leader>a", M.toggle_files, { silent = true })
  vim.keymap.set("n", "<leader>o", M.find_file, { silent = true })
  vim.keymap.set("n", "<leader>cc", M.commit_push, { silent = true })
  vim.keymap.set("n", "<leader>e", M.ready, { silent = true })
  vim.keymap.set("n", "<leader>f", function()
    help.close()
    if state.list and api.nvim_win_is_valid(state.list) then api.nvim_set_current_win(state.list) end
  end)
  vim.keymap.set("n", "<leader>p", function()
    if state.repo then M.pull_requests(state.repo) end
  end)
  vim.keymap.set("n", "<leader>r", function()
    if state.session then M.refresh() end
  end)
  M.repositories()
end

M.state = state
return M
