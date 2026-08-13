local M = {}

local configured = false

local function plugin_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function parser_source()
	return vim.fs.joinpath(plugin_root(), "tree-sitter-acp", "src", "parser.c")
end

function M.parser_revision()
	local path = parser_source()
	local ok, lines = pcall(vim.fn.readfile, path, "b")
	if not ok or type(lines) ~= "table" then
		return "missing"
	end
	return vim.fn.sha256(table.concat(lines, "\n"))
end

local function parser_definition()
	local root = plugin_root()
	return {
		install_info = {
			path = root,
			location = "tree-sitter-acp",
			queries = "queries/acp",
			revision = M.parser_revision(),
		},
		maintainers = { "@chenkeyv" },
		tier = 1,
	}
end

local function configure_nvim_treesitter()
	local ok, parsers = pcall(require, "nvim-treesitter.parsers")
	if not ok or type(parsers) ~= "table" then
		return false
	end
	local configs = type(parsers.get_parser_configs) == "function" and parsers.get_parser_configs() or parsers
	configs.acp = parser_definition()
	return true
end

local function language_available(language)
	if not vim.treesitter or not vim.treesitter.language or not vim.treesitter.language.add then
		return false, "Tree-sitter is unavailable"
	end
	local ok, available, err = pcall(vim.treesitter.language.add, language)
	if not ok then
		return false, tostring(available)
	end
	if available == true then
		return true
	end
	return false, tostring(err or ("No parser for language %q"):format(language))
end

local function load_installed_language(language)
	local available, err = language_available(language)
	if available then
		return true
	end
	local paths = vim.api.nvim_get_runtime_file(("parser/%s.*"):format(language), false)
	if #paths == 0 then
		local config_ok, config = pcall(require, "nvim-treesitter.config")
		if config_ok and type(config.get_install_dir) == "function" then
			for _, extension in ipairs({ "so", "dylib", "dll" }) do
				local path = vim.fs.joinpath(config.get_install_dir("parser"), language .. "." .. extension)
				if vim.uv.fs_stat(path) then
					table.insert(paths, path)
				end
			end
		end
	end
	for _, path in ipairs(paths) do
		local ok, loaded, load_err = pcall(vim.treesitter.language.add, language, { path = path })
		if ok and loaded == true then
			return true
		end
		err = tostring(ok and load_err or loaded)
	end
	return false, err
end

local function start_language(bufnr, language, known_available)
	if not vim.treesitter or not vim.treesitter.start or not vim.treesitter.language then
		return false
	end
	local available = known_available == true or language_available(language)
	if not available then
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

local function start_acp_buffers()
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_loaded(bufnr)
			and vim.bo[bufnr].filetype == "acp"
			and vim.b[bufnr].acp_language_injection ~= "paused"
		then
			start_language(bufnr, "acp")
		end
	end
end

function M.status()
	local registered = configure_nvim_treesitter()
	local available, err = language_available("acp")
	local paths = vim.api.nvim_get_runtime_file("parser/acp.*", false)
	local installed_revision
	local config_ok, config = pcall(require, "nvim-treesitter.config")
	if config_ok and type(config.get_install_dir) == "function" then
		local revision_path = vim.fs.joinpath(config.get_install_dir("parser-info"), "acp.revision")
		local revision_ok, revisions = pcall(vim.fn.readfile, revision_path)
		if revision_ok and type(revisions) == "table" then
			installed_revision = revisions[1]
		end
	end
	local revision = M.parser_revision()
	return {
		available = available,
		error = available and nil or err,
		registered = registered,
		path = paths[1],
		revision = revision,
		installed_revision = installed_revision,
		up_to_date = available and (not installed_revision or installed_revision == revision),
	}
end

function M.install(callback)
	callback = callback or function() end
	configure_nvim_treesitter()
	local ok, nvim_treesitter = pcall(require, "nvim-treesitter")
	if not ok or type(nvim_treesitter.install) ~= "function" then
		callback(false, "nvim-treesitter is required to compile the ACP parser")
		return false
	end
	local started, task = pcall(nvim_treesitter.install, "acp", { force = true, summary = true })
	if not started or type(task) ~= "table" or type(task.await) ~= "function" then
		callback(false, tostring(task or "Could not start the ACP parser installation"))
		return false
	end
	task:await(function(err, success)
		vim.schedule(function()
			if err or not success then
				callback(false, tostring(err or "ACP parser compilation failed; run :TSLog for details"))
				return
			end
			local available, load_err = load_installed_language("acp")
			if not available then
				callback(false, load_err)
				return
			end
			start_acp_buffers()
			callback(true)
		end)
	end)
	return true
end

local function install_command()
	M.install(function(ok, err)
		if ok then
			vim.notify("ACP Tree-sitter parser installed; chat highlighting refreshed", vim.log.levels.INFO, {
				title = "acp.nvim",
			})
		else
			vim.notify(tostring(err), vim.log.levels.ERROR, { title = "acp.nvim" })
		end
	end)
end

local function register_install_command()
	vim.api.nvim_create_user_command("AcpInstallParser", install_command, {
		force = true,
		desc = "Compile and install the acp.nvim Tree-sitter parser",
	})
end

function M.setup()
	if configured then
		configure_nvim_treesitter()
		register_install_command()
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
	register_install_command()
end

function M.register_commands()
	register_install_command()
end

function M.available()
	return language_available("acp")
end

function M.start(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "unavailable"
	end
	local available = M.available()
	if not available then
		M.stop(bufnr)
		return false, "unavailable"
	end
	if start_language(bufnr, "acp", true) then
		return true, "treesitter-acp"
	end
	M.stop(bufnr)
	return false, "unavailable"
end

function M.stop(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.treesitter or not vim.treesitter.stop then
		return
	end
	pcall(vim.treesitter.stop, bufnr)
end

function M.parser_config()
	return vim.deepcopy(parser_definition().install_info)
end

return M
