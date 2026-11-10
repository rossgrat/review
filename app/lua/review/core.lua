local M = {}
local uv = vim.uv
local user_id = uv.os_get_passwd().uid

function M.run(args, cwd, allow_failure, input)
  local result
  local thread = coroutine.running()
  if thread then
    vim.system(args, { cwd = cwd, timeout = 30000, stdin = input }, function(output)
      vim.schedule(function()
        local ok, err = coroutine.resume(thread, output)
        if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
      end)
    end)
    result = coroutine.yield()
  else
    result = vim.system(args, { cwd = cwd, stdin = input }):wait(30000)
  end
  if result.code ~= 0 and not allow_failure then
    local message = vim.trim(result.stderr or "")
    error(message ~= "" and message or args[1] .. " failed with exit code " .. result.code, 0)
  end
  return result.stdout or "", result.code, result.stderr or ""
end

function M.git(path, args, allow_failure, input)
  return M.run(vim.list_extend({ "git", "-C", path }, args), nil, allow_failure, input)
end

local function trimmed(path, args) return vim.trim(M.git(path, args)) end

local function parallel(items, fn)
  local parent, next_index, completed = coroutine.running(), 1, 0
  local suspended, failure = false, nil
  for _ = 1, math.min(8, #items) do
    coroutine.wrap(function()
      while next_index <= #items do
        local index = next_index
        next_index = index + 1
        local ok, err = pcall(fn, items[index], index)
        if not ok then failure = failure or err end
        completed = completed + 1
      end
      if completed == #items and suspended and parent then
        vim.schedule(function()
          local ok, err = coroutine.resume(parent)
          if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
        end)
      end
    end)()
  end
  if completed < #items then
    suspended = true
    if parent then
      coroutine.yield()
    else
      assert(vim.wait(30000, function() return completed == #items end, 1), "Repository discovery timed out")
    end
  end
  if failure then error(failure, 0) end
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return end
  local contents = file:read("*a")
  file:close()
  return contents
end

local function resolve(directory, path)
  return uv.fs_realpath(path:sub(1, 1) == "/" and path or directory .. "/" .. path)
end

local function repository_metadata(path)
  if vim.env.GIT_DIR or vim.env.GIT_COMMON_DIR or vim.env.GIT_WORK_TREE then return end
  local git_dir = path .. "/.git"
  local stat = uv.fs_stat(git_dir)
  if not stat then
    git_dir = path
  elseif stat.type == "file" then
    local target = (read_file(git_dir) or ""):match("^gitdir: ([^\r\n]+)[\r\n]*$")
    if not target then return end
    git_dir = resolve(path, target)
  elseif stat.type ~= "directory" then
    return
  end
  if not git_dir then return end
  git_dir = uv.fs_realpath(git_dir)
  if not git_dir then return end
  local common = git_dir
  local shared = read_file(git_dir .. "/commondir")
  if shared then
    local target = shared:match("^([^\r\n]+)[\r\n]*$")
    common = target and resolve(git_dir, target)
  end
  if not common then return end
  for _, directory in ipairs({ path, git_dir, common }) do
    stat = uv.fs_stat(directory)
    if not stat or stat.uid ~= user_id then return end
  end
  local objects, refs = uv.fs_stat(common .. "/objects"), uv.fs_stat(common .. "/refs")
  if not objects or objects.type ~= "directory" or not refs or refs.type ~= "directory" then return end
  local config = read_file(common .. "/config")
  if not config then return end
  local section, version
  for line in config:gmatch("[^\r\n]+") do
    local header = line:match("^%s*%[([^%]]+)%]")
    if header then
      section = vim.trim(header):lower()
      if section == "extensions" or section:match("^include") then return end
    elseif section == "core" then
      version = line:lower():match("^%s*repositoryformatversion%s*=%s*(%S+)") or version
    end
  end
  if version ~= "0" then return end
  stat = uv.fs_lstat(git_dir .. "/HEAD")
  if not stat or stat.type ~= "file" then return end
  local head = (read_file(git_dir .. "/HEAD") or ""):gsub("[\r\n]+$", "")
  local branch = head:match("^ref: refs/heads/(%S+)$")
  if branch and branch:sub(1, 1) ~= "." then return { common = common, branch = branch } end
  if #head == 40 and head:match("^%x+$") then return { common = common, branch = "detached" } end
end

function M.discover(directory)
  local candidates, metadata, found, seen = {}, {}, {}, {}
  local function visit(path)
    if uv.fs_stat(path .. "/.git") or uv.fs_stat(path .. "/HEAD") and uv.fs_stat(path .. "/objects") then
      candidates[#candidates + 1] = path
      return
    end
    local entries = uv.fs_scandir(path)
    if not entries then return end
    while true do
      local name, kind = uv.fs_scandir_next(entries)
      if not name then break end
      if kind == "directory" and name:sub(1, 1) ~= "." and name ~= "node_modules" then
        visit(path .. "/" .. name)
      end
    end
  end
  directory = uv.fs_realpath(vim.fn.expand(directory))
  assert(directory, "Directory does not exist")
  visit(directory)
  parallel(candidates, function(path, index)
    metadata[index] = repository_metadata(path)
    if metadata[index] then return end
    local common, code = M.git(path, { "rev-parse", "--path-format=absolute", "--git-common-dir" }, true)
    if code == 0 then
      local branch = vim.trim(M.git(path, { "symbolic-ref", "--quiet", "--short", "HEAD" }, true))
      metadata[index] =
        { common = uv.fs_realpath(vim.trim(common)), branch = branch ~= "" and branch or "detached" }
    end
  end)
  for index, path in ipairs(candidates) do
    local common = metadata[index] and metadata[index].common
    if common and not seen[common] then
      seen[common] = true
      found[#found + 1] =
        { path = path, common = common, name = vim.fs.basename(path), branch = metadata[index].branch }
    end
  end
  table.sort(found, function(a, b)
    if a.name:lower() == b.name:lower() then return a.path < b.path end
    return a.name:lower() < b.name:lower()
  end)
  return found
end

function M.pull_requests(repo)
  local query = [[
    query($owner:String!, $name:String!, $endCursor:String) {
      repository(owner:$owner, name:$name) {
        nameWithOwner
        pullRequests(first:100, after:$endCursor, states:OPEN, orderBy:{field:CREATED_AT,direction:DESC}) {
          nodes { number title draft:isDraft updated_at:updatedAt user:author { login } headRefName baseRefName }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  ]]
  local args = {
    "gh",
    "api",
    "graphql",
    "--paginate",
    "--slurp",
    "-F",
    "owner={owner}",
    "-F",
    "name={repo}",
    "-f",
    "query=" .. query,
  }
  local response = M.run(args, repo.path)
  local pages = vim.json.decode(response)
  local prs = {}
  for _, page in ipairs(pages) do
    local repository = page.data.repository
    repo.slug = repository.nameWithOwner
    for _, pr in ipairs(repository.pullRequests.nodes) do
      pr.head, pr.base = { ref = pr.headRefName }, { ref = pr.baseRefName }
      if pr.user == vim.NIL then pr.user = nil end
      prs[#prs + 1] = pr
    end
  end
  return prs
end

function M.pull_request(repo, number)
  local response =
    M.run({ "gh", "api", "--method", "GET", "repos/" .. repo.slug .. "/pulls/" .. number }, repo.path)
  local pr = vim.json.decode(response)
  assert(pr.state == "open", "This PR is no longer open. Refresh the PR list.")
  return pr
end

function M.worktrees(path)
  local result, item = {}, {}
  for field in M.git(path, { "worktree", "list", "--porcelain", "-z" }):gmatch("([^%z]*)%z") do
    if field == "" then
      if item.path then result[#result + 1] = item end
      item = {}
    else
      local key, value = field:match("^(%S+) (.*)$")
      if key == "worktree" then item.path = value end
      if key == "branch" then item.branch = value end
      if field == "bare" then item.bare = true end
      if key == "prunable" or field == "prunable" then item.prunable = true end
    end
  end
  return result
end

local function slug(url)
  return url:match("github%.com[:/]([^/]+/[^/]+)")
    and url:match("github%.com[:/]([^/]+/[^/]+)"):gsub("%.git$", "")
end

local function remote_for(path, repository, push)
  for remote in M.git(path, { "remote" }):gmatch("[^\n]+") do
    local args = { "remote", "get-url" }
    if push then vim.list_extend(args, { "--push", "--all" }) end
    args[#args + 1] = remote
    local urls = vim.split(trimmed(path, args), "\n", { trimempty = true })
    if #urls == 1 and slug(urls[1]) == repository.full_name then return remote end
  end
  return repository.ssh_url
end

function M.prepare(repo, pr, worktree_root, before_update)
  assert(pr.head.repo ~= vim.NIL and pr.head.repo, "The PR source repository no longer exists")
  local prefix = "refs/pr-review/" .. pr.number
  local base_ref, head_ref = pr.base.sha, pr.head.sha
  local present = base_ref
    and head_ref
    and M.git(
        repo.path,
        { "cat-file", "--batch-check=%(objecttype)" },
        false,
        base_ref .. "\n" .. head_ref .. "\n"
      )
      == "commit\ncommit\n"
  if not present then
    M.git(repo.path, {
      "fetch",
      "--atomic",
      "--no-tags",
      "--no-write-fetch-head",
      "--",
      remote_for(repo.path, pr.base.repo),
      "+refs/heads/" .. pr.base.ref .. ":" .. prefix .. "/base",
      "+refs/pull/" .. pr.number .. "/head:" .. prefix .. "/head",
    })
    base_ref, head_ref = prefix .. "/base", prefix .. "/head"
  end

  local branch = pr.head.ref
  local local_tip, exists = M.git(repo.path, { "rev-parse", "--verify", "refs/heads/" .. branch }, true)
  if exists == 0 then
    local upstream =
      trimmed(repo.path, { "for-each-ref", "--format=%(upstream:remotename)", "refs/heads/" .. branch })
    local url = upstream ~= "" and M.git(repo.path, { "remote", "get-url", upstream }, true) or ""
    local _, contains =
      M.git(repo.path, { "merge-base", "--is-ancestor", head_ref, vim.trim(local_tip) }, true)
    if
      slug(vim.trim(url)) ~= pr.head.repo.full_name
      and contains ~= 0
      and pr.head.repo.full_name ~= pr.base.repo.full_name
    then
      branch = "pr-review/" .. pr.number
    end
  end
  local trees, tree = M.worktrees(repo.path), nil
  local managed = vim.fn.stdpath("data") .. "/worktrees/"
  for _, candidate in ipairs(trees) do
    if
      candidate.branch == "refs/heads/" .. branch
      and not candidate.prunable
      and uv.fs_stat(candidate.path)
    then
      tree = candidate.path
      break
    end
  end
  if not tree or tree:sub(1, #managed) == managed then
    local aliases = {}
    local tracking = M.git(
      repo.path,
      { "for-each-ref", "--format=%(refname)%09%(upstream:remotename)%09%(upstream:remoteref)", "refs/heads" }
    )
    for line in tracking:gmatch("[^\n]+") do
      local ref, remote, upstream = line:match("^([^\t]+)\t([^\t]*)\t(.*)$")
      if remote and remote ~= "" and upstream == "refs/heads/" .. pr.head.ref then aliases[ref] = remote end
    end
    for _, candidate in ipairs(trees) do
      if
        candidate.branch
        and not candidate.prunable
        and aliases[candidate.branch]
        and uv.fs_stat(candidate.path)
        and candidate.path:sub(1, #managed) ~= managed
        and slug(trimmed(repo.path, { "remote", "get-url", aliases[candidate.branch] }))
          == pr.head.repo.full_name
      then
        tree, branch = candidate.path, candidate.branch:sub(#"refs/heads/" + 1)
        break
      end
    end
  end
  if not tree and not worktree_root then
    local usable, others, selected_bare = {}, {}, false
    local selected_path = uv.fs_realpath(repo.path)
    for _, candidate in ipairs(trees) do
      if uv.fs_realpath(candidate.path) == selected_path and candidate.bare then selected_bare = true end
      if not candidate.bare and not candidate.prunable and uv.fs_stat(candidate.path) then
        if uv.fs_realpath(candidate.path) == selected_path then
          usable = { candidate }
        else
          others[#others + 1] = candidate
        end
      end
    end
    if #usable == 0 and selected_bare and #others == 1 then usable = others end
    for _, candidate in ipairs(usable) do
      if M.git(candidate.path, { "status", "--porcelain=v1" }) == "" then
        if before_update then before_update() end
        local _, branch_exists = M.git(repo.path, { "show-ref", "--verify", "refs/heads/" .. branch }, true)
        local args = { "switch", "--no-overwrite-ignore" }
        if branch_exists == 0 then
          args[#args + 1] = branch
        else
          vim.list_extend(args, { "--create", branch, head_ref })
        end
        M.git(candidate.path, args)
        tree = candidate.path
        break
      end
    end
  end
  if not tree then
    local common = repo.common
      or trimmed(repo.path, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
    local root = worktree_root
      or (vim.fn.stdpath("data") .. "/worktrees/" .. vim.fn.sha256(common):sub(1, 16))
    tree = root .. "/pr-" .. pr.number
    if not worktree_root then return { needs_worktree = true, path = tree, root = root, branch = branch } end
    if before_update then before_update() end
    vim.fn.mkdir(root, "p")
    local _, branch_exists = M.git(repo.path, { "show-ref", "--verify", "refs/heads/" .. branch }, true)
    local args = { "worktree", "add" }
    if branch_exists ~= 0 then
      vim.list_extend(args, { "-b", branch, tree, head_ref })
    else
      vim.list_extend(args, { tree, branch })
    end
    M.git(repo.path, args)
  end
  local counts = trimmed(tree, { "rev-list", "--left-right", "--count", head_ref .. "...HEAD" })
  local behind, ahead = counts:match("(%d+)%s+(%d+)")
  behind, ahead = tonumber(behind), tonumber(ahead)
  local warning, backup
  if behind > 0 then
    if M.git(tree, { "status", "--porcelain=v1" }) ~= "" then
      warning =
        "GitHub has newer commits. Local changes prevent an automatic update. Stash them, pull, then reapply them."
    elseif ahead == 0 then
      if before_update then before_update() end
      M.git(tree, { "merge", "--ff-only", "--no-edit", "--no-overwrite-ignore", head_ref })
      behind = 0
    else
      local previous = trimmed(tree, { "rev-parse", "HEAD" })
      local prefix = "pr-review/" .. pr.number .. "-before-pull-" .. previous:sub(1, 12)
      local suffix = 0
      backup = prefix
      if before_update then before_update() end
      while true do
        local existing, code = M.git(tree, { "rev-parse", "--verify", "refs/heads/" .. backup }, true)
        if code == 0 and vim.trim(existing) == previous and backup ~= branch then break end
        if code ~= 0 and backup ~= branch then
          M.git(tree, { "branch", backup, previous })
          break
        end
        suffix = suffix + 1
        backup = prefix .. "-" .. suffix
      end
      if before_update then before_update() end
      assert(
        trimmed(tree, { "branch", "--show-current" }) == branch
          and trimmed(tree, { "rev-parse", "HEAD" }) == previous,
        "The checkout changed while pulling. Pull again."
      )
      M.git(tree, { "switch", "--no-overwrite-ignore", "--force-create", branch, head_ref })
      ahead, behind = 0, 0
    end
  end
  local base = trimmed(tree, { "merge-base", base_ref, "HEAD" })
  return {
    path = tree,
    base = base,
    pr = pr,
    branch = branch,
    ahead = ahead,
    behind = behind,
    warning = warning,
    backup = backup,
  }
end

function M.commit_plan(session, pr)
  assert(
    trimmed(session.path, { "branch", "--show-current" }) == session.branch,
    "The worktree branch changed. Reopen the PR before committing."
  )
  assert(pr.head.repo and pr.head.repo ~= vim.NIL, "The PR source repository no longer exists")
  local status = M.git(session.path, { "status", "--porcelain=v1", "-z", "--untracked-files=all" })
  local fields = vim.split(status, "\0", { plain = true, trimempty = true })
  local files, stage, seen, index = {}, {}, {}, 1
  while index <= #fields do
    local code, path = fields[index]:sub(1, 2), fields[index]:sub(4)
    assert(
      not code:find("U", 1, true) and code ~= "AA" and code ~= "DD",
      "Resolve merge conflicts before committing."
    )
    if not seen[path] then
      files[#files + 1], seen[path] = path, true
    end
    local renamed = code:find("R", 1, true) or code:find("C", 1, true)
    if code == "??" or code:sub(2, 2) ~= " " then
      stage[#stage + 1] = path
      if code:sub(2, 2) == "R" then stage[#stage + 1] = fields[index + 1] end
    end
    index = index + (renamed and 2 or 1)
  end
  return {
    files = files,
    stage = stage,
    status = status,
    head = trimmed(session.path, { "rev-parse", "HEAD" }),
    remote = remote_for(session.path, pr.head.repo, true),
    destination = pr.head.repo.full_name .. ":" .. pr.head.ref,
    ref = "refs/heads/" .. pr.head.ref,
  }
end

function M.commit_and_push(session, plan, message)
  assert(
    trimmed(session.path, { "branch", "--show-current" }) == session.branch,
    "The worktree branch changed. Reopen the PR before committing."
  )
  assert(
    trimmed(session.path, { "rev-parse", "HEAD" }) == plan.head
      and M.git(session.path, { "status", "--porcelain=v1", "-z", "--untracked-files=all" }) == plan.status,
    "The worktree changed. Run commit and push again."
  )
  if #plan.files > 0 then
    assert(message and vim.trim(message) ~= "", "Enter a commit message.")
    if #plan.stage > 0 then
      M.git(session.path, vim.list_extend({ "--literal-pathspecs", "add", "--" }, plan.stage))
    end
    local _, clean = M.git(session.path, { "diff", "--cached", "--quiet" }, true)
    if clean ~= 0 then M.git(session.path, { "commit", "-m", message }) end
  end
  local commit = trimmed(session.path, { "rev-parse", "HEAD" })
  local output, code, stderr =
    M.git(session.path, { "push", "--", plan.remote, commit .. ":" .. plan.ref }, true)
  if code ~= 0 then
    error(
      "Push failed. Local commit "
        .. commit:sub(1, 8)
        .. " is preserved. Resolve the push error and run commit and push again.\n"
        .. (stderr ~= "" and stderr or output),
      0
    )
  end
  return commit
end

local function unchanged(session, path)
  local entry =
    trimmed(session.path, { "ls-tree", "--format=%(objectmode) %(objectname)", session.base, "--", path })
  local mode, hash = entry:match("(%d+) (%x+)")
  local stat = uv.fs_lstat(session.path .. "/" .. path)
  if stat.type == "link" then
    return mode == "120000"
      and uv.fs_readlink(session.path .. "/" .. path)
        == M.git(session.path, { "show", session.base .. ":" .. path })
  end
  if stat.type ~= "file" or mode == "120000" then return false end
  local filemode = M.git(session.path, { "config", "--bool", "core.filemode" }, true)
  local executable = bit.band(stat.mode, 64) ~= 0
  return (vim.trim(filemode) == "false" or mode == (executable and "100755" or "100644"))
    and trimmed(session.path, { "hash-object", "--path=" .. path, "--", path }) == hash
end

function M.changes(session)
  local tokens = vim.split(
    M.git(session.path, { "diff", "--name-status", "-z", "--find-renames", session.base, "--" }),
    "\0",
    { trimempty = true, plain = true }
  )
  local files, removed, index = {}, {}, 1
  while index <= #tokens do
    local status, old = tokens[index], tokens[index + 1]
    local renamed = status:sub(1, 1) == "R" or status:sub(1, 1) == "C"
    files[#files + 1] = { status = status, old_path = old, path = renamed and tokens[index + 2] or old }
    if status == "D" or renamed then removed[old] = files[#files] end
    index = index + (renamed and 3 or 2)
  end
  for path in M.git(session.path, { "ls-files", "--others", "--exclude-standard", "-z" }):gmatch("([^%z]+)%z") do
    local previous = removed[path]
    if previous then
      if previous.status == "D" then
        previous.omit = true
      else
        previous.status = "A"
      end
      if not unchanged(session, path) then
        files[#files + 1] = { status = "M", old_path = path, path = path }
      end
    else
      files[#files + 1] = { status = "?", path = path }
    end
  end
  files = vim.tbl_filter(function(file) return not file.omit end, files)
  table.sort(files, function(a, b) return a.path < b.path end)
  return files
end

function M.original(session, file)
  if file.status == "?" or file.status == "A" then return "" end
  local key = session.base .. ":" .. file.old_path
  session.originals = session.originals or {}
  if session.originals[key] ~= nil then return session.originals[key] end
  local contents = M.git(session.path, { "show", key })
  local size = session.original_bytes or 0
  if size + #contents <= 8 * 1024 * 1024 then
    session.originals[key], session.original_bytes = contents, size + #contents
  end
  return contents
end

return M
