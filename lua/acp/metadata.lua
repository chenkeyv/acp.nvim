local M = {}

local codex_metadata_cache = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "ACP" })
end

local function first_field(source, fields)
	if type(source) ~= "table" then
		return nil
	end

	for _, field in ipairs(fields) do
		local value = source[field]
		if value ~= nil and value ~= vim.NIL and value ~= "" then
			return value
		end
	end
end

local function codex_config_path()
	local codex_home = vim.env.CODEX_HOME
	if codex_home and codex_home ~= "" then
		return vim.fs.joinpath(codex_home, "config.toml")
	end

	return vim.fs.joinpath(vim.fn.expand("~"), ".codex", "config.toml")
end

local function codex_model()
	local ok, lines = pcall(vim.fn.readfile, codex_config_path(), "", 80)
	if not ok then
		return nil
	end

	for _, line in ipairs(lines) do
		local model = line:match('^%s*model%s*=%s*"([^"]+)"')
		if model then
			return model
		end
	end
end

local function decode_codex_models(output)
	local json = output and output:match("({.*)")
	if not json then
		return nil
	end

	local ok, catalog = pcall(vim.json.decode, json)
	return ok and catalog or nil
end

local function normalize_command(command)
	if type(command) == "string" then
		return { command }
	end
	if type(command) == "table" then
		return vim.deepcopy(command)
	end
	return nil
end

local function codex_metadata(adapter)
	local command = normalize_command(adapter.codex_command or { "codex" })
	local model = codex_model()
	local cache_key = ("%s\0%s"):format(table.concat(command or {}, "\0"), model or "")
	if codex_metadata_cache[cache_key] then
		return codex_metadata_cache[cache_key]
	end

	local metadata = { model = model }
	if not command or not command[1] or vim.fn.executable(command[1]) ~= 1 then
		codex_metadata_cache[cache_key] = metadata
		return metadata
	end

	table.insert(command, "debug")
	table.insert(command, "models")
	local ok, result = pcall(function()
		return vim.system(command, { text = true }):wait()
	end)
	if ok and result and result.code == 0 then
		local catalog = decode_codex_models(table.concat({ result.stdout or "", result.stderr or "" }, "\n"))
		for _, entry in ipairs((catalog and catalog.models) or {}) do
			if entry.slug == model then
				metadata.model = entry.slug or model
				metadata.context_window = entry.context_window or entry.model_context_window or entry.max_context_window
				break
			end
		end
	end

	codex_metadata_cache[cache_key] = metadata
	return metadata
end

local function resolve_config_value(value, label)
	if type(value) ~= "function" then
		return value
	end

	local ok, result = pcall(value)
	if ok then
		return result
	end

	notify(("ACP %s resolver failed: %s"):format(label, result), vim.log.levels.WARN)
end

function M.resolve_adapter(adapter)
	local metadata = resolve_config_value(adapter.metadata, "metadata")
	if metadata == "codex" then
		metadata = codex_metadata(adapter)
	end
	if type(metadata) ~= "table" then
		metadata = {}
	end

	return {
		model = first_field(metadata, { "model", "modelId", "model_id", "modelName", "model_name" })
			or resolve_config_value(adapter.model, "model"),
		context_window = first_field(metadata, {
			"model_context_window",
			"contextWindow",
			"context_window",
			"contextWindowSize",
			"context_window_size",
			"maxContextWindow",
			"max_context_window",
		}) or resolve_config_value(adapter.context_window, "context window"),
	}
end

function M.apply_session(state, update)
	local changed = false
	local candidates = { update }
	if type(update) == "table" then
		for _, field in ipairs({ "info", "session", "usage", "tokenUsage", "token_usage" }) do
			if type(update[field]) == "table" then
				table.insert(candidates, update[field])
			end
		end
	end

	for _, candidate in ipairs(candidates) do
		local model = first_field(candidate, { "model", "modelId", "model_id", "modelName", "model_name" })
		local context_window = first_field(candidate, {
			"model_context_window",
			"contextWindow",
			"context_window",
			"contextWindowSize",
			"context_window_size",
			"maxContextWindow",
			"max_context_window",
		})

		if model and model ~= state.model then
			state.model = model
			changed = true
		end
		if context_window and context_window ~= state.context_window then
			state.context_window = context_window
			changed = true
		end
	end

	return changed
end

return M
