local M = {}

local configured = false

local function plugin_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function configure_nvim_treesitter()
	local ok, parsers = pcall(require, "nvim-treesitter.parsers")
	if not ok or type(parsers) ~= "table" then
		return false
	end
	local root = plugin_root()
	parsers.acp = {
		install_info = {
			path = root,
			location = "tree-sitter-acp",
			queries = "queries/acp",
		},
		maintainers = { "@chenkeyv" },
		tier = 1,
	}
	return true
end

local function start_language(bufnr, language)
	if not vim.treesitter or not vim.treesitter.start or not vim.treesitter.language then
		return false
	end
	local ok, available = pcall(vim.treesitter.language.add, language)
	if not ok or available ~= true then
		return false
	end
	local highlighter = vim.treesitter.highlighter
		and vim.treesitter.highlighter.active
		and vim.treesitter.highlighter.active[bufnr]
	if highlighter and highlighter.tree then
		local current_ok, current = pcall(highlighter.tree.lang, highlighter.tree)
		if current_ok and current == language then
			return true
		end
		M.stop(bufnr)
	end
	return pcall(vim.treesitter.start, bufnr, language)
end

function M.setup()
	if configured then
		configure_nvim_treesitter()
		return
	end
	configured = true
	if vim.treesitter and vim.treesitter.language then
		vim.treesitter.language.register("acp", "acp")
	end
	configure_nvim_treesitter()
	local group = vim.api.nvim_create_augroup("AcpTreesitter", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "TSUpdate",
		callback = configure_nvim_treesitter,
	})
end

function M.start(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "unavailable"
	end
	if start_language(bufnr, "acp") then
		return true, "treesitter-acp"
	end
	if start_language(bufnr, "markdown") then
		return true, "treesitter-markdown"
	end
	return false, "fence-detection"
end

function M.stop(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.treesitter or not vim.treesitter.stop then
		return
	end
	pcall(vim.treesitter.stop, bufnr)
end

function M.parser_config()
	local root = plugin_root()
	return {
		path = root,
		location = "tree-sitter-acp",
		queries = "queries/acp",
	}
end

return M
