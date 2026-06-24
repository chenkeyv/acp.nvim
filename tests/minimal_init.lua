vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.shadafile = "NONE"
vim.env.XDG_STATE_HOME = vim.env.XDG_STATE_HOME or "/tmp/acp.nvim-state"
pcall(vim.fn.mkdir, vim.env.XDG_STATE_HOME, "p")
