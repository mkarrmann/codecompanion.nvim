-- Lean init for omnigent unit tests. Unlike scripts/minimal_init.lua this does
-- NOT install tree-sitter parsers (a multi-minute network step) because the
-- omnigent protocol layer (client / sse / events / adapter resolution) is pure
-- Lua and never renders a buffer. Chat-render tests that need tree-sitter should
-- use scripts/minimal_init.lua instead.
vim.cmd([[let &rtp.=','.getcwd()]])
vim.cmd("set rtp+=deps/mini.nvim")
vim.cmd("set rtp+=deps/plenary.nvim")

require("mini.test").setup()

vim.o.termguicolors = true
vim.o.background = "dark"
