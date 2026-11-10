package.path = "./lua/?.lua;" .. package.path
local core = require("review.core")
local api = vim.api
local project_dir = vim.fn.fnamemodify(".", ":p")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
vim.env.XDG_DATA_HOME = root .. "/data"
vim.env.XDG_STATE_HOME = root .. "/state"
local passed = 0

local function equal(actual, expected)
  assert(
    vim.deep_equal(actual, expected),
    "Expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
end

local function put(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function get(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
end

local function finish_task(ui)
  assert(vim.wait(10000, function() return not ui.state.busy end, 10), "UI operation timed out")
end

local function choose_file(ui, path)
  api.nvim_set_current_win(ui.state.list)
  local parent = ""
  local parts = vim.split(path, "/", { plain = true })
  for index = 1, #parts - 1 do
    parent = parent .. parts[index] .. "/"
    if ui.state.collapsed[parent] then
      for line, row in pairs(ui.state.tree_rows) do
        if row.directory and row.path == parent then
          api.nvim_win_set_cursor(0, { line, 0 })
          vim.fn.maparg("l", "n", false, true).callback()
          break
        end
      end
    end
  end
  local selected = false
  for line, row in pairs(ui.state.tree_rows) do
    if row.file and row.file.path == path then
      api.nvim_win_set_cursor(0, { line, 0 })
      selected = true
      break
    end
  end
  assert(selected, "File is absent from the visible tree: " .. path)
  vim.fn.maparg("<CR>", "n", false, true).callback()
  finish_task(ui)
end

local started = false
vim.schedule(function() started = true end)
assert(vim.wait(5000, function() return started and not require("review.ui").state.busy end, 10))

local ok, err = xpcall(function()
  local catalog, repo, remote = root .. "/catalog", root .. "/catalog/example", root .. "/remote.git"
  vim.fn.mkdir(repo, "p")
  core.run({ "git", "init", "--bare", "--initial-branch=main", remote })
  core.run({ "git", "init", "--initial-branch=main", repo })
  local function git(args) return core.git(repo, args) end
  local function sha(ref) return vim.trim(git({ "rev-parse", ref })) end
  local function commit(message) git({ "commit", "-m", message }) end
  git({ "config", "user.name", "Review Test" })
  git({ "config", "user.email", "review-test@example.invalid" })
  git({ "config", "commit.gpgsign", "false" })
  git({ "remote", "add", "origin", remote })
  put(repo .. "/app.txt", "base\n")
  put(repo .. "/old name.txt", "rename me\n")
  put(repo .. "/remove.txt", "remove me\n")
  put(repo .. "/binary.dat", "original\0bytes")
  put(repo .. "/empty.txt", "")
  vim.fn.mkdir(repo .. "/internal/catalog", "p")
  put(
    repo .. "/internal/catalog/item.go",
    'package catalog\n\nfunc Label(name string) string {\n\treturn "Item: " + name\n}\n'
  )
  put(repo .. "/.gitignore", "*.ignored\n")
  git({
    "add",
    "app.txt",
    "old name.txt",
    "remove.txt",
    "binary.dat",
    "empty.txt",
    ".gitignore",
    "internal/catalog/item.go",
  })
  commit("Baseline")
  git({ "switch", "-c", "feature-a" })
  put(repo .. "/app.txt", "base\nparent\n")
  put(repo .. "/parent.txt", "parent change\n")
  git({ "add", "app.txt", "parent.txt" })
  commit("Parent PR")
  local parent = sha("HEAD")
  git({ "switch", "-c", "feature-b" })
  put(repo .. "/app.txt", "base\nparent\nchild\n")
  put(
    repo .. "/internal/catalog/item.go",
    'package catalog\n\nfunc Label(name string) string {\n\treturn "Product: " + name\n}\n'
  )
  git({ "mv", "old name.txt", "new name.txt" })
  git({ "rm", "remove.txt" })
  git({ "add", "app.txt", "internal/catalog/item.go" })
  commit("Child PR")
  local child = sha("HEAD")
  git({ "switch", "feature-a" })
  put(repo .. "/later-parent.txt", "new parent change\n")
  git({ "add", "later-parent.txt" })
  commit("Parent advances independently")
  git({
    "push",
    "origin",
    "main",
    "feature-a",
    "feature-b",
    "feature-b:refs/pull/2/head",
    "feature-b:refs/pull/3/head",
    "feature-b:refs/pull/4/head",
  })
  local outside = root .. "/outside worktree"
  git({ "worktree", "add", outside, "feature-b" })
  put(outside .. "/ahead.txt", "local committed change\n")
  core.git(outside, { "add", "ahead.txt" })
  core.git(outside, { "commit", "-m", "Local ahead" })
  put(outside .. "/app.txt", "base\nparent\nchild\nstaged\n")
  put(outside .. "/staged-add.txt", "staged new file\n")
  core.git(outside, { "add", "app.txt", "staged-add.txt" })
  put(outside .. "/app.txt", "base\nparent\nchild\nstaged\nunstaged\n")
  put(outside .. "/new file.txt", "untracked\n")
  put(outside .. "/skip.ignored", "ignored\n")
  put(repo .. "/parent.txt", "dirty parent worktree\n")
  local before = git({ "status", "--porcelain=v1" })
  local repository = { path = repo, common = repo .. "/.git", slug = "acme/example" }
  local project = { full_name = "acme/example", ssh_url = remote }
  local pr = {
    number = 2,
    title = "Child PR",
    draft = true,
    state = "open",
    user = { login = "rossgrat" },
    updated_at = "2026-11-09T20:10:00Z",
    base = { ref = "feature-a", sha = sha("feature-a"), repo = project },
    head = { ref = "feature-b", sha = child, repo = project },
  }
  local session

  test("nested repositories and external worktrees appear once", function()
    git({ "worktree", "add", catalog .. "/linked", "main" })
    local repos = core.discover(catalog)
    equal(#repos, 1)
    equal(repos[1].common, vim.uv.fs_realpath(repo .. "/.git"))
    equal(#core.worktrees(repo), 3)
  end)

  test("repositories sort by name across directories without case affecting the order", function()
    for _, name in ipairs({ "z/Alpha", "a/Zulu", "m/beta" }) do
      local path = root .. "/sorted/" .. name
      vim.fn.mkdir(path, "p")
      core.run({ "git", "init", "--initial-branch=main", path })
    end
    local names = {}
    for _, found in ipairs(core.discover(root .. "/sorted")) do
      names[#names + 1] = found.name
    end
    equal(names, { "Alpha", "beta", "Zulu" })
    local ui = require("review.ui")
    ui.start(root .. "/sorted")
    finish_task(ui)
  end)

  test(
    "ordinary metadata stays fresh without Git processes for linked, detached, and bare repositories",
    function()
      local linked = catalog .. "/linked"
      local pointer = get(linked .. "/.git")
      local admin = vim.trim(core.git(linked, { "rev-parse", "--absolute-git-dir" }))
      put(linked .. "/.git", "gitdir: ../example/.git/worktrees/" .. vim.fs.basename(admin) .. "\n")
      local original, calls = core.run, 0
      core.run = function(...)
        calls = calls + 1
        return original(...)
      end
      local found = core.discover(linked)
      equal(calls, 0)
      equal(found[1].common, vim.uv.fs_realpath(repo .. "/.git"))
      equal(found[1].branch, "main")
      core.run = original
      core.git(linked, { "switch", "-c", "discovery/check" })
      equal(core.discover(linked)[1].branch, "discovery/check")
      core.git(linked, { "switch", "--detach" })
      equal(core.discover(linked)[1].branch, "detached")
      core.git(linked, { "switch", "main" })
      put(linked .. "/.git", pointer)
      equal(core.discover(remote)[1].branch, "main")
    end
  )

  test("nonstandard metadata uses Git and malformed repositories stay excluded", function()
    local path = root .. "/reftable"
    core.run({ "git", "init", "--ref-format=reftable", "--initial-branch=table-main", path })
    local discovered = core.discover(path)
    equal(#discovered, 1)
    equal(discovered[1].branch, "table-main")
    core.git(path, { "symbolic-ref", "HEAD", "refs/heads/renamed-table" })
    equal(core.discover(path)[1].branch, "renamed-table")
    local broken = root .. "/broken"
    vim.fn.mkdir(broken, "p")
    put(broken .. "/.git", "not a Git pointer\n")
    equal(#core.discover(broken), 0)
  end)

  test("existing dirty worktree is reused without changing the parent checkout", function()
    local original_git, fetched = core.git, false
    core.git = function(path, args, ...)
      if args[1] == "fetch" then fetched = true end
      return original_git(path, args, ...)
    end
    session = core.prepare(repository, pr, root .. "/managed")
    core.git = original_git
    equal(fetched, false)
    equal(session.path, outside)
    equal(session.base, parent)
    equal(session.ahead, 1)
    equal(session.behind, 0)
    equal(git({ "status", "--porcelain=v1" }), before)
    equal(get(outside .. "/app.txt"), "base\nparent\nchild\nstaged\nunstaged\n")
    equal(vim.uv.fs_stat(repo .. "/.git/FETCH_HEAD"), nil)
  end)

  test("diff contains committed, staged, unstaged and untracked changes", function()
    local files = core.changes(session)
    local by_path = {}
    for _, file in ipairs(files) do
      by_path[file.path] = file
    end
    equal(#files, 7)
    equal(by_path["app.txt"].status, "M")
    equal(by_path["ahead.txt"].status, "A")
    equal(by_path["staged-add.txt"].status, "A")
    equal(by_path["new file.txt"].status, "?")
    equal(by_path["remove.txt"].status, "D")
    equal(by_path["new name.txt"].old_path, "old name.txt")
    equal(core.original(session, by_path["app.txt"]), "base\nparent\n")
    equal(core.original(session, by_path["new name.txt"]), "rename me\n")
    equal(core.original(session, by_path["new file.txt"]), "")
    equal(by_path["parent.txt"], nil)
    equal(by_path["later-parent.txt"], nil)
    equal(by_path["skip.ignored"], nil)
  end)

  test("base content is reused without hiding local edits or a different comparison base", function()
    local selected = { path = outside, base = parent }
    local file = { status = "M", path = "app.txt", old_path = "app.txt" }
    local original, calls = core.git, 0
    core.git = function(path, args, ...)
      if args[1] == "show" then calls = calls + 1 end
      return original(path, args, ...)
    end
    equal(core.original(selected, file), "base\nparent\n")
    equal(core.original(selected, file), "base\nparent\n")
    equal(calls, 1)
    local saved = get(outside .. "/app.txt")
    put(outside .. "/app.txt", saved .. "local edit\n")
    equal(core.original(selected, file), "base\nparent\n")
    equal(calls, 1)
    put(outside .. "/app.txt", saved)
    selected.base = child
    equal(core.original(selected, file), "base\nparent\nchild\n")
    equal(calls, 2)
    selected.base = parent
    equal(core.original(selected, file), "base\nparent\n")
    equal(calls, 2)
    equal(core.original(selected, { status = "M", old_path = "binary.dat" }), "original\0bytes")
    equal(core.original(selected, { status = "M", old_path = "binary.dat" }), "original\0bytes")
    equal(calls, 3)
    equal(core.original(selected, { status = "M", old_path = "empty.txt" }), "")
    equal(core.original(selected, { status = "M", old_path = "empty.txt" }), "")
    equal(calls, 4)
    core.git = original
  end)

  test("missing local branch gets its own worktree at the PR head", function()
    local fresh = vim.deepcopy(pr)
    fresh.number, fresh.head.ref = 3, "fresh"
    local opened = core.prepare(repository, fresh, root .. "/managed")
    equal(vim.trim(core.git(opened.path, { "branch", "--show-current" })), "fresh")
    equal(vim.trim(core.git(opened.path, { "rev-parse", "HEAD" })), child)
    equal(opened.base, parent)
    equal(core.prepare(repository, fresh, root .. "/managed").path, opened.path)
  end)

  test("fork branch name collision preserves the unrelated local branch", function()
    local fork = vim.deepcopy(pr)
    fork.number, fork.head.ref, fork.head.repo = 4, "feature-a", { full_name = "fork/example" }
    local previous = sha("feature-a")
    local opened = core.prepare(repository, fork, root .. "/managed")
    equal(vim.trim(core.git(opened.path, { "branch", "--show-current" })), "pr-review/4")
    equal(sha("feature-a"), previous)
    equal(core.prepare(repository, fork, root .. "/managed").path, opened.path)
  end)

  test("a PR fetches missing commits before creating its worktree", function()
    local publisher = root .. "/publisher"
    core.run({ "git", "clone", remote, publisher })
    core.git(publisher, { "config", "user.name", "Review Test" })
    core.git(publisher, { "config", "user.email", "review-test@example.invalid" })
    core.git(publisher, { "config", "commit.gpgsign", "false" })
    core.git(publisher, { "switch", "-c", "remote-only", "origin/feature-b" })
    put(publisher .. "/remote.txt", "remote commit\n")
    core.git(publisher, { "add", "remote.txt" })
    core.git(publisher, { "commit", "-m", "Remote only" })
    local remote_pr = vim.deepcopy(pr)
    remote_pr.number, remote_pr.head.ref = 5, "remote-only"
    remote_pr.head.sha = vim.trim(core.git(publisher, { "rev-parse", "HEAD" }))
    core.git(publisher, { "push", "origin", "HEAD:refs/pull/5/head" })
    local _, missing = core.git(repo, { "cat-file", "-e", remote_pr.head.sha }, true)
    assert(missing ~= 0)
    local opened = core.prepare(repository, remote_pr, root .. "/managed")
    equal(get(opened.path .. "/remote.txt"), "remote commit\n")
    equal(opened.base, parent)
  end)

  test("opening a PR updates its clean existing checkout to the latest commit", function()
    local fresh = vim.deepcopy(pr)
    fresh.number, fresh.head.ref = 3, "fresh"
    local checkout = core.prepare(repository, fresh, root .. "/managed").path
    local publisher = root .. "/publisher"
    core.git(publisher, { "switch", "-c", "refresh-updates", child })
    put(publisher .. "/app.txt", "new GitHub content\n")
    core.git(publisher, { "add", "app.txt" })
    core.git(publisher, { "commit", "-m", "Update PR remotely" })
    fresh.head.sha = vim.trim(core.git(publisher, { "rev-parse", "HEAD" }))
    core.git(publisher, { "push", "origin", "HEAD:refs/pull/3/head", "HEAD:refs/heads/fresh" })
    local updated = core.prepare(repository, fresh)
    equal(updated.path, checkout)
    equal(vim.trim(core.git(checkout, { "rev-parse", "HEAD" })), fresh.head.sha)
    equal(get(checkout .. "/app.txt"), "new GitHub content\n")
    equal(updated.behind, 0)
  end)

  test("an existing checkout is reused instead of creating a worktree", function()
    local checkout = root .. "/existing"
    core.run({ "git", "init", "--initial-branch=main", checkout })
    core.git(checkout, { "config", "user.name", "Review Test" })
    core.git(checkout, { "config", "user.email", "review-test@example.invalid" })
    core.git(checkout, { "config", "commit.gpgsign", "false" })
    put(checkout .. "/file.txt", "base\n")
    core.git(checkout, { "add", "file.txt" })
    core.git(checkout, { "commit", "-m", "Base" })
    local base = vim.trim(core.git(checkout, { "rev-parse", "HEAD" }))
    core.git(checkout, { "switch", "-c", "feature" })
    put(checkout .. "/file.txt", "PR\n")
    core.git(checkout, { "add", "file.txt" })
    core.git(checkout, { "commit", "-m", "PR" })
    local head = vim.trim(core.git(checkout, { "rev-parse", "HEAD" }))
    core.git(checkout, { "switch", "main" })
    local project = { full_name = "example/existing", ssh_url = checkout }
    local selected = {
      number = 10,
      base = { ref = "main", sha = base, repo = project },
      head = { ref = "feature", sha = head, repo = project },
    }
    local opened = core.prepare({ path = checkout }, selected)
    equal(opened.path, checkout)
    equal(opened.branch, "feature")
    equal(#core.worktrees(checkout), 1)
    equal(get(checkout .. "/file.txt"), "PR\n")
    core.git(checkout, { "branch", "other-source" })
    put(checkout .. "/notes.txt", "keep my changes\n")
    local unrelated = root .. "/unrelated-checkout"
    core.git(checkout, { "worktree", "add", "-b", "unrelated-branch", unrelated, "main" })
    selected.head.ref = "other-source"
    local pending = core.prepare({ path = checkout }, selected)
    equal(pending.needs_worktree, true)
    equal(vim.uv.fs_stat(pending.path), nil)
    equal(#core.worktrees(checkout), 2)
    equal(vim.trim(core.git(unrelated, { "branch", "--show-current" })), "unrelated-branch")
    equal(vim.trim(core.git(checkout, { "branch", "--show-current" })), "feature")
    equal(get(checkout .. "/notes.txt"), "keep my changes\n")
    core.git(checkout, { "switch", "main" })
    local alias = root .. "/user-checkout"
    core.git(checkout, { "worktree", "add", "-b", "working-alias", alias, "feature" })
    core.git(checkout, { "remote", "add", "github", "git@github.com:example/existing.git" })
    core.git(checkout, { "config", "branch.working-alias.remote", "github" })
    core.git(checkout, { "config", "branch.working-alias.merge", "refs/heads/feature" })
    local managed = vim.fn.stdpath("data") .. "/worktrees/owned"
    vim.fn.mkdir(vim.fs.dirname(managed), "p")
    core.git(checkout, { "worktree", "add", managed, "feature" })
    selected.head.ref = "feature"
    opened = core.prepare({ path = checkout }, selected)
    equal(opened.path, alias)
    equal(opened.branch, "working-alias")
    equal(#core.worktrees(checkout), 4)
    local stale = root .. "/stale-checkout"
    core.git(checkout, { "worktree", "add", "-b", "stale-branch", stale, "feature" })
    vim.uv.fs_unlink(stale .. "/.git")
    local found_stale = false
    for _, candidate in ipairs(core.worktrees(checkout)) do
      if candidate.path == stale then found_stale = candidate.prunable == true end
    end
    assert(found_stale, "Git must identify stale registrations even when their directories remain")
  end)

  local bin = root .. "/bin"
  vim.fn.mkdir(bin, "p")
  put(
    bin .. "/gh",
    [[#!/bin/sh
if [ "${PR_REVIEW_TEST_FAIL:-}" = 1 ]; then
  echo 'GitHub is unavailable' >&2
  exit 1
fi
if [ "$1" = auth ]; then
  exit 0
elif [ "$1" = repo ]; then
  echo acme/example
elif [ "$2" = graphql ]; then
  cat "$PR_REVIEW_TEST_PAGES"
else
  for arg in "$@"; do endpoint="$arg"; done
  case "$endpoint" in
    *) cat "$PR_REVIEW_TEST_PR" ;;
  esac
fi
]]
  )
  vim.uv.fs_chmod(bin .. "/gh", 493)
  vim.env.PATH = bin .. ":" .. vim.env.PATH
  vim.env.PR_REVIEW_TEST_PR = root .. "/pr.json"
  vim.env.PR_REVIEW_TEST_PAGES = root .. "/pages.json"
  put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(pr))
  local function page(items)
    local nodes = {}
    for _, item in ipairs(items) do
      nodes[#nodes + 1] =
        vim.tbl_extend("force", item, { headRefName = item.head.ref, baseRefName = item.base.ref })
    end
    return { data = { repository = { nameWithOwner = "acme/example", pullRequests = { nodes = nodes } } } }
  end
  put(
    vim.env.PR_REVIEW_TEST_PAGES,
    vim.json.encode({ page({ pr }), page({ vim.tbl_extend("force", pr, { number = 3, draft = false }) }) })
  )

  test("all pages of open PRs include drafts and retain the target branch", function()
    local prs = core.pull_requests(repository)
    equal(#prs, 2)
    equal(prs[1].draft, true)
    equal(prs[1].base.ref, "feature-a")
    equal(core.pull_request(repository, 2).number, 2)
  end)

  test("GitHub failure is visible and a closed PR cannot open", function()
    vim.env.PR_REVIEW_TEST_FAIL = "1"
    local success, message = pcall(core.pull_requests, repository)
    equal(success, false)
    assert(message:find("GitHub is unavailable", 1, true))
    vim.env.PR_REVIEW_TEST_FAIL = nil
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(vim.tbl_extend("force", pr, { state = "closed" })))
    equal(pcall(core.pull_request, repository, 2), false)
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(pr))
  end)

  test(
    "instructions open from lists, include every Review shortcut, and close without changing selection",
    function()
      local ui = require("review.ui")
      ui.start(catalog)
      finish_task(ui)
      local origin, buffer = api.nvim_get_current_win(), api.nvim_get_current_buf()
      local cursor = api.nvim_win_get_cursor(origin)
      api.nvim_feedkeys(" i", "xt", false)
      local popup = api.nvim_get_current_win()
      assert(popup ~= origin)
      equal(api.nvim_win_get_config(popup).relative, "editor")
      equal(vim.bo[api.nvim_get_current_buf()].modifiable, false)
      equal(vim.wo[popup].diff, false)
      local text = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      for _, shortcut in ipairs({
        "Space i",
        "Space f",
        "Space g",
        "Space n",
        "Space b",
        "Space p",
        "Space r",
        "Space c c",
        "Space q",
        ":ReviewHelp",
        ":ReviewNext",
        ":ReviewBack",
        ":ReviewGenerated",
        ":ReviewPull",
        ":ReviewCommitPush",
        ":ReviewQuit",
        ":wall",
        "]c / [c",
        "Ctrl-w h/j/k/l",
      }) do
        assert(text:find(shortcut, 1, true), "Missing instructions: " .. shortcut)
      end
      api.nvim_feedkeys("10j", "xt", false)
      assert(api.nvim_win_get_cursor(popup)[1] > 1)
      api.nvim_feedkeys("q", "xt", false)
      equal(api.nvim_win_is_valid(popup), false)
      equal(api.nvim_get_current_win(), origin)
      equal(api.nvim_get_current_buf(), buffer)
      equal(api.nvim_win_get_cursor(origin), cursor)
      vim.cmd("ReviewHelp")
      api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
      equal(api.nvim_get_current_win(), origin)
      api.nvim_feedkeys(" i i", "xt", false)
      equal(api.nvim_get_current_win(), origin)
      equal(#api.nvim_list_wins(), 1)
      local columns, rows = vim.o.columns, vim.o.lines
      vim.o.columns, vim.o.lines = 50, 18
      vim.cmd("ReviewHelp")
      popup = api.nvim_get_current_win()
      assert(api.nvim_win_get_width(popup) < vim.o.columns)
      assert(api.nvim_win_get_height(popup) < vim.o.lines)
      equal(vim.wo[popup].wrap, true)
      api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
      vim.o.columns, vim.o.lines = columns, rows
      equal(api.nvim_get_current_win(), origin)
    end
  )

  test("pull and picker reopen update loaded buffers while saves stay local", function()
    local ui = require("review.ui")
    local fresh = vim.deepcopy(pr)
    fresh.number, fresh.head.ref = 3, "fresh"
    local publisher = root .. "/publisher"
    fresh.head.sha = vim.trim(core.git(publisher, { "rev-parse", "HEAD" }))
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(fresh))
    ui.pull_requests(repository, true)
    finish_task(ui)
    ui.open(fresh)
    finish_task(ui)
    choose_file(ui, "app.txt")
    local checkout = ui.state.session.path
    local function publish(text)
      put(publisher .. "/app.txt", text)
      core.git(publisher, { "add", "app.txt" })
      core.git(publisher, { "commit", "-m", "Update remote PR" })
      fresh.head.sha = vim.trim(core.git(publisher, { "rev-parse", "HEAD" }))
      core.git(publisher, { "push", "origin", "HEAD:refs/pull/3/head", "HEAD:refs/heads/fresh" })
      put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(fresh))
    end
    publish("pulled version\n")
    local previous_head = vim.trim(core.git(checkout, { "rev-parse", "HEAD" }))
    local provider = core.pull_request
    core.pull_request = function(...)
      local result = provider(...)
      api.nvim_buf_set_lines(api.nvim_win_get_buf(ui.state.right), 0, -1, false, { "typed while pulling" })
      return result
    end
    ui.refresh()
    finish_task(ui)
    core.pull_request = provider
    equal(vim.trim(core.git(checkout, { "rev-parse", "HEAD" })), previous_head)
    local edited = api.nvim_win_get_buf(ui.state.right)
    equal(vim.bo[edited].modified, true)
    equal(api.nvim_buf_get_lines(edited, 0, -1, false), { "typed while pulling" })
    api.nvim_buf_set_lines(edited, 0, -1, false, { "new GitHub content" })
    vim.bo[edited].modified = false
    api.nvim_feedkeys(" r", "xt", false)
    finish_task(ui)
    equal(vim.trim(core.git(checkout, { "rev-parse", "HEAD" })), fresh.head.sha)
    equal(ui.state.selected, "app.txt")
    equal(api.nvim_buf_get_lines(api.nvim_win_get_buf(ui.state.right), 0, -1, false), { "pulled version" })
    equal(ui.state.session.behind, 0)
    publish("picker version\n")
    ui.pull_requests(repository, true)
    finish_task(ui)
    ui.open(fresh)
    finish_task(ui)
    choose_file(ui, "app.txt")
    equal(api.nvim_buf_get_lines(api.nvim_win_get_buf(ui.state.right), 0, -1, false), { "picker version" })
    fresh.base.ref, fresh.base.sha = "main", sha("main")
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(fresh))
    vim.cmd("ReviewPull")
    finish_task(ui)
    equal(ui.state.session.base, sha("main"))
    equal(api.nvim_buf_get_lines(api.nvim_win_get_buf(ui.state.left), 0, -1, false), { "base" })
    local original, calls = core.pull_request, 0
    core.pull_request = function(...)
      calls = calls + 1
      return original(...)
    end
    api.nvim_set_current_win(ui.state.right)
    api.nvim_buf_set_lines(0, 0, -1, false, { "saved local edit" })
    vim.cmd("write")
    finish_task(ui)
    equal(calls, 0)
    core.pull_request = original
    local local_head = vim.trim(core.git(checkout, { "rev-parse", "HEAD" }))
    publish("remote after local edit\n")
    ui.refresh()
    finish_task(ui)
    equal(vim.trim(core.git(checkout, { "rev-parse", "HEAD" })), local_head)
    equal(get(checkout .. "/app.txt"), "saved local edit\n")
    assert(ui.state.session.warning:find("Local changes", 1, true))
    core.git(checkout, { "restore", "--source=HEAD", "--", "app.txt" })
    ui.refresh()
    finish_task(ui)
    equal(vim.trim(core.git(checkout, { "rev-parse", "HEAD" })), fresh.head.sha)
    equal(
      api.nvim_buf_get_lines(api.nvim_win_get_buf(ui.state.right), 0, -1, false),
      { "remote after local edit" }
    )
    put(checkout .. "/local-only-refresh.txt", "local commit\n")
    core.git(checkout, { "add", "local-only-refresh.txt" })
    core.git(checkout, { "commit", "-m", "Unpushed local commit" })
    local_head = vim.trim(core.git(checkout, { "rev-parse", "HEAD" }))
    publish("remote diverged\n")
    ui.refresh()
    finish_task(ui)
    equal(vim.trim(core.git(checkout, { "rev-parse", "HEAD" })), fresh.head.sha)
    local backup = assert(ui.state.session.backup, "Diverged local history needs a backup")
    equal(vim.trim(core.git(checkout, { "rev-parse", backup })), local_head)
    equal(core.git(checkout, { "show", backup .. ":local-only-refresh.txt" }), "local commit\n")
    equal(vim.uv.fs_stat(checkout .. "/local-only-refresh.txt"), nil)
    equal(ui.state.session.ahead, 0)
    equal(ui.state.session.behind, 0)
    put(checkout .. "/collision.ignored", "keep ignored data\n")
    put(checkout .. "/another-local.txt", "another local commit\n")
    core.git(checkout, { "add", "another-local.txt" })
    core.git(checkout, { "commit", "-m", "Preserve another local commit" })
    local_head = vim.trim(core.git(checkout, { "rev-parse", "HEAD" }))
    put(publisher .. "/collision.ignored", "remote tracked file\n")
    core.git(publisher, { "add", "--force", "collision.ignored" })
    core.git(publisher, { "commit", "-m", "Track previously ignored file" })
    fresh.head.sha = vim.trim(core.git(publisher, { "rev-parse", "HEAD" }))
    core.git(publisher, { "push", "origin", "HEAD:refs/pull/3/head", "HEAD:refs/heads/fresh" })
    local success = pcall(core.prepare, repository, fresh)
    equal(success, false)
    equal(vim.trim(core.git(checkout, { "rev-parse", "HEAD" })), local_head)
    equal(get(checkout .. "/collision.ignored"), "keep ignored data\n")
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(pr))
    ui.pull_requests(repository)
    finish_task(ui)
  end)

  test("worktree creation is offered only as an explicit fallback", function()
    local ui = require("review.ui")
    local bare = root .. "/fallback.git"
    core.run({ "git", "clone", "--bare", "--shared", repo, bare })
    local clone = { path = bare, common = bare }
    local pending = core.prepare(clone, pr)
    equal(pending.needs_worktree, true)
    local previous, allow, prompts = vim.ui.select, false, 0
    vim.ui.select = function(choices, opts, done)
      prompts = prompts + 1
      equal(choices[1], "Cancel")
      assert(opts.prompt:find(pending.path, 1, true))
      done(allow and "Create worktree" or "Cancel")
    end
    ui.pull_requests(clone, true)
    finish_task(ui)
    ui.open(pr)
    finish_task(ui)
    equal(prompts, 1)
    equal(vim.uv.fs_stat(pending.path), nil)
    equal(#core.worktrees(bare), 1)
    equal(ui.state.session, nil)
    allow = true
    ui.open(pr)
    finish_task(ui)
    equal(prompts, 2)
    equal(vim.uv.fs_realpath(ui.state.session.path), vim.uv.fs_realpath(pending.path))
    equal(#core.worktrees(bare), 2)
    vim.ui.select = previous
    ui.pull_requests(repository, true)
    finish_task(ui)
  end)

  test("picker opens a real editable file beside a read-only merge base", function()
    local ui = require("review.ui")
    ui.start(catalog)
    assert(
      ui.state.loading and api.nvim_win_is_valid(ui.state.loading),
      "Startup must draw its loading dialog before discovery"
    )
    local loading_text =
      table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(ui.state.loading), 0, -1, false), "\n")
    assert(loading_text:find("Finding repositories", 1, true))
    finish_task(ui)
    equal(ui.state.loading, nil)
    ui.pull_requests(repository)
    finish_task(ui)
    vim.fn.maparg("j", "n", false, true).callback()
    equal(ui.state.picker_rows[api.nvim_win_get_cursor(0)[1]].item.number, 3)
    vim.fn.maparg("k", "n", false, true).callback()
    local first = api.nvim_win_get_cursor(0)[1]
    api.nvim_win_set_cursor(0, { first + 1, 3 })
    vim.fn.maparg("<CR>", "n", false, true).callback()
    finish_task(ui)
    assert(ui.state.session, "PR did not open")
    equal(ui.state.session.path, outside)
    equal(#api.nvim_list_wins(), 3)
    choose_file(ui, "app.txt")
    local left = api.nvim_win_get_buf(ui.state.left)
    local right = api.nvim_win_get_buf(ui.state.right)
    equal(vim.bo[left].modifiable, false)
    equal(vim.bo[right].modifiable, true)
    equal(api.nvim_buf_get_name(right), outside .. "/app.txt")
    equal(api.nvim_buf_get_lines(left, 0, -1, false), { "base", "parent" })
    api.nvim_buf_set_lines(right, -1, -1, false, { "edited in review" })
    ui.pull_requests(repository)
    equal(#api.nvim_list_wins(), 3)
    api.nvim_set_current_win(ui.state.right)
    vim.cmd("write")
    finish_task(ui)
    assert(get(outside .. "/app.txt"):find("edited in review", 1, true))
    equal(vim.wo[ui.state.left].diff, true)
    equal(vim.wo[ui.state.right].diff, true)
    ui.pull_requests(repository)
    finish_task(ui)
    equal(#api.nvim_list_wins(), 1)
    equal(ui.state.session, nil)
    ui.refresh()
  end)

  test("instructions preserve unsaved code and close before focusing files", function()
    local ui = require("review.ui")
    ui.open(pr)
    finish_task(ui)
    choose_file(ui, "internal/catalog/item.go")
    local origin, buffer = ui.state.right, api.nvim_get_current_buf()
    local contents = api.nvim_buf_get_lines(buffer, 0, -1, false)
    api.nvim_buf_set_lines(buffer, -1, -1, false, { "unsaved" })
    local cursor = api.nvim_win_get_cursor(origin)
    api.nvim_feedkeys(" i", "xt", false)
    local popup = api.nvim_get_current_win()
    equal(vim.bo[buffer].modified, true)
    equal(vim.wo[popup].diff, false)
    api.nvim_feedkeys(" f", "xt", false)
    equal(api.nvim_get_current_win(), ui.state.list)
    equal(api.nvim_win_is_valid(popup), false)
    equal(vim.bo[buffer].modified, true)
    equal(api.nvim_win_get_cursor(origin), cursor)
    equal(#api.nvim_list_wins(), 3)
    api.nvim_win_call(origin, function()
      vim.cmd("diffupdate")
      equal(vim.fn.diff_hlID(1, 1), 0)
    end)
    vim.cmd("ReviewHelp")
    popup = api.nvim_get_current_win()
    api.nvim_set_current_win(origin)
    assert(vim.wait(1000, function() return not api.nvim_win_is_valid(popup) end, 10))
    equal(api.nvim_get_current_win(), origin)
    api.nvim_buf_set_lines(buffer, 0, -1, false, contents)
    vim.bo[buffer].modified = false
    ui.pull_requests(repository)
    finish_task(ui)
  end)

  test("binary files and symbolic links stay read-only and removed changes clear the view", function()
    put(outside .. "/binary.dat", "binary\0data")
    assert(vim.uv.fs_symlink(repo .. "/parent.txt", outside .. "/link.txt"))
    local ui = require("review.ui")
    ui.open(pr)
    finish_task(ui)
    for _, wanted in ipairs({ "binary.dat", "link.txt", "remove.txt" }) do
      choose_file(ui, wanted)
      equal(vim.bo[api.nvim_win_get_buf(ui.state.right)].modifiable, false)
    end
    equal(get(repo .. "/parent.txt"), "dirty parent worktree\n")
    put(outside .. "/remove.txt", "remove me\n")
    ui.refresh()
    finish_task(ui)
    equal(ui.state.selected, nil)
    equal(api.nvim_buf_get_lines(api.nvim_win_get_buf(ui.state.right), 0, -1, false), { "" })
    put(outside .. "/remove.txt", "restored with changes\n")
    put(outside .. "/old name.txt", "rename me\n")
    local restored, matches = {}, 0
    for _, file in ipairs(core.changes(ui.state.session)) do
      restored[file.path] = file
      if file.path == "remove.txt" then matches = matches + 1 end
    end
    equal(matches, 1)
    equal(restored["remove.txt"].status, "M")
    equal(restored["old name.txt"], nil)
    equal(restored["new name.txt"].status, "A")
    equal(core.original(ui.state.session, restored["new name.txt"]), "")
    ui.pull_requests(repository)
    finish_task(ui)
  end)

  test("nested folders collapse and reopen without changing the file selected for editing", function()
    vim.fn.mkdir(outside .. "/internal/catalog", "p")
    vim.fn.mkdir(outside .. "/internal/store", "p")
    put(outside .. "/internal/store/postgres.go", "package store\n")
    local ui = require("review.ui")
    ui.open(pr)
    finish_task(ui)
    choose_file(ui, "internal/catalog/item.go")
    api.nvim_win_call(ui.state.right, function()
      vim.cmd("diffupdate")
      equal(vim.fn.diff_hlID(1, 1), 0)
      equal(vim.fn.diff_hlID(3, 1), 0)
      assert(vim.fn.diff_hlID(4, 10) ~= 0, "Changed code must remain highlighted")
    end)
    equal(api.nvim_buf_get_name(api.nvim_win_get_buf(ui.state.right)), outside .. "/internal/catalog/item.go")
    api.nvim_set_current_win(ui.state.list)
    vim.fn.maparg("h", "n", false, true).callback()
    local folder = ui.state.tree_rows[api.nvim_win_get_cursor(0)[1]]
    equal(folder.path, "internal/catalog/")
    vim.fn.maparg("<CR>", "n", false, true).callback()
    equal(ui.state.collapsed[folder.path], true)
    for _, row in pairs(ui.state.tree_rows) do
      assert(not row.file or row.file.path ~= "internal/catalog/item.go")
    end
    equal(ui.state.selected, "internal/catalog/item.go")
    ui.refresh()
    finish_task(ui)
    equal(ui.state.collapsed[folder.path], true)
    vim.fn.maparg("l", "n", false, true).callback()
    equal(ui.state.collapsed[folder.path], false)
    choose_file(ui, "internal/catalog/item.go")
    api.nvim_set_current_win(ui.state.right)
    vim.cmd("write")
    finish_task(ui)
    equal(ui.state.selected, "internal/catalog/item.go")
    ui.pull_requests(repository)
    finish_task(ui)
  end)

  test("next marks files viewed, collapses completed folders, and resets edited files", function()
    local ui = require("review.ui")
    ui.open(pr)
    finish_task(ui)
    choose_file(ui, "internal/catalog/item.go")
    local buffer = api.nvim_win_get_buf(ui.state.right)
    local contents = api.nvim_buf_get_lines(buffer, 0, -1, false)
    api.nvim_buf_set_lines(buffer, -1, -1, false, { "unsaved" })
    ui.next_file()
    equal(ui.state.viewed["internal/catalog/item.go"], nil)
    equal(ui.state.selected, "internal/catalog/item.go")
    api.nvim_buf_set_lines(buffer, 0, -1, false, contents)
    vim.bo[buffer].modified = false
    api.nvim_feedkeys(" n", "xt", false)
    finish_task(ui)
    assert(ui.state.viewed["internal/catalog/item.go"])
    equal(ui.state.collapsed["internal/catalog/"], true)
    equal(ui.state.selected, "internal/store/postgres.go")
    ui.next_file()
    finish_task(ui)
    equal(ui.state.collapsed["internal/store/"], true)
    equal(ui.state.collapsed["internal/"], true)
    for _ = 1, #ui.state.files do
      ui.next_file()
      finish_task(ui)
    end
    equal(vim.tbl_count(ui.state.viewed), #ui.state.files)
    local last = ui.state.selected
    ui.next_file()
    finish_task(ui)
    equal(ui.state.selected, last)
    ui.pull_requests(repository)
    finish_task(ui)
    ui.open(pr)
    finish_task(ui)
    equal(vim.tbl_count(ui.state.viewed), #ui.state.files)
    choose_file(ui, "internal/catalog/item.go")
    api.nvim_set_current_win(ui.state.right)
    api.nvim_buf_set_lines(0, -1, -1, false, { "var Enabled = true" })
    vim.cmd("write")
    finish_task(ui)
    equal(ui.state.viewed["internal/catalog/item.go"], nil)
    equal(ui.state.collapsed["internal/catalog/"], false)
    equal(ui.state.collapsed["internal/"], false)
    ui.pull_requests(repository)
    finish_task(ui)
  end)

  test("Back restores review steps and cursor positions while preserving unsaved edits", function()
    local ui = require("review.ui")
    local back_pr = vim.deepcopy(pr)
    back_pr.number = 6
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(back_pr))
    ui.open(back_pr)
    finish_task(ui)
    choose_file(ui, "internal/catalog/item.go")
    api.nvim_win_set_cursor(ui.state.right, { 4, 2 })
    local cursor = api.nvim_win_get_cursor(ui.state.right)
    local old_head = vim.trim(core.git(outside, { "rev-parse", "HEAD" }))
    ui.next_file()
    finish_task(ui)
    ui.next_file()
    finish_task(ui)
    equal(ui.state.collapsed["internal/"], true)
    choose_file(ui, "internal/catalog/item.go")
    ui.next_file()
    finish_task(ui)
    api.nvim_feedkeys(" b", "xt", false)
    finish_task(ui)
    equal(ui.state.selected, "internal/catalog/item.go")
    assert(ui.state.viewed["internal/catalog/item.go"], "Back must preserve a preexisting viewed mark")
    api.nvim_feedkeys(" b", "xt", false)
    finish_task(ui)
    equal(ui.state.selected, "internal/store/postgres.go")
    equal(ui.state.viewed["internal/store/postgres.go"], nil)
    assert(ui.state.viewed["internal/catalog/item.go"])
    equal(ui.state.collapsed["internal/"], false)
    equal(ui.state.collapsed["internal/store/"], false)
    vim.cmd("ReviewBack")
    finish_task(ui)
    equal(ui.state.selected, "internal/catalog/item.go")
    equal(ui.state.viewed["internal/catalog/item.go"], nil)
    equal(ui.state.collapsed["internal/catalog/"], false)
    equal(api.nvim_win_get_cursor(ui.state.right), cursor)
    ui.undo_next()
    finish_task(ui)
    equal(ui.state.selected, "internal/catalog/item.go")
    ui.next_file()
    finish_task(ui)
    local buffer = api.nvim_win_get_buf(ui.state.right)
    local contents = api.nvim_buf_get_lines(buffer, 0, -1, false)
    api.nvim_buf_set_lines(buffer, -1, -1, false, { "var Pending = true" })
    api.nvim_feedkeys(" b", "xt", false)
    finish_task(ui)
    equal(ui.state.selected, "internal/catalog/item.go")
    equal(vim.bo[buffer].modified, true)
    equal(api.nvim_buf_is_loaded(buffer), true)
    equal(api.nvim_buf_get_lines(buffer, -2, -1, false), { "var Pending = true" })
    equal(get(outside .. "/internal/store/postgres.go"), "package store\n")
    equal(vim.trim(core.git(outside, { "rev-parse", "HEAD" })), old_head)
    api.nvim_buf_set_lines(buffer, 0, -1, false, contents)
    vim.bo[buffer].modified = false
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(pr))
    ui.pull_requests(repository)
    finish_task(ui)
  end)

  test("Back handles review completion and keeps history scoped to the PR and comparison base", function()
    local ui = require("review.ui")
    local back_pr = vim.deepcopy(pr)
    back_pr.number = 8
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(back_pr))
    ui.open(back_pr)
    finish_task(ui)
    for _ = 1, #ui.state.files do
      ui.next_file()
      finish_task(ui)
    end
    local last = ui.state.selected
    local steps = #ui.state.history
    ui.next_file()
    finish_task(ui)
    equal(#ui.state.history, steps)
    ui.undo_next()
    finish_task(ui)
    equal(ui.state.selected, last)
    equal(ui.state.viewed[last], nil)
    equal(vim.tbl_count(ui.state.viewed), #ui.state.files - 1)
    ui.next_file()
    finish_task(ui)
    local other = vim.deepcopy(pr)
    other.number, other.head.ref = 9, "fresh"
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(other))
    ui.open(other)
    finish_task(ui)
    local selected = ui.state.selected
    ui.undo_next()
    finish_task(ui)
    equal(ui.state.selected, selected)
    equal(vim.tbl_count(ui.state.viewed), 0)
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(back_pr))
    ui.open(back_pr)
    finish_task(ui)
    ui.undo_next()
    finish_task(ui)
    equal(ui.state.selected, last)
    equal(ui.state.viewed[last], nil)
    back_pr.base.ref, back_pr.base.sha = "main", sha("main")
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(back_pr))
    ui.open(back_pr)
    finish_task(ui)
    equal(#ui.state.history, 0)
    equal(vim.tbl_count(ui.state.viewed), 0)
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(pr))
    ui.pull_requests(repository)
    finish_task(ui)
  end)

  test("canceling commit and push leaves the worktree and index untouched", function()
    local ui = require("review.ui")
    ui.open(pr)
    finish_task(ui)
    local old_head = vim.trim(core.git(outside, { "rev-parse", "HEAD" }))
    local old_status = core.git(outside, { "status", "--porcelain=v1", "-z" })
    local input, select = vim.ui.input, vim.ui.select
    local confirmed = false
    vim.ui.input = function(_, done) done("Review changes") end
    vim.ui.select = function(_, opts, done)
      assert(opts.prompt:find("acme/example:feature-b", 1, true))
      confirmed = true
      done("Cancel")
    end
    vim.cmd("ReviewCommitPush")
    finish_task(ui)
    assert(vim.wait(1000, function() return confirmed end, 10))
    vim.ui.input, vim.ui.select = input, select
    equal(vim.trim(core.git(outside, { "rev-parse", "HEAD" })), old_head)
    equal(core.git(outside, { "status", "--porcelain=v1", "-z" }), old_status)
    ui.pull_requests(repository)
    finish_task(ui)
  end)

  test("commit and push includes all saved changes and leaves the parent worktree alone", function()
    local ui = require("review.ui")
    local old_base = vim.trim(core.run({ "git", "--git-dir=" .. remote, "rev-parse", "feature-a" }))
    local parent_status = git({ "status", "--porcelain=v1", "-z" })
    core.git(outside, { "mv", "app.txt", "renamed app.txt" })
    put(outside .. "/new [literal].txt", "saved addition\n")
    vim.uv.fs_unlink(outside .. "/ahead.txt")
    ui.open(pr)
    finish_task(ui)
    local input, select = vim.ui.input, vim.ui.select
    local calls = 0
    vim.ui.input = function(_, done)
      calls = calls + 1
      done("Apply review edits")
    end
    vim.ui.select = function(_, opts, done)
      assert(opts.prompt:find("acme/example:feature-b", 1, true))
      assert(opts.prompt:find("Apply review edits", 1, true))
      done("Commit and push")
    end
    local buffer = api.nvim_win_get_buf(ui.state.right)
    local contents = api.nvim_buf_get_lines(buffer, 0, -1, false)
    api.nvim_buf_set_lines(buffer, -1, -1, false, { "unsaved" })
    ui.commit_push()
    equal(calls, 0)
    api.nvim_buf_set_lines(buffer, 0, -1, false, contents)
    vim.bo[buffer].modified = false
    api.nvim_feedkeys(" cc", "xt", false)
    finish_task(ui)
    vim.ui.input, vim.ui.select = input, select
    equal(calls, 1)
    equal(core.git(outside, { "status", "--porcelain=v1" }), "")
    local pushed = vim.trim(core.run({ "git", "--git-dir=" .. remote, "rev-parse", "feature-b" }))
    equal(pushed, vim.trim(core.git(outside, { "rev-parse", "HEAD" })))
    equal(core.git(outside, { "show", "HEAD:new [literal].txt" }), "saved addition\n")
    assert(core.git(outside, { "show", "HEAD:renamed app.txt" }):find("unstaged", 1, true))
    local _, removed = core.git(outside, { "cat-file", "-e", "HEAD:ahead.txt" }, true)
    assert(removed ~= 0)
    equal(git({ "status", "--porcelain=v1", "-z" }), parent_status)
    equal(vim.trim(core.run({ "git", "--git-dir=" .. remote, "rev-parse", "feature-a" })), old_base)
  end)

  test("rejected pushes preserve the local commit and retry does not create another commit", function()
    local ui = require("review.ui")
    local publisher = root .. "/publisher"
    core.git(publisher, { "fetch", "origin", "feature-b" })
    core.git(publisher, { "switch", "-c", "remote-advance", "FETCH_HEAD" })
    put(publisher .. "/remote-side.txt", "remote advance\n")
    core.git(publisher, { "add", "remote-side.txt" })
    core.git(publisher, { "commit", "-m", "Advance remote" })
    core.git(publisher, { "push", "origin", "HEAD:refs/heads/feature-b" })
    local remote_head = vim.trim(core.run({ "git", "--git-dir=" .. remote, "rev-parse", "feature-b" }))
    put(outside .. "/retry.txt", "local retry\n")
    local input, select, notify = vim.ui.input, vim.ui.select, vim.notify
    local calls, failure = 0, nil
    vim.ui.input = function(_, done)
      calls = calls + 1
      done("Preserve local commit")
    end
    vim.ui.select = function(_, _, done) done("Commit and push") end
    vim.notify = function(message, level)
      if level == vim.log.levels.ERROR then failure = message end
    end
    ui.commit_push()
    finish_task(ui)
    assert(failure and failure:find("Push failed. Local commit", 1, true))
    assert(failure:find("rejected", 1, true))
    equal(vim.trim(core.run({ "git", "--git-dir=" .. remote, "rev-parse", "feature-b" })), remote_head)
    equal(core.git(outside, { "status", "--porcelain=v1" }), "")
    equal(core.git(outside, { "show", "HEAD:retry.txt" }), "local retry\n")
    core.git(outside, { "fetch", "origin", "feature-b" })
    core.git(outside, { "merge", "--no-edit", "FETCH_HEAD" })
    local merged = vim.trim(core.git(outside, { "rev-parse", "HEAD" }))
    ui.commit_push()
    finish_task(ui)
    vim.ui.input, vim.ui.select, vim.notify = input, select, notify
    equal(calls, 1)
    equal(vim.trim(core.git(outside, { "rev-parse", "HEAD" })), merged)
    equal(vim.trim(core.run({ "git", "--git-dir=" .. remote, "rev-parse", "feature-b" })), merged)
    ui.pull_requests(repository)
    finish_task(ui)
  end)

  test("a fork pushes to its PR source branch even when the local branch has another name", function()
    local fork_remote = root .. "/fork.git"
    core.run({ "git", "init", "--bare", fork_remote })
    git({ "push", fork_remote, child .. ":refs/heads/feature-a" })
    local fork = vim.deepcopy(pr)
    fork.number, fork.head.ref = 4, "feature-a"
    fork.head.repo = { full_name = "fork/example", ssh_url = fork_remote }
    local opened = core.prepare(repository, fork, root .. "/managed")
    equal(opened.branch, "pr-review/4")
    local parent_head = sha("feature-a")
    put(opened.path .. "/fork-only.txt", "fork change\n")
    local pushed = core.commit_and_push(opened, core.commit_plan(opened, fork), "Update fork review")
    equal(vim.trim(core.run({ "git", "--git-dir=" .. fork_remote, "rev-parse", "feature-a" })), pushed)
    equal(sha("feature-a"), parent_head)
    equal(vim.trim(core.run({ "git", "--git-dir=" .. remote, "rev-parse", "feature-a" })), parent_head)
  end)

  test("unresolved merge conflicts cannot be committed by the shortcut", function()
    local publisher = root .. "/publisher"
    put(outside .. "/renamed app.txt", "local conflict\n")
    core.git(outside, { "add", "renamed app.txt" })
    core.git(outside, { "commit", "-m", "Local conflict case" })
    put(publisher .. "/renamed app.txt", "remote conflict\n")
    core.git(publisher, { "add", "renamed app.txt" })
    core.git(publisher, { "commit", "-m", "Remote conflict case" })
    core.git(outside, { "fetch", publisher, "HEAD" })
    local _, conflict = core.git(outside, { "merge", "--no-commit", "FETCH_HEAD" }, true)
    assert(conflict ~= 0)
    local old_head = vim.trim(core.git(outside, { "rev-parse", "HEAD" }))
    local ok, message = pcall(core.commit_plan, session, pr)
    equal(ok, false)
    assert(message:find("Resolve merge conflicts", 1, true))
    equal(vim.trim(core.git(outside, { "rev-parse", "HEAD" })), old_head)
    core.git(outside, { "merge", "--abort" })
  end)

  test("PR navigation reuses recent lists and refresh bypasses the cache", function()
    local ui = require("review.ui")
    local original, calls = core.pull_requests, 0
    core.pull_requests = function(...)
      calls = calls + 1
      return original(...)
    end
    ui.pull_requests(repository, true)
    finish_task(ui)
    ui.pull_requests(repository)
    finish_task(ui)
    equal(calls, 1)
    ui.pull_requests(repository, true)
    finish_task(ui)
    equal(calls, 2)
    ui.state.pr_cache[repository.common].loaded = vim.uv.hrtime() - 31e9
    ui.pull_requests(repository)
    finish_task(ui)
    equal(calls, 3)
    core.pull_requests = original
  end)

  test("typed quit exits all panes and protects unsaved edits unless forced", function()
    for _, scenario in ipairs({ "clean", "dirty", "force" }) do
      local output, code = core.run({
        "nvim",
        "--headless",
        "-n",
        "--noplugin",
        "-i",
        "NONE",
        "-u",
        project_dir .. "init.lua",
        "-l",
        project_dir .. "tests/quit.lua",
        scenario,
      }, project_dir, false)
      assert(code == 0, scenario .. " quit failed: " .. output)
    end
  end)

  local generated_repo = root .. "/generated-example"
  local generated_pr
  test("generated detection respects attributes, headers, locks, deletions, and vendor paths", function()
    core.run({ "git", "init", "--initial-branch=main", generated_repo })
    core.git(generated_repo, { "config", "user.name", "Review Test" })
    core.git(generated_repo, { "config", "user.email", "review-test@example.invalid" })
    core.git(generated_repo, { "config", "commit.gpgsign", "false" })
    local fixtures = {
      ["generated/sqlc.go"] = "// Code generated by sqlc. DO NOT EDIT.\npackage queries\nvar Version = 1\n",
      ["generated/deleted.go"] = "// Code generated by protoc-gen-go. DO NOT EDIT.\npackage api\n",
      ["mixed/client.ts"] = "\239\187\191/* Generated by client generator. DO NOT EDIT. */\nexport const version = 1\n",
      ["mixed/manual.ts"] = "export const version = 1\n",
      ["gen/handwritten.go"] = 'package gen\nvar Example = "Code generated by sqlc. DO NOT EDIT."\n',
      ["override.go"] = "// Code generated by sqlc. DO NOT EDIT.\npackage manual\n",
      ["unset.go"] = "// @generated\npackage manual\n",
      ["forced file.txt"] = "attribute marks this file\n",
      ["package-lock.json"] = '{"lockfileVersion": 3}\n',
      ["checksums/go.sum"] = "example v1.0.0 h1:test\n",
      ["vendor/dependency/file.go"] = "package dependency\n",
      ["vendor/manual.go"] = "package manual\n",
      ["one-line.txt"] = "one line 1\n",
    }
    put(
      generated_repo .. "/.gitattributes",
      'override.go linguist-generated=false\nunset.go -linguist-generated\n"forced file.txt" linguist-generated\n'
        .. "vendor/manual.go linguist-generated=false\none-line.txt linguist-generated=true\nempty.txt linguist-generated\n"
    )
    local paths = { ".gitattributes" }
    for path, text in pairs(fixtures) do
      vim.fn.mkdir(vim.fs.dirname(generated_repo .. "/" .. path), "p")
      put(generated_repo .. "/" .. path, text)
      paths[#paths + 1] = path
    end
    core.git(generated_repo, vim.list_extend({ "add", "--" }, paths))
    core.git(generated_repo, { "commit", "-m", "Generated fixture base" })
    local base = vim.trim(core.git(generated_repo, { "rev-parse", "HEAD" }))
    core.git(generated_repo, { "switch", "-c", "feature" })
    for path, text in pairs(fixtures) do
      if path == "generated/deleted.go" then
        vim.uv.fs_unlink(generated_repo .. "/" .. path)
      else
        put(generated_repo .. "/" .. path, text:gsub("1", "2") .. (path == "one-line.txt" and "" or "\n"))
      end
    end
    core.git(generated_repo, vim.list_extend({ "add", "--" }, paths))
    core.git(generated_repo, { "commit", "-m", "Update generated fixtures" })
    local head = vim.trim(core.git(generated_repo, { "rev-parse", "HEAD" }))
    generated_pr = {
      number = 20,
      title = "Generated changes",
      state = "open",
      head = { ref = "feature", sha = head, repo = project },
      base = { ref = "main", sha = base, repo = project },
    }
    vim.fn.mkdir(generated_repo .. "/nested/vendor/library", "p")
    put(generated_repo .. "/nested/vendor/library/file.txt", "vendored source\n")
    put(generated_repo .. "/empty.txt", "")
    local files = core.changes({ path = generated_repo, base = base })
    local found = {}
    for _, file in ipairs(files) do
      found[file.path] = file.generated
    end
    for _, path in ipairs({
      "generated/sqlc.go",
      "generated/deleted.go",
      "mixed/client.ts",
      "forced file.txt",
      "package-lock.json",
      "checksums/go.sum",
      "vendor/dependency/file.go",
      "vendor/manual.go",
      "nested/vendor/library/file.txt",
      "empty.txt",
    }) do
      equal(found[path], true)
    end
    for _, path in ipairs({ "mixed/manual.ts", "gen/handwritten.go", "override.go", "unset.go" }) do
      equal(found[path], false)
    end
  end)

  test("generated diffs fold both panes and generated-only directories without marking viewed", function()
    local ui = require("review.ui")
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(generated_pr))
    ui.pull_requests(
      { path = generated_repo, common = generated_repo .. "/.git", slug = "acme/example" },
      true
    )
    finish_task(ui)
    ui.open(generated_pr)
    finish_task(ui)
    equal(ui.state.collapsed["generated/"], true)
    equal(ui.state.collapsed["vendor/"], true)
    equal(ui.state.collapsed["nested/vendor/"], true)
    equal(ui.state.collapsed["mixed/"], nil)
    equal(ui.state.collapsed["gen/"], nil)
    equal(vim.tbl_count(ui.state.viewed), 0)
    local function folded(expected)
      for _, window in ipairs({ ui.state.left, ui.state.right }) do
        api.nvim_win_call(window, function() equal(vim.fn.foldclosed(1), expected and 1 or -1) end)
      end
    end
    choose_file(ui, "generated/sqlc.go")
    folded(true)
    local buffer = api.nvim_win_get_buf(ui.state.right)
    local contents = api.nvim_buf_get_lines(buffer, 0, -1, false)
    api.nvim_feedkeys(" g", "xt", false)
    finish_task(ui)
    folded(false)
    api.nvim_set_current_win(ui.state.right)
    vim.cmd("write")
    finish_task(ui)
    folded(false)
    equal(ui.state.collapsed["generated/"], false)
    vim.cmd("ReviewGenerated")
    finish_task(ui)
    folded(true)
    equal(api.nvim_buf_get_lines(buffer, 0, -1, false), contents)
    equal(vim.bo[buffer].modified, false)
    equal(vim.tbl_count(ui.state.viewed), 0)
    for _, path in ipairs({ "one-line.txt", "empty.txt", "generated/deleted.go" }) do
      choose_file(ui, path)
      folded(true)
      vim.cmd("ReviewGenerated")
      finish_task(ui)
      folded(false)
    end
    choose_file(ui, "gen/handwritten.go")
    for _, window in ipairs({ ui.state.left, ui.state.right }) do
      equal(vim.wo[window].foldmethod, "diff")
      equal(vim.wo[window].foldtext, "foldtext()")
    end
    put(vim.env.PR_REVIEW_TEST_PR, vim.json.encode(pr))
    ui.pull_requests(repository, true)
    finish_task(ui)
  end)

  test("diff panes color modified and one-sided lines as old red and new green", function()
    local ui = require("review.ui")
    ui.open(pr)
    finish_task(ui)
    choose_file(ui, "internal/catalog/item.go")
    for _, side in ipairs({ "left", "right" }) do
      local window = ui.state[side]
      local mapping = {}
      for group, target in vim.wo[window].winhighlight:gmatch("([^,:]+):([^,]+)") do
        mapping[group] = target
      end
      api.nvim_win_call(window, function()
        vim.cmd("diffupdate")
        local id = vim.fn.diff_hlID(4, 1)
        local name = vim.fn.synIDattr(id, "name")
        equal(mapping[name], side == "left" and "ReviewDiffRemove" or "ReviewDiffAdd")
      end)
      equal(mapping.DiffAdd, side == "left" and "ReviewDiffRemove" or "ReviewDiffAdd")
      equal(mapping.DiffText, side == "left" and "ReviewDiffOldText" or "ReviewDiffNewText")
      equal(mapping.DiffDelete, "ReviewDiffFiller")
    end
    local function channels(group)
      local bg = api.nvim_get_hl(0, { name = group }).bg
      return math.floor(bg / 65536), math.floor(bg / 256) % 256
    end
    for _, group in ipairs({ "ReviewDiffRemove", "ReviewDiffOldText" }) do
      local red, green = channels(group)
      assert(red > green)
    end
    for _, group in ipairs({ "ReviewDiffAdd", "ReviewDiffNewText" }) do
      local red, green = channels(group)
      assert(green > red)
    end
    ui.pull_requests(repository)
    finish_task(ui)
  end)

  test("installation works from another directory and preserves unrelated commands", function()
    local previous_data, previous_path = vim.env.XDG_DATA_HOME, vim.env.PATH
    vim.env.XDG_DATA_HOME = root .. "/installed app's data"
    vim.env.PR_REVIEW_BIN_DIR = root .. "/installed bin"
    vim.env.PATH = vim.env.PR_REVIEW_BIN_DIR .. ":" .. previous_path
    core.run({ project_dir .. "install" }, root)
    core.run({ project_dir .. "install" }, root)
    put(bin .. "/nvim", '#!/bin/sh\nprintf "%s\\n" "$NVIM_APPNAME" "$PR_REVIEW_DIRECTORY" "$@"\n')
    vim.uv.fs_chmod(bin .. "/nvim", 493)
    local launched = core.run({ "review", catalog }, root)
    assert(launched:find("pr-review\n" .. catalog, 1, true))
    assert(launched:find(vim.env.XDG_DATA_HOME .. "/pr-review/app/init.lua", 1, true))
    local default = core.run({ "review" }, root)
    assert(default:find("pr-review\n" .. root, 1, true))
    put(vim.env.PR_REVIEW_BIN_DIR .. "/review", "unrelated command\n")
    local _, code = core.run({ project_dir .. "install" }, root, true)
    assert(code ~= 0)
    equal(get(vim.env.PR_REVIEW_BIN_DIR .. "/review"), "unrelated command\n")
    vim.uv.fs_unlink(bin .. "/nvim")
    vim.env.XDG_DATA_HOME, vim.env.PATH = previous_data, previous_path
    vim.env.PR_REVIEW_BIN_DIR = nil
  end)
end, debug.traceback)

vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print(string.format("%d tests passed", passed))
