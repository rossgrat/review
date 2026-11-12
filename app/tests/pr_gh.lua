local function read(path)
  local file = assert(io.open(path, "rb"))
  local contents = file:read("*a")
  file:close()
  return contents
end
local state = vim.json.decode(read(vim.env.PR_REVIEW_DESCRIPTION_STATE))
local args = {}
for index, value in ipairs(arg) do
  args[index] = value
end
local entry = { args = args }
if args[1] == "pr" and args[2] == "edit" then entry.body = io.stdin:read("*a") end
local log = assert(io.open(vim.env.PR_REVIEW_DESCRIPTION_LOG, "a"))
log:write(vim.json.encode(entry), "\n")
log:close()
if args[1] == "api" then
  assert(args[4] == "repos/example/description/pulls/17", "Wrong PR endpoint")
  io.stdout:write(vim.json.encode(state.pr))
else
  assert(
    args[1] == "pr" and args[3] == "17" and args[4] == "--repo" and args[5] == "example/description",
    "Wrong PR destination"
  )
  if state.fail == args[2] then
    io.stderr:write(args[2] .. " rejected\n")
    vim.cmd("cquit 1")
  end
  if args[2] == "edit" then
    assert(args[6] == "--body-file" and args[7] == "-", "Body must use stdin")
    state.pr.body = entry.body
  elseif args[2] == "ready" then
    state.pr.draft = false
  else
    error("Unexpected GitHub write")
  end
  local file = assert(io.open(vim.env.PR_REVIEW_DESCRIPTION_STATE, "wb"))
  file:write(vim.json.encode(state))
  file:close()
end
