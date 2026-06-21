if vim.g.loaded_acp_nvim then
	return
end

vim.g.loaded_acp_nvim = true
require("acp").setup()
