local M = {}

local cache = {}

local function kinds()
	local ok, types = pcall(require, "blink.cmp.types")
	return ok and types.CompletionItemKind or { Text = 1 }
end

local function response(items)
	return {
		items = items or {},
		is_incomplete_forward = false,
		is_incomplete_backward = false,
	}
end

local function range(ctx, start_col)
	return {
		start = { line = ctx.cursor[1] - 1, character = start_col },
		["end"] = { line = ctx.cursor[1] - 1, character = ctx.cursor[2] },
	}
end

local function token(ctx)
	local before = ctx.line:sub(1, ctx.cursor[2])
	local start, text = before:match("()([%a][%a'-]*)$")
	if not start then
		return nil
	end
	local segment_prefix = before:sub(1, start - 1):match("([^%s]*)$") or ""
	for _, marker in ipairs({ "/", "\\", "$", "@", ":", "." }) do
		if segment_prefix:find(marker, 1, true) then
			return nil
		end
	end
	return { query = text, start_col = start - 1 }
end

local function paths(bufnr)
	local results = {}
	local seen = {}
	local ok, configured = pcall(vim.api.nvim_buf_call, bufnr, function()
		return vim.opt_local.dictionary:get()
	end)
	for _, path in ipairs(ok and configured or {}) do
		for _, expanded in ipairs(vim.fn.glob(vim.fn.expand(path), false, true)) do
			if expanded ~= "" and vim.fn.filereadable(expanded) == 1 and not seen[expanded] then
				seen[expanded] = true
				table.insert(results, expanded)
			end
		end
	end
	if #results == 0 and vim.fn.filereadable("/usr/share/dict/words") == 1 then
		table.insert(results, "/usr/share/dict/words")
	end
	return results
end

local function process(query, dictionary_paths, callback, spawn)
	local escaped = query:gsub("([\\%^%$%.%[%]%*%+%-%?%(%)%{%}%|])", "\\%1")
	local pattern = "^" .. escaped .. "[[:alpha:]'-]+$"
	return (spawn or vim.system)(
		vim.list_extend({
			"rg",
			"--no-config",
			"--no-heading",
			"--no-filename",
			"--color=never",
			"--ignore-case",
			"-m",
			"40",
			pattern,
		}, dictionary_paths),
		{ text = true },
		function(result)
			vim.schedule(function()
				if result.code ~= 0 and result.code ~= 1 then
					callback(nil)
					return
				end
				callback(vim.split(result.stdout or "", "\n", { trimempty = true }))
			end)
		end
	)
end

local function words(bufnr, query, callback, spawn)
	local dictionary_paths = paths(bufnr)
	local key = table.concat(dictionary_paths, "\0")
	if key == "" then
		callback({})
		return function() end
	end
	cache[key] = cache[key] or {}
	local prefix = query:lower()
	if cache[key][prefix] then
		callback(vim.deepcopy(cache[key][prefix]))
		return function() end
	end
	local handle = process(query, dictionary_paths, function(result)
		if result then
			cache[key][prefix] = result
			callback(vim.deepcopy(result))
		else
			callback({})
		end
	end, spawn)
	return function()
		if handle then
			handle:kill(15)
		end
	end
end

local function items(ctx, current, suggestions)
	local query = current.query
	if #query < 2 then
		return {}
	end
	local results = {}
	local edit_range = range(ctx, current.start_col)
	local completion_kinds = kinds()
	local prefix = query:lower()
	local seen = {}
	for _, suggestion in ipairs(suggestions or {}) do
		local lowered = suggestion:lower()
		if lowered:sub(1, #prefix) == prefix and lowered ~= prefix and not seen[lowered] then
			seen[lowered] = true
			table.insert(results, {
				label = suggestion,
				kind = completion_kinds.Text,
				detail = "Dictionary",
				textEdit = { newText = suggestion, range = edit_range },
			})
			if #results == 40 then
				break
			end
		end
	end
	return results
end

function M.new()
	return setmetatable({}, { __index = M })
end

function M:enabled()
	return vim.bo.filetype == "acp-prompt"
end

function M:get_completions(ctx, callback)
	local current = token(ctx)
	if not current or #current.query < 2 then
		callback(response())
		return
	end
	local cancelled = false
	local cancel = words(ctx.bufnr, current.query, function(suggestions)
		if not cancelled then
			callback(response(items(ctx, current, suggestions)))
		end
	end)
	return function()
		cancelled = true
		cancel()
	end
end

function M.clear_cache()
	cache = {}
end

function M:reload()
	M.clear_cache()
end

M._items = items
M._paths = paths
M._process = process
M._token = token
M._words = words

return M
