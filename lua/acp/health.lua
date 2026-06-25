local icons = require("acp.icons")
local metadata = require("acp.metadata")

local M = {}

local function normalize_command(command)
	if type(command) == "string" then
		return { command }
	end
	if type(command) == "table" then
		return vim.deepcopy(command)
	end
	return nil
end

local function command_display(command)
	command = normalize_command(command)
	if not command or not command[1] then
		return nil
	end
	return table.concat(command, " ")
end

local function add(items, level, message)
	table.insert(items, {
		level = level,
		message = message,
	})
end

local function sorted_adapter_names(config)
	local names = vim.tbl_keys((config and config.adapters) or {})
	table.sort(names)
	return names
end

local function command_found(command)
	command = normalize_command(command)
	return command and command[1] and vim.fn.executable(command[1]) == 1
end

local function adapter_items(items, name, adapter, config)
	add(items, "info", ("Adapter: %s"):format(name))
	if type(adapter) ~= "table" then
		add(items, "error", ("Adapter %s is not configured"):format(name))
		return
	end

	local default_adapter = config and config.default_adapter
	local missing_level = name == default_adapter and "error" or "warn"
	local adapter_command = command_display(adapter.command)
	if command_found(adapter.command) then
		add(items, "ok", ("%s adapter command found: %s"):format(name, adapter_command))
	elseif adapter_command then
		add(items, missing_level, ("%s adapter command is missing: %s"):format(name, adapter_command))
	else
		add(items, missing_level, ("%s adapter command is not configured"):format(name))
	end

	local resolved = metadata.resolve_adapter(adapter)
	if resolved.model then
		add(items, "info", ("Prompt metadata model: %s"):format(tostring(resolved.model)))
	end
	if resolved.context_window then
		add(items, "info", ("Prompt metadata context window: %s"):format(tostring(resolved.context_window)))
	end

	if adapter.metadata ~= "codex" then
		return
	end

	local codex_command = command_display(adapter.codex_command or { "codex" })
	if command_found(adapter.codex_command or { "codex" }) then
		add(items, "ok", ("Codex CLI found: %s"):format(codex_command))
	else
		add(items, "warn", ("Codex CLI is missing: %s"):format(codex_command or "codex"))
	end

	local config_path = metadata.codex_config_path()
	if vim.fn.filereadable(config_path) == 1 then
		add(items, "ok", ("Codex config found: %s"):format(config_path))
	else
		add(items, "warn", ("Codex config not found: %s"):format(config_path))
	end

	if not resolved.model then
		add(items, "warn", "Codex model metadata was not resolved")
	end
	if not resolved.context_window then
		add(items, "warn", "Codex context window metadata was not resolved")
	end
end

function M.items(config, opts)
	opts = opts or {}
	local items = {}
	if type(config) ~= "table" then
		add(items, "error", "ACP config is unavailable")
		return items
	end

	if config.default_adapter and not opts.adapter_name then
		if config.adapters and config.adapters[config.default_adapter] then
			add(items, "ok", ("Default adapter: %s"):format(config.default_adapter))
		else
			add(items, "error", ("Default adapter is missing: %s"):format(config.default_adapter))
		end
	end

	local names = opts.adapter_name and { opts.adapter_name } or sorted_adapter_names(config)
	if #names == 0 then
		add(items, "error", "No ACP adapters are configured")
		return items
	end

	for _, name in ipairs(names) do
		adapter_items(items, name, config.adapters and config.adapters[name], config)
	end

	return items
end

local function default_reporter()
	local health = vim.health or {}
	return {
		start = health.start or health.report_start,
		ok = health.ok or health.report_ok,
		warn = health.warn or health.report_warn,
		error = health.error or health.report_error,
		info = health.info or health.report_info,
	}
end

function M.render(items, reporter)
	reporter = reporter or default_reporter()
	if reporter.start then
		reporter.start(icons.title("acp.nvim"))
	end

	for _, item in ipairs(items or {}) do
		local report = reporter[item.level] or reporter.info
		if report then
			report(item.message)
		end
	end
end

function M.check()
	local ok, acp = pcall(require, "acp")
	if not ok or type(acp.get_config) ~= "function" then
		M.render({ {
			level = "error",
			message = "Failed to load acp.nvim config",
		} })
		return
	end

	M.render(M.items(acp.get_config()))
end

function M.notify(config, adapter_name, notify)
	notify = notify or vim.notify
	local levels = {
		ok = vim.log.levels.INFO,
		info = vim.log.levels.INFO,
		warn = vim.log.levels.WARN,
		error = vim.log.levels.ERROR,
	}

	for _, item in ipairs(M.items(config, { adapter_name = adapter_name })) do
		notify(item.message, levels[item.level] or vim.log.levels.INFO, { title = icons.title("ACP") })
	end
end

return M
