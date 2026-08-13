local M = {}
local version = require("acp.version")

function M.check()
	vim.health.start("acp.nvim")
	local supported, info = version.current()
	if supported then
		vim.health.ok(("Supported Neovim nightly: %s"):format(version.describe(info)))
	else
		vim.health.error(version.error_message(info))
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

	vim.health.start("Tree-sitter chat highlighting")
	local treesitter_ok, treesitter = pcall(require, "acp.treesitter")
	if not treesitter_ok then
		vim.health.error("Could not load ACP Tree-sitter support: " .. tostring(treesitter))
		return
	end
	local status = treesitter.status()
	if status.available and status.up_to_date == false then
		vim.health.warn(
			("ACP parser is installed but does not match this plugin: %s"):format(status.path or "parser/acp"),
			{
				"Run :AcpInstallParser to rebuild it",
			}
		)
	elseif status.available then
		vim.health.ok(("ACP parser loaded: %s"):format(status.path or "runtime parser/acp"))
	elseif status.registered then
		vim.health.warn("ACP parser is registered but not installed", {
			"Run :AcpInstallParser",
			"The chat keeps structural fallback highlighting until the parser is installed",
		})
	else
		vim.health.warn("ACP parser is not installed and nvim-treesitter is unavailable", {
			"Install nvim-treesitter, then run :AcpInstallParser",
			"The chat keeps structural fallback highlighting without it",
		})
	end
end

return M
