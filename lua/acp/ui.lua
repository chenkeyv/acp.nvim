local Connection = require("acp.connection").Connection

local M = {}

local defaults = {
	default_adapter = "codex",
	default_mode = "tab",
	layout = {
		width_ratio = 0.88,
		height_ratio = 0.86,
		input_height = 7,
		session_panel_width = 28,
	},
	adapters = {
		codex = {
			command = { "codex-acp" },
			codex_command = { "codex" },
			auth_method = "chatgpt",
			metadata = "codex",
			timeout_ms = 60000,
			model = nil,
			context_window = nil,
		},
		claude_code = {
			command = { "claude-agent-acp" },
			timeout_ms = 60000,
			model = nil,
			context_window = nil,
		},
	},
}

local config = vim.deepcopy(defaults)
local states = {}
local sessions = {}
local next_session_id = 1
local codex_metadata_cache = {}
local session_panel_lines = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "ACP" })
end

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function set_buf_options(bufnr, opts)
	for key, value in pairs(opts) do
		vim.bo[bufnr][key] = value
	end
end

local function set_output_lines(state, start, stop, lines)
	if not valid_buf(state.output_buf) then
		return
	end

	vim.bo[state.output_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.output_buf, start, stop, false, lines)
	vim.bo[state.output_buf].modifiable = false
end

local function set_panel_lines(bufnr, lines)
	if not valid_buf(bufnr) then
		return
	end

	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
end

local function follow_output(state)
	if not valid_win(state.output_win) or not valid_buf(state.output_buf) then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(state.output_buf)
	pcall(vim.api.nvim_win_set_cursor, state.output_win, { line_count, 0 })
end

local function append_lines(state, lines)
	set_output_lines(state, -1, -1, lines)
	follow_output(state)
end

local function append_text(state, text)
	if not valid_buf(state.output_buf) or not text or text == "" then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(state.output_buf)
	local last = vim.api.nvim_buf_get_lines(state.output_buf, line_count - 1, line_count, false)[1] or ""
	local parts = vim.split(text, "\n", { plain = true })

	if #parts == 1 then
		set_output_lines(state, line_count - 1, line_count, { last .. parts[1] })
		follow_output(state)
		return
	end

	local replacement = { last .. parts[1] }
	for index = 2, #parts do
		table.insert(replacement, parts[index])
	end

	set_output_lines(state, line_count - 1, line_count, replacement)
	follow_output(state)
end

local function sorted_sessions()
	local list = {}
	for _, state in pairs(sessions) do
		if not state.closed then
			table.insert(list, state)
		end
	end

	table.sort(list, function(left, right)
		return left.id < right.id
	end)
	return list
end

local function session_status(state)
	if state.busy then
		return state.run_status or "running"
	end
	return state.run_status or "idle"
end

