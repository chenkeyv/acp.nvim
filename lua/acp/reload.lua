local M = {}

local function is_acp_module(name)
	return name == "acp" or name:match("^acp%.") ~= nil
end

local function loaded_modules()
	local modules = {}
	for name, module in pairs(package.loaded) do
		if is_acp_module(name) then
			modules[name] = module
		end
	end
	return modules
end

local function unload_modules()
	local names = {}
	for name in pairs(package.loaded) do
		if is_acp_module(name) then
			table.insert(names, name)
		end
	end
	for _, name in ipairs(names) do
		package.loaded[name] = nil
	end
end

local function restore_modules(modules)
	unload_modules()
	for name, module in pairs(modules) do
		package.loaded[name] = module
	end
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Codex" })
end

local function runtime_files()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	local directory = vim.fs.dirname(vim.fs.normalize(source))
	local files = vim.fn.globpath(directory, "**/*.lua", false, true)
	table.sort(files)
	return files
end

local function validate_files(files)
	if type(files) ~= "table" or #files == 0 then
		return false, "No acp.nvim Lua modules were found"
	end
	for _, path in ipairs(files) do
		local chunk, err = loadfile(path)
		if not chunk then
			return false, ("%s:\n%s"):format(path, err)
		end
	end
	return true
end

local function export_runtime(ui)
	if type(ui._export_runtime) == "function" then
		return ui._export_runtime()
	end
	if type(ui._state) ~= "function" or type(ui._client) ~= "function" then
		return nil, "This acp.nvim version does not expose its live runtime"
	end
	local current_client = ui._client()
	return {
		config = type(ui.get_config) == "function" and ui.get_config() or {},
		client = current_client,
		client_managed = type(current_client) == "table"
			and type(current_client.pending) == "table"
			and type(current_client.line_buffer) == "table",
		state = ui._state(),
	}
end

function M.reload(opts)
	opts = opts or {}
	local valid, validation_err = validate_files(opts._files or runtime_files())
	if not valid then
		local message = ("Reload preflight failed; the current Codex session was preserved:\n%s"):format(validation_err)
		if not opts.silent then
			notify(message, vim.log.levels.ERROR)
		end
		return false, message
	end

	local old_ui = package.loaded["acp.ui"] or require("acp.ui")
	local runtime, export_err = export_runtime(old_ui)
	if not runtime then
		local message = ("Cannot preserve the current Codex session:\n%s"):format(export_err)
		if not opts.silent then
			notify(message, vim.log.levels.ERROR)
		end
		return false, message
	end

	local old_modules = loaded_modules()

	local function rollback(message)
		restore_modules(old_modules)
		if type(old_ui._adopt_runtime) == "function" then
			pcall(old_ui._adopt_runtime, runtime)
		end
		if not opts.silent then
			notify(("Reload failed; the current Codex session was preserved:\n%s"):format(message), vim.log.levels.ERROR)
		end
		return false, message
	end

	unload_modules()
	local loaded, new_ui = pcall(require, "acp.ui")
	if not loaded then
		return rollback(new_ui)
	end
	local root_loaded, root = pcall(require, "acp")
	if not root_loaded then
		return rollback(root)
	end
	if root ~= new_ui or type(new_ui._adopt_runtime) ~= "function" then
		return rollback("The reloaded acp.nvim modules do not support runtime adoption")
	end
	for _, name in ipairs({ "acp.health", "acp.reload" }) do
		local dependency_loaded, dependency_err = pcall(require, name)
		if not dependency_loaded then
			return rollback(dependency_err)
		end
	end

	local adopted, adopt_err = pcall(new_ui._adopt_runtime, runtime)
	if not adopted then
		return rollback(adopt_err)
	end
	if not opts.silent then
		local thread = runtime.state and runtime.state.thread_id
		local suffix = thread and ("; preserved thread " .. thread) or ""
		notify("Reloaded acp.nvim" .. suffix)
	end
	return true, new_ui
end

M._validate_files = validate_files

return M
