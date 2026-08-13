local M = {}

M.provider_id = "acp"
M.filetype = "acp-prompt"

local registered_blink

local function add_unique(items, value)
	if type(value) ~= "string" or value == "" then
		return
	end
	for _, current in ipairs(items) do
		if current == value then
			return
		end
	end
	table.insert(items, value)
end

local function blink()
	local ok, cmp = pcall(require, "blink.cmp")
	return ok and cmp or nil
end

local function normal_buffers()
	local bufnrs = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_loaded(bufnr)
			and vim.bo[bufnr].buflisted
			and vim.bo[bufnr].buftype == ""
			and vim.api.nvim_buf_line_count(bufnr) > 0
		then
			table.insert(bufnrs, bufnr)
		end
	end
	return bufnrs
end

local function is_slash_command(ctx)
	if vim.bo[ctx.bufnr].filetype ~= M.filetype then
		return false
	end
	return ctx.line:sub(1, ctx.cursor[2]):match("^%s*/[^/%s]*$") ~= nil
end

local function patch_path_provider(provider)
	if type(provider) ~= "table" then
		return
	end
	provider.opts = provider.opts or {}
	if not provider._acp_workspace_cwd then
		local fallback = provider.opts.get_cwd
		provider.opts.get_cwd = function(ctx)
			return require("acp.completion").path_cwd(ctx, fallback)
		end
		provider._acp_workspace_cwd = true
	end
	if not provider._acp_hide_slash_commands then
		local fallback = provider.should_show_items
		provider.should_show_items = function(ctx, items)
			if require("acp.completion").is_slash_command(ctx) then
				return false
			end
			return type(fallback) ~= "function" or fallback(ctx, items)
		end
		provider._acp_hide_slash_commands = true
	end
end

local function patch_buffer_provider(provider)
	if type(provider) ~= "table" or provider._acp_loaded_buffers then
		return
	end
	provider.opts = provider.opts or {}
	local fallback = provider.opts.get_bufnrs
	provider.opts.get_bufnrs = function()
		return require("acp.completion").buffer_bufnrs(fallback)
	end
	provider._acp_loaded_buffers = true
end

local function refresh_live_provider()
	local ok, sources = pcall(require, "blink.cmp.sources.lib")
	local provider = ok and sources.providers[M.provider_id] or nil
	if not provider then
		return
	end
	if provider.list then
		provider.list:destroy()
	end
	provider.module = require("acp.completion.source").new()
	provider.list = nil
	provider.resolve_cache = {}
end

local function sync_live_builtin_providers(config)
	local ok, sources = pcall(require, "blink.cmp.sources.lib")
	if not ok then
		return
	end
	local path = sources.providers.path
	if path and path.module and path.module.opts then
		path.module.opts.get_cwd = config.sources.providers.path.opts.get_cwd
		path.config.should_show_items = config.sources.providers.path.should_show_items
	end
	local buffer = sources.providers.buffer
	if buffer and buffer.module and buffer.module.opts then
		buffer.module.opts.get_bufnrs = config.sources.providers.buffer.opts.get_bufnrs
	end
end

function M.setup()
	local cmp = blink()
	if not cmp then
		return false
	end
	if registered_blink ~= cmp then
		local config = require("blink.cmp.config")
		if not config.sources.providers[M.provider_id] then
			cmp.add_source_provider(M.provider_id, {
				name = "Codex",
				module = "acp.completion.source",
				async = true,
				timeout_ms = 300,
				score_offset = 100,
			})
		elseif config.sources.providers[M.provider_id].module == "acp.completion.source" then
			refresh_live_provider()
		end
		patch_path_provider(config.sources.providers.path)
		patch_buffer_provider(config.sources.providers.buffer)
		sync_live_builtin_providers(config)
		registered_blink = cmp
	end
	local sources = require("blink.cmp.sources.lib")
	local registered = sources.per_filetype_provider_ids[M.filetype] or {}
	for _, source in ipairs(M.sources()) do
		if not vim.tbl_contains(registered, source) then
			cmp.add_filetype_source(M.filetype, source)
			table.insert(registered, source)
		end
	end
	return true
end

function M.ensure()
	if registered_blink then
		return true
	end
	return M.setup()
end

function M.sources()
	local sources = { M.provider_id }
	local cmp = blink()
	if not cmp then
		return sources
	end

	local config = require("blink.cmp.config")
	local defaults = config.sources.default
	if type(defaults) == "function" then
		local ok, resolved = pcall(defaults)
		defaults = ok and resolved or {}
	end
	for _, source in ipairs(type(defaults) == "table" and defaults or {}) do
		if source ~= "path" and source ~= "buffer" then
			add_unique(sources, source)
		end
	end
	for _, source in ipairs({ "buffer", "path" }) do
		if config.sources.providers[source] then
			add_unique(sources, source)
		end
	end
	return sources