local function render_session_panel(state)
	if not valid_buf(state.session_panel_buf) then
		return
	end

	local lines = { "Sessions", "" }
	local line_ids = {}
	for _, session in ipairs(sorted_sessions()) do
		local marker = session.id == state.id and ">" or " "
		local model = session.model and session.model ~= "" and (" " .. session.model) or ""
		table.insert(lines, ("%s #%d %s%s"):format(marker, session.id, session.adapter, model))
		line_ids[#lines] = session.id
		table.insert(lines, ("  %s"):format(session_status(session)))
		line_ids[#lines] = session.id
	end

	session_panel_lines[state.session_panel_buf] = line_ids
	set_panel_lines(state.session_panel_buf, lines)
end

local function refresh_session_panels()
	for _, state in pairs(sessions) do
		render_session_panel(state)
	end
end

local function set_run_status(state, status)
	if not valid_buf(state.output_buf) then
		return
	end

	if state.run_status == status then
		return
	end

	local line = ("Status: %s"):format(status)
	local line_count = vim.api.nvim_buf_line_count(state.output_buf)
	if state.run_status_line and state.run_status_line < line_count then
		set_output_lines(state, state.run_status_line, state.run_status_line + 1, { line })
	else
		state.run_status_line = line_count
		set_output_lines(state, -1, -1, { line, "" })
	end

	state.run_status = status
	follow_output(state)
	refresh_session_panels()
end

local function trim(text)
	return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function format_count(value)
	local number = tonumber(value)
	if not number then
		return tostring(value)
	end

	if number >= 1000000 then
		local formatted = number / 1000000
		return formatted % 1 == 0 and ("%dM"):format(formatted) or ("%.1fM"):format(formatted)
	end
	if number >= 1000 then
		local formatted = number / 1000
		return formatted % 1 == 0 and ("%dk"):format(formatted) or ("%.1fk"):format(formatted)
	end
	return tostring(number)
end

local function prompt_title(state)
	local parts = { "Prompt" }
	local metadata = {}

	if state.model and state.model ~= "" then
		table.insert(metadata, state.model)
	end
	if state.context_window then
		table.insert(metadata, ("ctx %s"):format(format_count(state.context_window)))
	end
	if #metadata > 0 then
		table.insert(parts, table.concat(metadata, " "))
	end

	table.insert(parts, "<Enter> newline")
	table.insert(parts, "<C-Enter> send")
	table.insert(parts, "<leader>aq stop")
	return (" %s "):format(table.concat(parts, "  "))
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

local function resolve_adapter_metadata(adapter)
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

local function apply_session_metadata(state, update)
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

local function refresh_prompt_chrome(state)
	if not valid_win(state.input_win) then
		return
	end

	local title = prompt_title(state)
	if state.mode == "window" then
		vim.wo[state.input_win].winbar = title
		return
	end

	local win_config = vim.api.nvim_win_get_config(state.input_win)
	if win_config.relative ~= "" then
		win_config.title = title
		pcall(vim.api.nvim_win_set_config, state.input_win, win_config)
	end
end

local function input_prompt(state)
	if not valid_buf(state.input_buf) then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
	local prompt = trim(table.concat(lines, "\n"))
	if prompt == "" then
		return nil
	end
	return prompt
end

local function clear_input(state)
	if not valid_buf(state.input_buf) then
		return
	end

	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })
	if valid_win(state.input_win) then
		pcall(vim.api.nvim_win_set_cursor, state.input_win, { 1, 0 })
	end
end

local function adapter_names()
	local names = vim.tbl_keys(config.adapters)
	table.sort(names)
	return names
end

local function escape_tabline(text)
	return tostring(text):gsub("%%", "%%%%")
end

local function tab_title(tabpage)
	local ok, title = pcall(vim.api.nvim_tabpage_get_var, tabpage, "acp_title")
	if ok and title and title ~= "" then
		return title
	end

	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		if vim.api.nvim_win_get_config(winid).relative == "" then
			local bufnr = vim.api.nvim_win_get_buf(winid)
			local name = vim.api.nvim_buf_get_name(bufnr)
			return name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
		end
	end

	return "[No Name]"
end

local function set_tab_title(state, title)
	if not state.tabpage or not vim.api.nvim_tabpage_is_valid(state.tabpage) then
		return
	end

	state.title = title
	pcall(vim.api.nvim_tabpage_set_var, state.tabpage, "acp_title", title)
	refresh_session_panels()
end

local function float_layout()
	local columns = vim.o.columns
	local lines = vim.o.lines
	local width = math.max(48, math.floor(columns * config.layout.width_ratio))
	width = math.min(width, math.max(20, columns - 4))

	local total_height = math.max(12, math.floor(lines * config.layout.height_ratio))
	total_height = math.min(total_height, math.max(8, lines - 4))

	local input_height = math.min(config.layout.input_height, math.max(3, total_height - 6))
	local gap = 1
	local output_height = math.max(5, total_height - input_height - gap)
	local row = math.max(0, lines - total_height - 2)
	local col = math.max(0, math.floor((columns - width) / 2))

	return {
		width = width,
		output_height = output_height,
		input_height = input_height,
		output_row = row,
		input_row = row + output_height + gap,
		col = col,
	}
end

