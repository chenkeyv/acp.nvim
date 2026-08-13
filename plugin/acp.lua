if vim.g.loaded_acp_nvim then
	return
end

require("acp.version").assert_supported()
vim.g.loaded_acp_nvim = true
require("acp").setup(vim.g.acp_nvim_config or {})
