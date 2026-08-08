local M = {}

function M.check()
	vim.health.start("acp.nvim")
	if vim.fn.has("nvim-0.10") == 1 and vim.system then
		vim.health.ok("Neovim supports vim.system")
	else
		vim.health.error("Neovim 0.10 or newer is required")
	end

	local ok, acp = pcall(require, "acp")
	local config = ok and acp.get_config() or {}
	local command = config.command or { "codex", "app-server" }
	if type(command) == "string" then
		command = { command, "app-server" }
	end
	if command[1] and vim.fn.executable(command[1]) == 1 then
		vim.health.ok(("Codex executable found: %s"):format(command[1]))
	else
		vim.health.error(("Codex executable not found: %s"):format(command[1] or "codex"))
	end

	if type(command) == "table" and vim.tbl_contains(command, "app-server") then
		vim.health.ok("Configured to use codex app-server directly")
	else
		vim.health.warn("The configured command does not include app-server")
	end
end

return M