local function input_float_config(state)
	local output_config = valid_win(state.output_win) and vim.api.nvim_win_get_config(state.output_win) or {}
	local output_position = valid_win(state.output_win) and vim.api.nvim_win_get_position(state.output_win) or { 0, 0 }
	local columns = vim.o.columns
	local lines = vim.o.lines
	local col = output_config.relative == "" and output_position[2] or 0
	local width = valid_win(state.output_win) and vim.api.nvim_win_get_width(state.output_win)
		or math.max(48, math.floor(columns * config.layout.width_ratio))
	width = math.min(width, math.max(20, columns - col))

	local input_height = math.min(config.layout.input_height, math.max(3, lines - 6))

	return {
		relative = "editor",
		row = math.max(0, lines - input_height - 3),
		col = output_config.relative == "" and col or math.max(0, math.floor((columns - width) / 2)),
		width = width,
		height = input_height,
		style = "minimal",
		border = "rounded",
		title = prompt_title(state),
		title_pos = "left",
		zindex = 50,
	}
end

local function apply_window_options(state)
	for _, winid in ipairs({ state.session_panel_win, state.output_win, state.input_win }) do
		if valid_win(winid) then
			vim.wo[winid].wrap = true
			vim.wo[winid].linebreak = true
			vim.wo[winid].signcolumn = "no"
			vim.wo[winid].number = false
			vim.wo[winid].relativenumber = false
			vim.wo[winid].foldcolumn = "0"
			pcall(function()
				vim.wo[winid].winfixbuf = true
			end)
		end
	end

	if valid_win(state.session_panel_win) then
		vim.wo[state.session_panel_win].wrap = false
		vim.wo[state.session_panel_win].linebreak = false
		vim.wo[state.session_panel_win].cursorline = true
		pcall(function()
			vim.wo[state.session_panel_win].winfixwidth = true
		end)
	end

	if state.mode ~= "float" then
		if valid_win(state.output_win) then
			vim.wo[state.output_win].winbar = (" ACP %s "):format(state.adapter)
		end
		if state.mode == "window" and valid_win(state.input_win) then
			vim.wo[state.input_win].winbar = prompt_title(state)
		end
	end
end

local function apply_float_layout(state)
	local dims = float_layout()

	local output_config = {
		relative = "editor",
		row = dims.output_row,
		col = dims.col,
		width = dims.width,
		height = dims.output_height,
		style = "minimal",
		border = "rounded",
		title = (" ACP %s "):format(state.adapter),
		title_pos = "left",
		zindex = 40,
	}

	local input_config = {
		relative = "editor",
		row = dims.input_row,
		col = dims.col,
		width = dims.width,
		height = dims.input_height,
		style = "minimal",
		border = "rounded",
		title = prompt_title(state),
		title_pos = "left",
		zindex = 50,
	}

	if valid_win(state.output_win) then
		vim.api.nvim_win_set_config(state.output_win, output_config)
	else
		state.output_win = vim.api.nvim_open_win(state.output_buf, false, output_config)
	end

	if valid_win(state.input_win) then
		vim.api.nvim_win_set_config(state.input_win, input_config)
	else
		state.input_win = vim.api.nvim_open_win(state.input_buf, true, input_config)
	end
end

local function apply_window_layout(state)
	if not valid_win(state.output_win) or not valid_win(state.input_win) then
		local total_height = math.max(config.layout.input_height + 6, math.floor(vim.o.lines * 0.45))

		vim.cmd(("botright %dsplit"):format(total_height))
		state.output_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.output_win, state.output_buf)

		vim.cmd(("botright %dsplit"):format(config.layout.input_height))
		state.input_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
	end

	if valid_win(state.input_win) then
		pcall(vim.api.nvim_win_set_height, state.input_win, config.layout.input_height)
	end
end

local function register_session_panel_autocmd(state)
	if not state.group or not valid_buf(state.session_panel_buf) then
		return
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = state.group,
		buffer = state.session_panel_buf,
		callback = function()
			session_panel_lines[state.session_panel_buf] = nil
		end,
	})
end

local function create_session_panel_buffer(state)
	state.session_panel_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(state.session_panel_buf, ("ACP://%s/%d/sessions"):format(state.adapter, state.id))
	set_buf_options(state.session_panel_buf, {
		bufhidden = "wipe",
		buftype = "nofile",
		filetype = "acp-sessions",
		modifiable = true,
		swapfile = false,
	})
	set_panel_lines(state.session_panel_buf, { "Sessions", "" })
	vim.keymap.set("n", "<CR>", function()
		M.select_session()
	end, { buffer = state.session_panel_buf, desc = "Open ACP session" })
	register_session_panel_autocmd(state)
