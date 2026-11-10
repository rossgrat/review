local root = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath = { root, vim.env.VIMRUNTIME }
vim.opt.packpath = {}
vim.opt.loadplugins = false
vim.opt.exrc = false
vim.opt.modeline = false
vim.opt.hidden = true
vim.opt.mouse = "a"
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.splitright = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.signcolumn = "no"
vim.opt.laststatus = 3
vim.opt.shortmess:append("I")
vim.opt.diffopt = { "internal", "filler", "closeoff", "algorithm:histogram", "linematch:60", "inline:word" }
vim.opt.fillchars:append({ eob = " ", diff = " " })
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
require("review.theme").setup()
vim.schedule(function() require("review.ui").start(vim.env.PR_REVIEW_DIRECTORY or vim.fn.getcwd()) end)