end

function M.show()
	local cmp = blink()
	if not cmp then
		return false
	end
	M.setup()
	cmp.show({ providers = M.sources() })
	return true
end

function M.path_cwd(ctx, fallback)
	if vim.bo[ctx.bufnr].filetype == M.filetype and vim.b[ctx.bufnr].acp_cwd then
		return vim.b[ctx.bufnr].acp_cwd
	end
	if type(fallback) == "function" then
		return fallback(ctx)
	end
	return vim.fn.expand(("#%d:p:h"):format(ctx.bufnr))
end

function M.buffer_bufnrs(fallback)
	if vim.bo.filetype == M.filetype then
		return normal_buffers()
	end
	if type(fallback) == "function" then
		return fallback()
	end
	return vim.iter(vim.api.nvim_list_wins())
		:map(function(win)
			return vim.api.nvim_win_get_buf(win)
		end)
		:filter(function(buf)
			return vim.bo[buf].buftype ~= "nofile"
		end)
		:totable()
end

M.is_slash_command = is_slash_command

function M.trigger()
	vim.schedule(M.show)
	return ""
end

local function span_available(elements, first, last)
	for _, element in ipairs(elements) do
		local range = element.byteRange
		if first - 1 < range["end"] and last > range.start then
			return false
		end
	end
	return true
end

local function cached_elements(text, items)
	local elements = {}
	for _, item in ipairs(items or {}) do
		local label = item.label
		if type(label) == "string" and (vim.startswith(label, "$") or vim.startswith(label, "@")) then
			local cursor = 1
			while true do
				local first, last = text:find(label, cursor, true)
				if not first then
					break
				end
				local before = first == 1 or text:sub(first - 1, first - 1):match("[%s%p]")
				local after = last == #text or text:sub(last + 1, last + 1):match("[%s,;!?%)%]%}]")
				if before and after and span_available(elements, first, last) then
					table.insert(elements, {
						byteRange = { start = first - 1, ["end"] = last },
						placeholder = label,
					})
				end
				cursor = last + 1
			end
		end
	end
	return elements
end

local function byte_elements(text, items)
	local elements = cached_elements(text, items)
	local cursor = 1
	while true do
		local first, last = text:find("[$@][%w_./:%-]+", cursor)
		if not first then
			break
		end
		local boundary = first == 1 or text:sub(first - 1, first - 1):match("[%s%p]")
		if boundary and span_available(elements, first, last) then
			table.insert(elements, {
				byteRange = { start = first - 1, ["end"] = last },
				placeholder = text:sub(first, last),
			})
		end
		cursor = last + 1
	end
	table.sort(elements, function(left, right)
		return left.byteRange.start < right.byteRange.start
	end)
	return elements
end

local function matched(items, value)
	for _, item in ipairs(items or {}) do
		if item.label == value or item.textEdit and item.textEdit.newText == value then
			return item
		end
	end
end

function M.input(text, cwd)
	local input = {}
	local ok, source = pcall(require, "acp.completion.source")
	if not ok then
		return input, {}
	end
	local special_items = source.cached_special_items()
	local elements = byte_elements(text or "", special_items)
	local structured = {}
	for _, element in ipairs(elements) do
		if element.placeholder:sub(1, 1) == "$" then
			local item = matched(special_items, element.placeholder)
			local data = item and item.data
			if data and data.acp_kind == "skill" and data.path then
				table.insert(input, { type = "skill", name = data.name, path = data.path })
				table.insert(structured, element)
			elseif data and data.acp_kind == "app" then
				table.insert(structured, element)
			end
		else
			local item = matched(special_items, element.placeholder)
			local data = item and item.data
			local path = data and data.acp_kind == "mention" and data.path or element.placeholder:sub(2)
			if not vim.startswith(path, "/") and not path:match("^%a:[/\\]") then
				path = vim.fs.joinpath(cwd or vim.fn.getcwd(), path)
			end
			path = vim.fs.normalize(path)
			if vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1 then
				table.insert(input, { type = "mention", name = vim.fs.basename(path), path = path })
				table.insert(structured, element)
			end
		end
	end
	return input, structured
end

function M.reload()
	local ok, source = pcall(require, "acp.completion.source")
	if ok then
		source.clear_cache()
	end
	local cmp = blink()
	if cmp then
		refresh_live_provider()
	end
end

function M.reset()
	registered_blink = nil
end

M._normal_buffers = normal_buffers

return M