end

local function apply_tab_layout(state)
	if not valid_buf(state.session_panel_buf) then
		create_session_panel_buffer(state)
		states[state.session_panel_buf] = state
	end

	if not valid_win(state.output_win) then
		vim.cmd("tabnew")
		state.tabpage = vim.api.nvim_get_current_tabpage()
		set_tab_title(state, state.title)
		state.output_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.output_win, state.output_buf)
	end

	if not valid_win(state.session_panel_win) and valid_buf(state.session_panel_buf) then
		local output_win = state.output_win
		vim.api.nvim_set_current_win(output_win)
		vim.cmd(("topleft %dvsplit"):format(config.layout.session_panel_width))
		state.session_panel_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.session_panel_win, state.session_panel_buf)
		pcall(vim.api.nvim_win_set_width, state.session_panel_win, config.layout.session_panel_width)
		vim.api.nvim_set_current_win(output_win)
	end

	render_session_panel(state)

	if valid_win(state.input_win) then
		vim.api.nvim_win_set_config(state.input_win, input_float_config(state))
	else
		state.input_win = vim.api.nvim_open_win(state.input_buf, true, input_float_config(state))
	end
end

local function apply_layout(state)
	if not valid_buf(state.output_buf) or not valid_buf(state.input_buf) then
		return
	end

	if state.mode == "tab" then
		apply_tab_layout(state)
	elseif state.mode == "window" then
		apply_window_layout(state)
	else
		apply_float_layout(state)
	end

	apply_window_options(state)
end

local function create_buffers(state)
	create_session_panel_buffer(state)
	state.output_buf = vim.api.nvim_create_buf(false, true)
	state.input_buf = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_buf_set_name(state.output_buf, ("ACP://%s/%d/output"):format(state.adapter, state.id))
	vim.api.nvim_buf_set_name(state.input_buf, ("ACP://%s/%d/input"):format(state.adapter, state.id))

	set_buf_options(state.output_buf, {
		bufhidden = "wipe",
		buftype = "nofile",
		filetype = "acp",
		modifiable = true,
		swapfile = false,
	})
	set_buf_options(state.input_buf, {
		bufhidden = "wipe",
		buftype = "nofile",
		filetype = "markdown",
		swapfile = false,
	})

	vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, {
		("ACP: %s"):format(state.adapter),
		"",
	})
	vim.bo[state.output_buf].modifiable = false
	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })
end

local function unregister(state)
	if not state or state.closed then
		return
	end

	state.closed = true
	state.connection:stop()
	session_panel_lines[state.session_panel_buf] = nil
	states[state.session_panel_buf] = nil
	states[state.output_buf] = nil
	states[state.input_buf] = nil
	sessions[state.id] = nil

	for _, winid in ipairs({ state.session_panel_win, state.output_win, state.input_win }) do
		if valid_win(winid) then
			pcall(vim.api.nvim_win_close, winid, true)
		end
	end

	refresh_session_panels()
end

local function register_autocmds(state)
	local group = vim.api.nvim_create_augroup(("AcpClient%d"):format(state.id), { clear = true })
	state.group = group

	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			if not state.closed then
				apply_layout(state)
			end
		end,
	})

	register_session_panel_autocmd(state)

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = state.output_buf,
		callback = function()
			unregister(state)
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = state.input_buf,
		callback = function()
			unregister(state)
		end,
	})
end

