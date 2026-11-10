local M = {}

function M.setup()
  vim.o.background = "dark"
  local colors = {
    Normal = { fg = "#c9d1df", bg = "#1b2029" },
    NormalNC = { link = "Normal" },
    EndOfBuffer = { fg = "#1b2029" },
    LineNr = { fg = "#505c70" },
    CursorLineNr = { fg = "#a8b6cb" },
    CursorLine = { bg = "#252d39" },
    WinSeparator = { fg = "#303a49", bg = "#1b2029" },
    WinBar = { fg = "#9aa8bc", bg = "#161b23" },
    WinBarNC = { link = "WinBar" },
    StatusLine = { fg = "#9aa8bc", bg = "#161b23" },
    StatusLineNC = { link = "StatusLine" },
    Visual = { bg = "#354156" },
    Search = { fg = "#e0c68c", bg = "#3d382c" },
    IncSearch = { fg = "#1b2029", bg = "#d9b889" },
    DiffAdd = { bg = "#24382e" },
    DiffDelete = { fg = "#78505a", bg = "#34272e", bold = false },
    DiffChange = { bg = "#282e39" },
    DiffText = { bg = "#414957", bold = false },
    DiffTextAdd = { bg = "#35523e", bold = false },
    ReviewDiffRemove = { bg = "#482832" },
    ReviewDiffAdd = { bg = "#234333" },
    ReviewDiffOldText = { fg = "#ffe2e5", bg = "#743640", bold = false },
    ReviewDiffNewText = { fg = "#dbffe7", bg = "#35664b", bold = false },
    ReviewDiffFiller = { fg = "#505c70", bg = "#202630", bold = false },
    Folded = { fg = "#77849a", bg = "#222a35" },
    Comment = { fg = "#76839a", italic = true },
    String = { fg = "#a9c88a" },
    Number = { fg = "#d9b889" },
    Boolean = { link = "Number" },
    Constant = { link = "Number" },
    Identifier = { fg = "#c9d1df" },
    Function = { fg = "#94b8d4" },
    Statement = { fg = "#b6a0cc" },
    Keyword = { link = "Statement" },
    PreProc = { link = "Statement" },
    Type = { fg = "#91b9b1" },
    Special = { fg = "#d9b889" },
    Delimiter = { fg = "#9aa8bc" },
    ReviewPanel = { fg = "#c9d1df", bg = "#161b23" },
    ReviewTitle = { fg = "#dce3ef", bold = true },
    ReviewFile = { fg = "#c9d1df" },
    ReviewMuted = { fg = "#76839a" },
    ReviewBorder = { fg = "#303a49" },
    ReviewAccent = { fg = "#94b8d4", bold = true },
    ReviewSelection = { bg = "#252f3e" },
    ReviewAdded = { fg = "#a9c88a" },
    ReviewChanged = { fg = "#d9b889" },
    ReviewDeleted = { fg = "#cf929a" },
  }
  for name, attributes in pairs(colors) do
    vim.api.nvim_set_hl(0, name, attributes)
  end
  vim.g.colors_name = "pr-review"
end

return M
