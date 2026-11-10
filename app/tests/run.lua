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
  vim.fn.mkdir(repo .. "/internal/catalog", "p")
  put(
    repo .. "/internal/catalog/item.go",
    'package catalog\n\nfunc Label(name string) string {\n\treturn "Item: " + name\n}\n'
  )
  put(repo .. "/.gitignore", "*.ignored\n")
  git({ "add", "app.txt", "old name.txt", "remove.txt", ".gitignore", "internal/catalog/item.go" })
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