local function register_keymaps(state)
	local send = function()
		M.send()
	end
	local stop = function()
		M.stop()
	end

	for _, bufnr in ipairs({ state.output_buf, state.input_buf }) do
		vim.keymap.set("n", "<leader>as", send, { buffer = bufnr, desc = "Send ACP prompt" })
		vim.keymap.set("n", "<leader>aq", stop, { buffer = bufnr, desc = "Stop ACP agent" })
	end

	vim.keymap.set("i", "<CR>", "<CR>", { buffer = state.input_buf, desc = "Insert newline" })
	vim.keymap.set({ "n", "i" }, "<C-CR>", send, { buffer = state.input_buf, desc = "Send ACP prompt" })
	vim.keymap.set({ "n", "i" }, "<C-s>", send, { buffer = state.input_buf, desc = "Send ACP prompt" })
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

	if vim.o.tabline == "" then
		vim.o.tabline = "%!v:lua.require'acp.ui'.tabline()"
	end

	vim.api.nvim_create_user_command("AcpChat", function(command)
		M.open(command.args ~= "" and command.args or nil, { mode = config.default_mode })
	end, {
		nargs = "?",
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpChatFloat", function(command)
		M.open(command.args ~= "" and command.args or nil, { mode = "float" })
	end, {
		nargs = "?",
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpChatWindow", function(command)
		M.open(command.args ~= "" and command.args or nil, { mode = "window" })
	end, {
		nargs = "?",
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpChatBuffer", function(command)
		M.open(command.args ~= "" and command.args or nil, { mode = "window" })
	end, {
		nargs = "?",
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpChatTab", function(command)
		M.open(command.args ~= "" and command.args or nil, { mode = "tab" })
	end, {
		nargs = "?",
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpSend", function()
		M.send()
	end, {})

	vim.api.nvim_create_user_command("AcpStop", function()
		M.stop()
	end, {})

	vim.api.nvim_create_user_command("AcpSessions", function()
		M.focus_sessions()
	end, {})

	vim.api.nvim_create_user_command("AcpHealth", function(command)
		M.health(command.args ~= "" and command.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return adapter_names()
		end,
	})
end

function M.open(adapter_name, opts)
	opts = opts or {}
	adapter_name = adapter_name or config.default_adapter
	local adapter = config.adapters[adapter_name]
	if not adapter then
		notify(("Unknown ACP adapter: %s"):format(adapter_name), vim.log.levels.ERROR)
		return
	end

	local id = next_session_id
	next_session_id = next_session_id + 1
	local metadata = resolve_adapter_metadata(adapter)

	local state = {
		id = id,
		adapter = adapter_name,
		mode = opts.mode or config.default_mode,
		title = ("ACP %s #%d"):format(adapter_name, id),
		model = metadata.model,
		context_window = metadata.context_window,
		connection = Connection.new({
			adapter = adapter,
			cwd = vim.fn.getcwd(),
		}),
		busy = false,
	}

	create_buffers(state)
	sessions[id] = state
	states[state.session_panel_buf] = state
	states[state.output_buf] = state
	states[state.input_buf] = state
	register_keymaps(state)
	register_autocmds(state)
	apply_layout(state)
	refresh_session_panels()

	vim.api.nvim_set_current_win(state.input_win)
end

local function current_state()
	local bufnr = vim.api.nvim_get_current_buf()
	local state = states[bufnr]
	if not state then
		notify("Current buffer is not an ACP chat", vim.log.levels.WARN)
		return nil
	end
	return state
end

local function focus_session(state)
	if not state or state.closed then
		notify("ACP session is no longer available", vim.log.levels.WARN)
		return
	end

	if state.mode == "tab" and state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage) then
		vim.api.nvim_set_current_tabpage(state.tabpage)
	end

	apply_layout(state)

	if valid_win(state.input_win) then
		vim.api.nvim_set_current_win(state.input_win)
	elseif valid_win(state.output_win) then
		vim.api.nvim_set_current_win(state.output_win)
	end

	refresh_session_panels()
end

function M.select_session()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local id = session_panel_lines[bufnr] and session_panel_lines[bufnr][line]
	if not id then
		return
	end

	focus_session(sessions[id])
end

function M.focus_sessions()
	local state = current_state()
	if not state then
		return
	end

	if state.mode ~= "tab" or not valid_win(state.session_panel_win) then
		if state.mode == "tab" then
			apply_layout(state)
		end
	end

	if state.mode ~= "tab" or not valid_win(state.session_panel_win) then
		notify("This ACP session does not have a sessions panel", vim.log.levels.WARN)
		return
	end

	vim.api.nvim_set_current_win(state.session_panel_win)
end

function M.send()
	local state = current_state()
	if not state then
		return
	end
	if state.busy then
		notify("ACP agent is still responding", vim.log.levels.WARN)
		return
	end

	local prompt = input_prompt(state)
	if not prompt then
		notify("Prompt is empty", vim.log.levels.WARN)
		return
	end

	state.busy = true
	state.streaming = false
	state.run_status = nil
	state.run_status_line = nil

	clear_input(state)
	append_lines(state, { "", "You", "" })
	append_lines(state, vim.split(prompt, "\n", { plain = true }))
	append_lines(state, { "", "Agent", "" })
	set_run_status(state, "starting")
	pcall(vim.cmd, "redraw")

	if not state.connection:ensure_session() then
		state.busy = false
		set_run_status(state, "error: failed to start session")
		return
	end

	set_run_status(state, "running")

	local ok = state.connection:prompt(prompt, {
		message_chunk = function(text)
			if not state.streaming then
				state.streaming = true
				set_run_status(state, "streaming")
			end
			append_text(state, text)
		end,
		thought_chunk = function(text)
			set_run_status(state, "thinking")
			append_lines(state, { "", ("Thought: %s"):format(text), "" })
		end,
		tool_call = function(update)
			set_run_status(state, ("tool: %s"):format(update.title or update.kind or "tool call"))
			append_lines(state, { "", ("Tool: %s"):format(update.title or update.kind or "tool call"), "" })
		end,
		tool_update = function(update)
			set_run_status(state, ("tool: %s"):format(update.status or update.title or "updated"))
			append_lines(state, { "", ("Tool update: %s"):format(update.status or update.title or "updated"), "" })
		end,
		file_written = function(path)
			set_run_status(state, ("wrote %s"):format(vim.fn.fnamemodify(path, ":.")))
			append_lines(state, { "", ("Wrote %s"):format(vim.fn.fnamemodify(path, ":.")), "" })
		end,
		session_info = function(update)
			if update.title and update.title ~= "" then
				set_tab_title(state, update.title)
			end
			if apply_session_metadata(state, update) then
				refresh_prompt_chrome(state)
			end
		end,
		usage = function(update)
			if apply_session_metadata(state, update) then
				refresh_prompt_chrome(state)
			end
		end,
		stderr = function(text)
			append_lines(state, { "", "stderr:" })
			append_lines(state, vim.split(text:gsub("%s+$", ""), "\n", { plain = true }))
			append_lines(state, { "" })
		end,
		done = function(stop_reason)
			state.busy = false
			set_run_status(state, ("stopped: %s"):format(stop_reason or "done"))
			if valid_win(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
		end,
		error = function(message)
			state.busy = false
			set_run_status(state, ("error: %s"):format(message))
			if valid_win(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
		end,
	})

	if not ok then
		state.busy = false
		set_run_status(state, "error: failed to send prompt")
	end
end

function M.health(adapter_name)
	adapter_name = adapter_name or config.default_adapter
	local adapter = config.adapters[adapter_name]
	if not adapter then
		notify(("Unknown ACP adapter: %s"):format(adapter_name), vim.log.levels.ERROR)
		return
	end

	local command = adapter.command and adapter.command[1]
	if command and vim.fn.executable(command) == 1 then
		notify(("%s adapter command found: %s"):format(adapter_name, table.concat(adapter.command, " ")))
	else
		notify(
			("%s adapter command is missing: %s"):format(adapter_name, table.concat(adapter.command or {}, " ")),
			vim.log.levels.WARN
		)
	end
end

function M.stop()
	local state = current_state()
	if not state then
		return
	end
	state.connection:stop()
	state.busy = false
	set_run_status(state, "stopped")
	notify("Stopped ACP agent")
end

function M.tabline()
	local parts = {}
	local current = vim.api.nvim_get_current_tabpage()

	for index, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
		local highlight = tabpage == current and "%#TabLineSel#" or "%#TabLine#"
		local title = escape_tabline(tab_title(tabpage))
		table.insert(parts, ("%s%%%dT %d:%s "):format(highlight, index, index, title))
	end

	table.insert(parts, "%#TabLineFill#%T")
	return table.concat(parts)
end

return M
