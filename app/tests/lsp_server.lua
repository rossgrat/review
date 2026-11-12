local uv = vim.uv
local input, output = uv.new_pipe(false), uv.new_pipe(false)
input:open(0)
output:open(1)
local received, documents, exited = "", {}, false

local function send(message)
  local body = vim.json.encode(message)
  output:write("Content-Length: " .. #body .. "\r\n\r\n" .. body)
end

local function handle(message)
  local log = assert(io.open(vim.env.PR_REVIEW_LSP_TEST_LOG, "a"))
  log:write(vim.json.encode(message), "\n")
  log:close()
  local method, params, result = message.method, message.params or {}, vim.NIL
  if method == "initialize" then
    result = {
      capabilities = {
        textDocumentSync = { openClose = true, change = 1 },
        completionProvider = { triggerCharacters = { "." }, resolveProvider = true },
        hoverProvider = true,
        signatureHelpProvider = { triggerCharacters = { "(", "," } },
        definitionProvider = true,
        referencesProvider = true,
        semanticTokensProvider = {
          legend = { tokenTypes = { "variable" }, tokenModifiers = {} },
          full = true,
        },
      },
    }
  elseif method == "textDocument/didOpen" then
    documents[params.textDocument.uri] = params.textDocument.text
  elseif method == "textDocument/didChange" then
    documents[params.textDocument.uri] = params.contentChanges[#params.contentChanges].text
  elseif method == "textDocument/completion" then
    local lines = vim.split(documents[params.textDocument.uri], "\n", { plain = true })
    local before = lines[params.position.line + 1]:sub(1, params.position.character)
    result = {
      isIncomplete = false,
      items = {
        {
          label = "Process(value string)",
          kind = 3,
          filterText = "Process",
          insertTextFormat = 2,
          textEdit = {
            range = {
              start = {
                line = params.position.line,
                character = params.position.character - #(before:match("[%w_]+$") or ""),
              },
              ["end"] = params.position,
            },
            newText = "Process(${1:value})$0",
          },
          additionalTextEdits = {
            {
              range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 0 } },
              newText = '\nimport "example.test/support"\n',
            },
          },
          documentation = { kind = "markdown", value = "Processes a value." },
        },
      },
    }
  elseif method == "completionItem/resolve" then
    result = params
  elseif method == "textDocument/hover" then
    result = {
      contents = { kind = "markdown", value = "```go\nfunc Process(value string)\n```\nProcesses a value." },
    }
  elseif method == "textDocument/signatureHelp" then
    local lines = vim.split(documents[params.textDocument.uri], "\n", { plain = true })
    local before = lines[params.position.line + 1]:sub(1, params.position.character)
    result = {
      signatures = before:match("%)%s*$") and {} or {
        {
          label = "Process(value string, count int)",
          parameters = { { label = "value string" }, { label = "count int" } },
        },
      },
      activeParameter = before:find(",", 1, true) and 1 or 0,
      activeSignature = 0,
    }
  elseif method == "exit" then
    exited = true
  end
  if method == "textDocument/didOpen" or method == "textDocument/didChange" then
    send({
      jsonrpc = "2.0",
      method = "textDocument/publishDiagnostics",
      params = {
        uri = params.textDocument.uri,
        diagnostics = {
          {
            range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 7 } },
            severity = 1,
            message = "Example error",
          },
          {
            range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 0 } },
            severity = 2,
            message = "Example warning",
          },
        },
      },
    })
  end
  if message.id then send({ jsonrpc = "2.0", id = message.id, result = result }) end
end

input:read_start(function(err, data)
  assert(not err, err)
  if not data then
    exited = true
    return
  end
  received = received .. data
  while true do
    local boundary = received:find("\r\n\r\n", 1, true)
    if not boundary then return end
    local size = tonumber(received:sub(1, boundary):match("Content%-Length:%s*(%d+)"))
    if #received < boundary + 3 + size then return end
    local message = received:sub(boundary + 4, boundary + 3 + size)
    received = received:sub(boundary + 4 + size)
    vim.schedule(function() handle(vim.json.decode(message)) end)
  end
end)
vim.wait(60000, function() return exited end, 10)
