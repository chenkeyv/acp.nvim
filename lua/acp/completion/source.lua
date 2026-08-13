local M = {}

local cache = { dollar_items = {}, mention_items = {}, dictionaries = {} }

local commands = {
	{ "permissions", "Set what Codex can do without asking first" },
	{ "ide", "Include open files and editor context" },
	{ "keymap", "Inspect or remap Codex shortcuts" },
	{ "vim", "Toggle Vim mode in the Codex composer" },
	{ "setup-default-sandbox", "Set up the elevated Windows sandbox" },
	{ "sandbox-add-read-dir", "Grant sandbox read access to a directory" },
	{ "agent", "Switch the active agent thread" },
	{ "subagents", "Switch the active agent thread" },
	{ "apps", "Browse apps and insert an app mention" },
	{ "plugins", "Browse installed and discoverable plugins" },
	{ "hooks", "View and manage lifecycle hooks" },
	{ "clear", "Clear the terminal and start a fresh chat" },
	{ "rename", "Rename the current chat" },
	{ "archive", "Archive the current session" },
	{ "delete", "Delete the current session" },
	{ "compact", "Summarize the chat to free context" },
	{ "copy", "Copy the latest completed response" },
	{ "diff", "Show the current Git diff" },
	{ "exit", "Exit Codex" },
	{ "experimental", "Toggle experimental features" },
	{ "approve", "Retry a recent automatic-review denial" },
	{ "memories", "Configure Codex memories" },
	{ "skills", "Browse and use skills" },
	{ "import", "Import supported external-agent setup" },
	{ "feedback", "Send feedback and diagnostics" },
	{ "init", "Generate an AGENTS.md scaffold" },
	{ "logout", "Sign out of Codex" },
	{ "mcp", "List configured MCP servers and tools" },
	{ "mention", "Attach a workspace file" },
	{ "model", "Choose the active model" },
	{ "fast", "Toggle the Fast service tier" },
	{ "plan", "Switch to plan mode" },
	{ "goal", "Set or inspect a persistent goal" },
	{ "personality", "Choose a communication style" },
	{ "ps", "Show background terminals" },
	{ "stop", "Stop background terminals" },
	{ "fork", "Fork the current chat" },
	{ "app", "Continue in the desktop app" },
	{ "side", "Start a temporary side chat" },
	{ "btw", "Start a temporary side chat" },
	{ "raw", "Toggle raw scrollback" },
	{ "resume", "Resume a saved chat" },
	{ "new", "Start a new chat" },
	{ "quit", "Exit Codex" },
	{ "review", "Review the working tree" },
	{ "status", "Show session configuration and usage" },
	{ "usage", "View account token usage" },
	{ "debug-config", "Inspect effective configuration layers" },
	{ "statusline", "Configure Codex status-line fields" },
	{ "title", "Configure the terminal title" },
	{ "theme", "Choose a syntax theme" },
	{ "pets", "Choose or hide a terminal pet" },
	{ "pet", "Choose or hide a terminal pet" },
	{ "threads", "Open recent threads in acp.nvim", local_command = true },
	{ "login", "Sign in to Codex from acp.nvim", local_command = true },
	{ "reload", "Reload acp.nvim without dropping the session", local_command = true },
	{ "reasoning", "Choose the reasoning effort", local_command = true },
}

local function kinds()
	local ok, types = pcall(require, "blink.cmp.types")
	return ok and types.CompletionItemKind
		or {
			Text = 1,
			Function = 3,
			File = 17,
			Folder = 19,
			Reference = 18,
		}
end

