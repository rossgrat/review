local M = {}

function M.rows(files, collapsed)
  local root = { children = {} }
  for _, file in ipairs(files) do
    local node, path = root, ""
    local parts = vim.split(file.path, "/", { plain = true })
    for index, name in ipairs(parts) do
      local directory = index < #parts
      path = path .. name .. (directory and "/" or "")
      local key = (directory and "directory:" or "file:") .. name
      node.children[key] = node.children[key]
        or {
          name = name,
          path = path,
          parent = node.path,
          directory = directory,
          children = {},
          count = 0,
        }
      node = node.children[key]
      node.count = node.count + 1
    end
    node.file = file
  end
  local rows = {}
  local function visit(node, prefix)
    local children = vim.tbl_values(node.children)
    table.sort(children, function(a, b)
      if a.directory ~= b.directory then return a.directory end
      if a.name:lower() == b.name:lower() then return a.name < b.name end
      return a.name:lower() < b.name:lower()
    end)
    for index, child in ipairs(children) do
      local last = index == #children
      local marker = child.directory and (collapsed[child.path] and "▸ " or "▾ ") or ""
      local guide = prefix .. (last and "└─ " or "├─ ")
      child.guides = #guide
      child.text = guide .. marker .. vim.fn.strtrans(child.name) .. (child.directory and "/" or "")
      rows[#rows + 1] = child
      if child.directory and not collapsed[child.path] then
        visit(child, prefix .. (last and "   " or "│  "))
      end
    end
  end
  visit(root, " ")
  return rows
end

return M