local function documentation(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return { kind = "plaintext", value = value }
end

local function response(items, incomplete)
	return {
		items = items or {},
		is_incomplete_forward = incomplete == true,
		is_incomplete_backward = incomplete == true,
	}
end

local function source_client(callback)
	local ok, ui = pcall(require, "acp.ui")
	local client = ok and ui._client and ui._client() or nil
	if
		not client
		or type(client.list_skills) ~= "function"
		or type(client.list_apps) ~= "function"
		or type(client.search_files) ~= "function"
	then
		callback(nil, "Codex app-server is unavailable")
		return false
	end
	return client, nil
end

local function range(ctx, start_col)
	return {
		start = { line = ctx.cursor[1] - 1, character = start_col },
		["end"] = { line = ctx.cursor[1] - 1, character = ctx.cursor[2] },
	}
end

local function command_items(ctx, token)
	local items = {}
	local edit_range = range(ctx, token.start_col)
	local completion_kinds = kinds()
	for index, command in ipairs(commands) do
		table.insert(items, {
			label = "/" .. command[1],
			filterText = "/" .. command[1],
			kind = completion_kinds.Function,
			detail = command.local_command and "acp.nvim command" or "Codex command",
			documentation = documentation(command[2]),
			sortText = (command.local_command and "2" or "1") .. ("%03d"):format(index),
			textEdit = { newText = "/" .. command[1], range = edit_range },
		})
	end
	return items
end

local function skill_items(ctx, token, result)
	local items = {}
	local edit_range = range(ctx, token.start_col)
	local completion_kinds = kinds()
	for _, entry in ipairs(type(result) == "table" and result.data or {}) do
		for _, skill in ipairs(entry.skills or {}) do
			if skill.enabled ~= false then
				local interface = type(skill.interface) == "table" and skill.interface or {}
				table.insert(items, {
					label = "$" .. skill.name,
					filterText = "$" .. skill.name,
					kind = completion_kinds.Reference,
					detail = interface.displayName or skill.scope or "Codex skill",
					documentation = documentation(
						interface.shortDescription or skill.shortDescription or skill.description
					),
					textEdit = { newText = "$" .. skill.name, range = edit_range },
					data = { acp_kind = "skill", name = skill.name, path = skill.path },
				})
			end
		end
	end
	return items
end

local function slug(value)
	return tostring(value or ""):lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
end

local function app_items(ctx, token, apps)
	local items = {}
	local edit_range = range(ctx, token.start_col)
	local completion_kinds = kinds()
	for _, app in ipairs(apps or {}) do
		if app.enabled ~= false and app.callable ~= false then
			local name = app.slug or app.shortName or app.runtimeName or app.name
			local mention = "$" .. slug(name)
			if mention ~= "$" then
				table.insert(items, {
					label = mention,
					filterText = table.concat({ mention, app.name or "", app.id or "" }, " "),
					kind = completion_kinds.Reference,
					detail = app.runtimeName or app.name or "Codex app",
					documentation = documentation(app.description),
					textEdit = { newText = mention, range = edit_range },
					data = { acp_kind = "app", id = app.id, name = app.runtimeName or app.name },
				})
			end
		end
	end
	return items
end

local function update_dollar_cache(items)
	for _, item in ipairs(items) do
		cache.dollar_items[item.label] = vim.deepcopy(item)
	end
end

local function update_mention_cache(items)
	for _, item in ipairs(items) do
		cache.mention_items[item.label] = vim.deepcopy(item)
	end
end

local function file_items(ctx, token, result)
	local items = {}
	local edit_range = range(ctx, token.start_col)
	local completion_kinds = kinds()
	for _, file in ipairs(type(result) == "table" and result.files or {}) do
		local directory = file.match_type == "directory"
		local path = file.path or file.file_name
		if type(path) == "string" and path ~= "" then
			local label = "@" .. path .. (directory and "/" or "")
			table.insert(items, {
				label = label,
				filterText = label,
				kind = directory and completion_kinds.Folder or completion_kinds.File,
				detail = directory and "Workspace directory" or "Workspace file",
				sortText = (directory and "2" or "1") .. ("%010d"):format(9999999999 - (file.score or 0)),
				textEdit = { newText = label, range = edit_range },
				data = {
					acp_kind = "mention",
					name = file.file_name or vim.fs.basename(path),
					path = vim.fs.joinpath(file.root or "", path),
				},
			})
		end
	end
	return items
end

local function dictionary_paths(bufnr)
	local paths = {}
	local seen = {}
	local ok, configured = pcall(vim.api.nvim_buf_call, bufnr, function()
		return vim.opt_local.dictionary:get()
	end)
	for _, path in ipairs(ok and configured or {}) do
		for _, expanded in ipairs(vim.fn.glob(vim.fn.expand(path), false, true)) do
			if expanded ~= "" and vim.fn.filereadable(expanded) == 1 and not seen[expanded] then
				seen[expanded] = true
				table.insert(paths, expanded)
			end
		end
	end
	if #paths == 0 and vim.fn.filereadable("/usr/share/dict/words") == 1 then
		table.insert(paths, "/usr/share/dict/words")
	end
	return paths
end

local function dictionary_process(query, paths, callback, spawn)
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
		}, paths),
		{ text = true },
		function(result)
			vim.schedule(function()
				if result.code ~= 0 and result.code ~= 1 then
					callback(nil)
					return
				end
				local words = vim.split(result.stdout or "", "\n", { trimempty = true })
				callback(words)
			end)
		end
	)
end

local function dictionary_words(bufnr, query, callback, spawn)
	local key = table.concat(dictionary_paths(bufnr), "\0")
	if key == "" then
		callback({})
		return function() end
	end
	cache.dictionaries[key] = cache.dictionaries[key] or {}
	local prefix = query:lower()
	if cache.dictionaries[key][prefix] then
		callback(vim.deepcopy(cache.dictionaries[key][prefix]))
		return function() end
	end
	local handle = dictionary_process(query, dictionary_paths(bufnr), function(words)
		if words then
			cache.dictionaries[key][prefix] = words
			callback(vim.deepcopy(words))
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

local function dictionary_items(ctx, token, words)
	local query = token.query
	if #query < 2 then
		return {}
	end
	local items = {}
	local edit_range = range(ctx, token.start_col)
	local completion_kinds = kinds()
	local prefix = query:lower()
	local seen = {}
	for _, suggestion in ipairs(words or {}) do
		local lowered = suggestion:lower()
		if lowered:sub(1, #prefix) == prefix and lowered ~= prefix and not seen[lowered] then
			seen[lowered] = true
			table.insert(items, {
				label = suggestion,
				kind = completion_kinds.Text,
				detail = "Dictionary",
				textEdit = { newText = suggestion, range = edit_range },
			})
			if #items == 40 then
				break
			end
		end
	end
	return items
end

function M.token(ctx)
	local before = ctx.line:sub(1, ctx.cursor[2])
	local start, text = before:match("^%s*()(/[^%s]*)$")
	if start then
		return { prefix = "/", query = text:sub(2), start_col = start - 1 }
	end
	start, text = before:match("()([$@][^%s$@]*)$")
	if start and (start == 1 or before:sub(start - 1, start - 1):match("[%s%p]")) then
		return { prefix = text:sub(1, 1), query = text:sub(2), start_col = start - 1 }
	end
	start, text = before:match("()([%a][%a'-]*)$")
	if start then
		return { prefix = "word", query = text, start_col = start - 1 }
	end
	return nil
end

function M.new()
	return setmetatable({ pending = {} }, { __index = M })
end

function M:enabled()
	return vim.bo.filetype == "acp-prompt"
end

function M:get_trigger_characters()
	return { "/", "$", "@" }
end

function M:get_completions(ctx, callback)
	local token = M.token(ctx)
	if not token then
		callback(response())
		return
	end
	if token.prefix == "/" then
		callback(response(command_items(ctx, token)))
		return
	end
	if token.prefix == "word" then
		if #token.query < 2 then
			callback(response())
			return
		end
		local cancelled = false
		local cancel = dictionary_words(ctx.bufnr, token.query, function(words)
			if not cancelled then
				callback(response(dictionary_items(ctx, token, words)))
			end
		end)
		return function()
			cancelled = true
			cancel()
		end
	end

	local cancelled = false
	if token.prefix == "$" then
		local pending = 2
		local items = {}
		local function collect(values)
			vim.list_extend(items, values or {})
			pending = pending - 1
			if pending == 0 and not cancelled then
				update_dollar_cache(items)
				callback(response(items))
			end
		end
		local client = source_client(collect)
		if client then
			client:list_skills(vim.b[ctx.bufnr].acp_cwd or vim.fn.getcwd(), function(result)
				collect(skill_items(ctx, token, result))
			end)
			client:list_apps(vim.b[ctx.bufnr].acp_thread_id, function(result)
				collect(app_items(ctx, token, result))
			end)
		else
			collect()
			collect()
		end
	else
		local root = vim.b[ctx.bufnr].acp_cwd or vim.fn.getcwd()
		local client = source_client(function()
			if not cancelled then
				callback(response())
			end
		end)
		if client then
			client:search_files(token.query, { root }, function(result)
				if not cancelled then
					local items = file_items(ctx, token, result)
					update_mention_cache(items)
					callback(response(items))
				end
			end)
		end
	end

	return function()
		cancelled = true
	end
end

M._commands = commands
M._command_items = command_items
M._skill_items = skill_items
M._app_items = app_items
M._file_items = file_items
M._dictionary_items = dictionary_items
M._dictionary_paths = dictionary_paths
M._dictionary_words = dictionary_words
M._dictionary_process = dictionary_process

function M.cached_dollar_items()
	local items = {}
	for _, item in pairs(cache.dollar_items) do
		table.insert(items, vim.deepcopy(item))
	end
	return items
end

function M.cached_special_items()
	local items = M.cached_dollar_items()
	for _, item in pairs(cache.mention_items) do
		table.insert(items, vim.deepcopy(item))
	end
	return items
end

function M.clear_cache()
	cache.dollar_items = {}
	cache.dictionaries = {}
	cache.mention_items = {}
end

function M:reload()
	M.clear_cache()
end

return M
