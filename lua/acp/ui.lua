local Codex = require("acp.codex").Client
local action = require("acp.action")
local blocks = require("acp.blocks")
local composer = require("acp.composer")
local context = require("acp.context")
local instructions = require("acp.instructions")
local output_ui = require("acp.output_ui")
local reloader = require("acp.reload")
local render = require("acp.render")
local requests = require("acp.requests")
local server_log = require("acp.server_log")
local treesitter = require("acp.treesitter")
local view = require("acp.view")

local M = {}

local defaults = {
	command = { "codex", "app-server" },
	timeout_ms = 30000,
	model = nil,
	reasoning_effort = nil,
	personality = nil,
	service_tier = nil,
	approval_policy = nil,
	sandbox = nil,
	auto_context = true,
	follow_up = "queue",
	review_delivery = "inline",
	thread_sources = { "cli", "vscode", "appServer" },
	max_threads = 100,
	window = {
		input_height = 6,
		input_padding = 2,
		instruction_height = 4,
		sessions_width = 30,
	},
	performance = {
		stream_interval_ms = 25,
		semantic_debounce_ms = 200,
		cursor_interval_ms = 16,
	},
}

local config = vim.deepcopy(defaults)
local setup_opts = {}
local client
local client_managed = false
local state

local select_model
local select_reasoning
local open_threads
local refresh_threads
local start_review
local compact_thread
local show_status
local drain_queue
local sync_composer
local refresh_composer
local flush_output_text
local flush_action_output

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_tab(tabpage)
	return tabpage and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function present(value)
	return value ~= nil and value ~= vim.NIL
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Codex" })
end

local function current_cwd()
	if type(config.cwd) == "function" then
		local ok, value = pcall(config.cwd)
		if ok and type(value) == "string" and value ~= "" then
			return vim.fs.normalize(value)
		end
	elseif type(config.cwd) == "string" and config.cwd ~= "" then
		return vim.fs.normalize(config.cwd)
	end
	return vim.fs.normalize(vim.fn.getcwd())
end

local function fresh_state(cwd)
	return {
		cwd = cwd or current_cwd(),
		model = config.model,
		effort = config.reasoning_effort,
		personality = config.personality,
		service_tier = config.service_tier,
		thread_id = nil,
		turn_id = nil,
		busy = false,
		starting = false,
		start_waiters = {},
		status = "new chat",
		contexts = {},
		queue = {},
		pending_instructions = {},
		instruction_sequence = 0,
		diff = "",
		streamed_items = {},
		items = {},
		agent_item = nil,
		agent_block_id = nil,
		plan_item = nil,
		plan_block_id = nil,
		models = nil,
		threads = nil,
		threads_error = nil,
		threads_loading = false,
		thread_waiters = {},
		thread_rows = {},
		prompt_chrome_key = nil,
		composer_layout_pending = false,
		pending_output_text = nil,
		output_text_scheduled = false,
		output_text_generation = 0,
		pending_output_block_id = nil,
		pending_action_output = {},
		action_output_scheduled = false,
		action_output_generation = 0,
		cursor_update_pending = false,
		output_position_mode = "normal",
		output_position_view = false,
		output_position_syncing = false,
		output_winbar = nil,
		chat = blocks.new(),
		tokens = nil,
	}
end

local function apply_state_defaults(value)
	if type(value) ~= "table" then
		return value
	end
	for key, default in pairs(fresh_state(value.cwd)) do
		if value[key] == nil then
			value[key] = default
		end
	end
	value.prompt_layout_pending = nil
	value._position_prompt = nil
	value.prompt_reserved_rows = nil
	value.prompt_spacer_rows = nil
	return instructions.normalize(value)
end

local function with_modifiable(bufnr, callback)
	if not valid_buf(bufnr) then
		return
	end
	local modifiable = vim.bo[bufnr].modifiable
	vim.bo[bufnr].modifiable = true
	local ok, err = pcall(callback)
	vim.bo[bufnr].modifiable = modifiable
	if not ok then
		error(err)
	end
end

local function output_content_line_count()
	if not state or not valid_buf(state.output_buf) then
		return 1
	end
	return math.max(1, vim.api.nvim_buf_line_count(state.output_buf))
end

local function at_output_bottom()
	if not state or not valid_win(state.output_win) or not valid_buf(state.output_buf) then
		return false
	end
	local cursor = vim.api.nvim_win_get_cursor(state.output_win)[1]
	return cursor >= output_content_line_count() - 2
end

local function reset_output_position(mode)
	if not state then
		return
	end
	state.output_position_mode = mode or "normal"
	state.output_position_view = false
	state.output_position_syncing = false
end

local function current_output_view()
	if not state or not valid_win(state.output_win) then
		return nil
	end
	local ok, saved_view = pcall(vim.api.nvim_win_call, state.output_win, function()
		return vim.fn.winsaveview()
	end)
	return ok and saved_view or nil
end

local function same_output_view(actual, expected)
	if type(actual) ~= "table" or type(expected) ~= "table" then
		return false
	end
	for _, key in ipairs({ "lnum", "col", "topline", "topfill", "leftcol", "skipcol" }) do
		if actual[key] ~= expected[key] then
			return false
		end
	end
	return true
end

local function output_position_synced()
	return state
		and state.output_position_mode == "center"
		and same_output_view(current_output_view(), state.output_position_view)
end

local function center_output_position()
	if not state or not valid_win(state.output_win) or not valid_buf(state.output_buf) then
		return false
	end
	state.output_position_mode = "center"
	state.output_position_syncing = true
	local saved_view = view.center_output(state.output_win, output_content_line_count())
	state.output_position_syncing = false
	if not saved_view then
		reset_output_position()
		return false
	end
	state.output_position_view = saved_view
	return true
end

local function leave_centered_output_if_moved()
	if
		state
		and state.output_position_mode == "center"
		and not state.output_position_syncing
		and not output_position_synced()
	then
		reset_output_position("manual")
	end
end

local function follow_output(should_follow)
	if not should_follow or not valid_win(state.output_win) or not valid_buf(state.output_buf) then
		return
	end
	if state.output_position_mode == "center" then
		center_output_position()
		return
	end
	pcall(vim.api.nvim_win_set_cursor, state.output_win, { output_content_line_count(), 0 })
end

local function performance_delay(name, fallback)
	local performance = type(config.performance) == "table" and config.performance or {}
	return math.max(0, tonumber(performance[name]) or fallback)
end

local function refresh_output_view(start_row, deferred, end_row)
	if not state or not valid_buf(state.output_buf) then
		return
	end
	view.refresh_transcript(state.output_buf, start_row, state.chat, end_row)
	if deferred then
		output_ui.schedule_refresh(state, performance_delay("semantic_debounce_ms", 200))
	else
		output_ui.flush_refresh(state)
	end
end

local function cancel_output_text()
	if not state then
		return
	end
	state.pending_output_text = nil
	state.pending_output_block_id = nil
	state.output_text_scheduled = false
	state.output_text_generation = (state.output_text_generation or 0) + 1
end

local function cancel_action_output()
	if not state then
		return
	end
	state.pending_action_output = {}
	state.action_output_scheduled = false
	state.action_output_generation = (state.action_output_generation or 0) + 1
end

local function set_output(lines, opts)
	if not state or not valid_buf(state.output_buf) then
		return
	end
	opts = opts or {}
	local saved_view
	if opts.preserve_view and valid_win(state.output_win) then
		saved_view = vim.api.nvim_win_call(state.output_win, function()
			return vim.fn.winsaveview()
		end)
	end
	cancel_output_text()
	cancel_action_output()
	output_ui.pause_language_injection(state)
	with_modifiable(state.output_buf, function()
		vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, lines)
	end)
	refresh_output_view(0)
	if saved_view and valid_win(state.output_win) then
		vim.api.nvim_win_call(state.output_win, function()
			vim.fn.winrestview(saved_view)
		end)
	else
		follow_output(true)
	end
end

local function set_chat(model)
	if not state then
		return
	end
	state.chat = blocks.adopt(model)
	if valid_buf(state.output_buf) then
		blocks.bind(state.output_buf, state.chat)
		set_output(state.chat:render_lines())
	end
end

local function apply_chat_operation(operation)
	if not state or not valid_buf(state.output_buf) or type(operation) ~= "table" then
		return
	end
	if state.output_position_mode == "center" and not output_position_synced() then
		reset_output_position("manual")
	end
	local follow = state.output_position_mode == "center"
		or (state.output_position_mode ~= "manual" and at_output_bottom())
	local manual_view = state.output_position_mode == "manual" and current_output_view() or nil
	local start_row = math.max(0, tonumber(operation.start_row) or 0)
	local end_row = math.max(start_row, tonumber(operation.end_row) or start_row)
	output_ui.pause_language_injection(state)
	with_modifiable(state.output_buf, function()
		vim.api.nvim_buf_set_lines(state.output_buf, start_row, end_row, false, operation.lines or {})
	end)
	local refresh_end = operation.block and operation.block.line2 + 1 or nil
	refresh_output_view(start_row, true, refresh_end)
	if manual_view and valid_win(state.output_win) then
		pcall(vim.api.nvim_win_call, state.output_win, function()
			vim.fn.winrestview(manual_view)
		end)
	else
		follow_output(follow)
	end
end

flush_output_text = function()
	if not state then
		return
	end
	local text = state.pending_output_text
	local block_id = state.pending_output_block_id
	state.pending_output_text = nil
	state.pending_output_block_id = nil
	state.output_text_scheduled = false
	state.output_text_generation = (state.output_text_generation or 0) + 1
	if text and text ~= "" and state.chat then
		apply_chat_operation(state.chat:append_text(block_id, text))
	end
end

flush_action_output = function()
	if not state then
		return
	end
	local pending = state.pending_action_output or {}
	state.pending_action_output = {}
	state.action_output_scheduled = false
	state.action_output_generation = (state.action_output_generation or 0) + 1
	for item_id, delta in pairs(pending) do
		if delta ~= "" and state.chat then
			local operation = state.chat:append_command_output(item_id, delta)
			apply_chat_operation(operation)
		end
	end
end

local function append_text(block_id, text)
	if not state or not valid_buf(state.output_buf) or not text or text == "" then
		return
	end
	if state.pending_output_block_id and state.pending_output_block_id ~= block_id then
		flush_output_text()
	end
	output_ui.pause_language_injection(state)
	state.pending_output_text = (state.pending_output_text or "") .. text
	state.pending_output_block_id = block_id
	if state.output_text_scheduled then
		return
	end
	state.output_text_scheduled = true
	state.output_text_generation = (state.output_text_generation or 0) + 1
	local generation = state.output_text_generation
	local scheduled_state = state
	vim.defer_fn(function()
		if state ~= scheduled_state or scheduled_state.output_text_generation ~= generation then
			return
		end
		scheduled_state.output_text_scheduled = false
		flush_output_text()
	end, performance_delay("stream_interval_ms", 25))
end

local function append_action_output(item_id, delta)
	if not state or not valid_buf(state.output_buf) or not item_id or not delta or delta == "" then
		return
	end
	state.pending_action_output = state.pending_action_output or {}
	state.pending_action_output[item_id] = (state.pending_action_output[item_id] or "") .. delta
	if state.action_output_scheduled then
		return
	end
	state.action_output_scheduled = true
	state.action_output_generation = (state.action_output_generation or 0) + 1
	local generation = state.action_output_generation
	local scheduled_state = state
	vim.defer_fn(function()
		if state ~= scheduled_state or scheduled_state.action_output_generation ~= generation then
			return
		end
		scheduled_state.action_output_scheduled = false
		flush_action_output()
	end, performance_delay("stream_interval_ms", 25))
end

local function append_chat_block(callback)
	if not state or not state.chat then
		return nil
	end
	flush_output_text()
	flush_action_output()
	local operation, block = callback(state.chat)
	apply_chat_operation(operation)
	return block
end

local function append_notice(kind, message, opts)
	return append_chat_block(function(chat)
		return chat:add_notice(kind, message, opts)
	end)
end

local function input_text()
	if not state or not valid_buf(state.input_buf) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n")
end

local function set_input(text)
	if not state or not valid_buf(state.input_buf) then
		return
	end
	local lines = vim.split(text or "", "\n", { plain = true })
	vim.bo[state.input_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, lines)
	vim.bo[state.input_buf].modifiable = true
end

local function set_sessions(lines)
	if not state or not valid_buf(state.sessions_buf) then
		return
	end
	with_modifiable(state.sessions_buf, function()
		vim.api.nvim_buf_set_lines(state.sessions_buf, 0, -1, false, lines)
	end)
end

local function session_entries()
	local entries = {}
	local listed_current
	for _, thread in ipairs(state.threads or {}) do
		if state.thread_id and thread.id == state.thread_id then
			listed_current = thread
		else
			table.insert(entries, { thread = thread, current = false })
		end
	end

	local current
	if state.thread_id then
		current = vim.tbl_extend(
			"force",
			{},
			state.current_thread or {},
			listed_current or {},
			{ id = state.thread_id, cwd = state.cwd }
		)
		if
			(not present(current.name) or current.name == "")
			and (not present(current.preview) or current.preview == "")
		then
			current.preview = "Current session"
		end
	else
		current = { preview = "New chat", cwd = state.cwd }
	end
	table.insert(entries, 1, { thread = current, current = true })
	return entries
end

local function render_sessions()
	if not state or not valid_buf(state.sessions_buf) then
		return
	end
	local lines = {}
	local rows = {}
	for _, entry in ipairs(session_entries()) do
		local marker = entry.current and "*" or " "
		table.insert(lines, ("%s %s"):format(marker, render.thread_label(entry.thread)))
		rows[#lines] = entry
	end
	state.thread_rows = rows
	state.sessions_count = #rows
	set_sessions(lines)
end

local function update_output_winbar()
	if not state or not valid_win(state.output_win) then
		return
	end
	local winbar = view.chat_winbar(state)
	if state.output_winbar ~= winbar or vim.wo[state.output_win].winbar ~= winbar then
		vim.wo[state.output_win].winbar = winbar
		state.output_winbar = winbar
	end
end

local function update_chrome()
	if not state then
		return
	end
	local status = tostring(state.status or ""):lower()
	local spinner_active = valid_win(state.input_win)
		and (state.busy or state.starting or status == "stopping")
		and not status:find("error", 1, true)
		and status ~= "disconnected"
	instructions.sync_spinner(state, spinner_active, refresh_composer)
	update_output_winbar()
	if composer.is_open(state, state.output_host_win) and sync_composer then
		sync_composer()
	end
	if valid_win(state.sessions_win) then
		local count = state.sessions_count or 1
		vim.wo[state.sessions_win].winbar = view.sessions_winbar(count, state.threads_loading, state.cwd)
	end
end

local function set_status(status)
	if not state then
		return
	end
	if state.status == status then
		return
	end
	state.status = status
	update_chrome()
end

local function add_pending_instruction(kind, envelope)
	local instruction = instructions.add(state, kind, envelope)
	update_chrome()
	return instruction
end

local function remove_pending_instruction(id, refresh)
	if not state or not present(id) then
		return false
	end
	local changed = instructions.remove(state, id)
	if changed and refresh ~= false then
		update_chrome()
	end
	return changed
end

local function clear_pending_instructions(kind, refresh)
	if not state then
		return false
	end
	local changed = instructions.clear(state, kind)
	if changed and refresh ~= false then
		update_chrome()
	end
	return changed
end

local function consume_steering_instructions()
	if instructions.consume_steers(state) then
		update_chrome()
	end
end

local function remember_source(bufnr, winid)
	if valid_buf(bufnr) and vim.bo[bufnr].buftype == "" then
		state.source_buf = bufnr
		state.source_win = winid
	end
end

local function close_window(winid)
	if valid_win(winid) then
		pcall(vim.api.nvim_win_close, winid, true)
	end
end

local function close_tab(tabpage, return_win)
	if not valid_tab(tabpage) or #vim.api.nvim_list_tabpages() <= 1 then
		return false
	end
	vim.api.nvim_set_current_tabpage(tabpage)
	local closed = pcall(vim.cmd, "tabclose!")
	if valid_win(return_win) then
		pcall(vim.api.nvim_set_current_win, return_win)
	end
	return closed
end

function M.close()
	if not state then
		return
	end
	flush_output_text()
	flush_action_output()
	output_ui.close(state)
	local current_win = vim.api.nvim_get_current_win()
	local current_tab = vim.api.nvim_get_current_tabpage()
	local chat_tab = valid_tab(state.tabpage) and state.tabpage or nil
	local return_win = chat_tab == current_tab and state.origin_win or current_win
	instructions.stop_spinner(state)
	composer.close(state)
	if not close_tab(chat_tab, return_win) then
		close_window(state.output_win)
		close_window(state.sessions_win)
		if valid_win(state.output_host_win) then
			local host_tab = vim.api.nvim_win_get_tabpage(state.output_host_win)
			if #vim.api.nvim_list_tabpages() == 1 and #vim.api.nvim_tabpage_list_wins(host_tab) == 1 then
				vim.api.nvim_set_current_win(state.output_host_win)
				vim.cmd("enew!")
			else
				close_window(state.output_host_win)
			end
		end
	end
	state.sessions_win = nil
	state.output_win = nil
	state.output_host_win = nil
	state.tabpage = nil
	if valid_win(return_win) then
		pcall(vim.api.nvim_set_current_win, return_win)
	elseif valid_tab(state.origin_tab) then
		pcall(vim.api.nvim_set_current_tabpage, state.origin_tab)
	end
end

local function create_buffers()
	local created = false
	if not valid_buf(state.sessions_buf) then
		created = true
		state.sessions_buf = vim.api.nvim_create_buf(false, true)
		pcall(vim.api.nvim_buf_set_name, state.sessions_buf, "acp://codex/sessions")
		vim.bo[state.sessions_buf].buftype = "nofile"
		vim.bo[state.sessions_buf].bufhidden = "hide"
		vim.bo[state.sessions_buf].swapfile = false
		vim.bo[state.sessions_buf].undolevels = -1
		vim.bo[state.sessions_buf].filetype = "acp-sessions"
		vim.bo[state.sessions_buf].modifiable = false
		render_sessions()
	end
	if not valid_buf(state.output_host_buf) then
		created = true
		state.output_host_buf = vim.api.nvim_create_buf(false, true)
		pcall(vim.api.nvim_buf_set_name, state.output_host_buf, "acp://codex/host")
		vim.bo[state.output_host_buf].buftype = "nofile"
		vim.bo[state.output_host_buf].bufhidden = "hide"
		vim.bo[state.output_host_buf].swapfile = false
		vim.bo[state.output_host_buf].undolevels = -1
		vim.bo[state.output_host_buf].filetype = "acp-host"
		vim.bo[state.output_host_buf].modifiable = false
	end
	if not valid_buf(state.output_buf) then
		created = true
		state.output_buf = vim.api.nvim_create_buf(false, true)
		pcall(vim.api.nvim_buf_set_name, state.output_buf, "acp://codex/chat")
		vim.bo[state.output_buf].buftype = "nofile"
		vim.bo[state.output_buf].bufhidden = "hide"
		vim.bo[state.output_buf].swapfile = false
		vim.bo[state.output_buf].undolevels = -1
		vim.bo[state.output_buf].filetype = "acp"
		vim.bo[state.output_buf].modifiable = false
		set_chat(state.chat or blocks.new())
	end
	-- Chat transcripts are presentation surfaces, so editor-wide indent guide
	-- plugins should leave their literal whitespace alone.
	vim.b[state.output_buf].indent_guide = false
	if vim.bo[state.output_buf].filetype ~= "acp" then
		vim.bo[state.output_buf].filetype = "acp"
	end
	if not valid_buf(state.input_buf) then
		created = true
		state.input_buf = vim.api.nvim_create_buf(false, true)
		pcall(vim.api.nvim_buf_set_name, state.input_buf, "acp://codex/prompt")
		vim.bo[state.input_buf].buftype = "nofile"
		vim.bo[state.input_buf].bufhidden = "hide"
		vim.bo[state.input_buf].swapfile = false
		vim.bo[state.input_buf].filetype = "acp-prompt"
	end
	if created then
		state.keymaps_set = false
	end
end

local function focus_input(insert)
	if not state or not valid_win(state.input_win) then
		return
	end
	vim.api.nvim_set_current_win(state.input_win)
	if insert then
		vim.cmd("startinsert")
	end
end

local function configure_window(winid, output)
	vim.wo[winid].number = false
	vim.wo[winid].relativenumber = false
	vim.wo[winid].signcolumn = "no"
	vim.wo[winid].foldcolumn = "0"
	vim.wo[winid].wrap = true
	vim.wo[winid].linebreak = true
	vim.wo[winid].cursorline = not output
	if output then
		view.configure_output_window(winid)
	end
end

local function configure_host_window(winid)
	if not valid_win(winid) then
		return
	end
	vim.wo[winid].number = false
	vim.wo[winid].relativenumber = false
	vim.wo[winid].signcolumn = "no"
	vim.wo[winid].foldcolumn = "0"
	vim.wo[winid].statuscolumn = ""
	vim.wo[winid].wrap = false
	vim.wo[winid].cursorline = false
	vim.wo[winid].winbar = ""
	vim.wo[winid].fillchars = "eob: "
end

local function configure_sessions_window(winid)
	configure_window(winid, false)
	vim.wo[winid].wrap = false
	vim.wo[winid].linebreak = false
	vim.wo[winid].winfixwidth = true
end

local function sync_output_float(layout, create)
	if not layout or not layout.chat or not valid_buf(state.output_buf) then
		return false, false
	end
	local geometry_changed = false
	if not valid_win(state.output_win) or not view.is_floating(state.output_win) then
		if not create then
			return false, false
		end
		state.output_win = vim.api.nvim_open_win(state.output_buf, false, layout.chat)
		geometry_changed = true
	else
		local current = vim.api.nvim_win_get_config(state.output_win)
		geometry_changed = not view.same_float_geometry(current, layout.chat)
		if geometry_changed then
			vim.api.nvim_win_set_config(state.output_win, layout.chat)
		end
	end
	vim.api.nvim_win_set_buf(state.output_win, state.output_buf)
	configure_window(state.output_win, true)
	update_output_winbar()
	return true, geometry_changed
end

local function apply_composer_result(result, create_output)
	if not result then
		return false
	end
	local applied, output_geometry_changed = sync_output_float(result.layout, create_output)
	if not applied then
		return false
	end
	if state.output_position_mode == "center" and (result.geometry_changed or output_geometry_changed) then
		center_output_position()
	end
	return true
end

sync_composer = function()
	if not state or not valid_win(state.output_host_win) or not composer.is_open(state, state.output_host_win) then
		return nil
	end
	local result = composer.sync(state, state.output_host_win, config.window)
	if not apply_composer_result(result, false) then
		return nil
	end
	return result
end

refresh_composer = function()
	if not composer.refresh_turn(state, state and state.output_host_win, config.window) then
		instructions.stop_spinner(state)
	end
end

local function open_composer()
	local result = composer.open(state, state.output_host_win, config.window)
	if not apply_composer_result(result, true) then
		return false
	end
	return true
end

local function normal_window_in_tab(winid, tabpage)
	return valid_win(winid) and vim.api.nvim_win_get_tabpage(winid) == tabpage and not view.is_floating(winid)
end

local function open_layout()
	state._sync_composer = sync_composer
	if
		normal_window_in_tab(state.output_host_win, state.tabpage)
		and valid_win(state.output_win)
		and view.is_floating(state.output_win)
		and composer.is_open(state, state.output_host_win)
		and normal_window_in_tab(state.sessions_win, state.tabpage)
		and vim.api.nvim_win_get_tabpage(state.output_win) == state.tabpage
	then
		vim.api.nvim_set_current_tabpage(state.tabpage)
		vim.api.nvim_win_set_buf(state.output_host_win, state.output_host_buf)
		vim.api.nvim_win_set_buf(state.output_win, state.output_buf)
		vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
		vim.api.nvim_win_set_buf(state.sessions_win, state.sessions_buf)
		configure_host_window(state.output_host_win)
		configure_window(state.output_win, true)
		configure_sessions_window(state.sessions_win)
		render_sessions()
		refresh_output_view(0)
		pcall(vim.cmd, "redraw")
		if not sync_composer() then
			error("Could not synchronize the Codex float stack")
		end
		update_chrome()
		focus_input(false)
		return
	end

	local previous_output = state.output_win
	local previous_host = state.output_host_win
	local previous_sessions = state.sessions_win
	composer.close(state)
	local tabpage = valid_tab(state.tabpage) and state.tabpage or nil
	if not tabpage then
		vim.cmd("tabnew")
		tabpage = vim.api.nvim_get_current_tabpage()
	else
		vim.api.nvim_set_current_tabpage(tabpage)
	end

	local host_win = normal_window_in_tab(previous_host, tabpage) and previous_host or nil
	if not host_win and normal_window_in_tab(previous_output, tabpage) then
		host_win = previous_output
	end
	if not host_win then
		for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
			if normal_window_in_tab(winid, tabpage) and winid ~= previous_sessions then
				host_win = winid
				break
			end
		end
	end
	if not host_win and normal_window_in_tab(previous_sessions, tabpage) then
		vim.api.nvim_set_current_win(previous_sessions)
		vim.cmd("rightbelow vnew")
		host_win = vim.api.nvim_get_current_win()
	end
	if not host_win then
		error("Codex tab has no normal host window")
	end

	local output_win = valid_win(previous_output)
			and view.is_floating(previous_output)
			and vim.api.nvim_win_get_tabpage(previous_output) == tabpage
			and previous_output
		or nil
	local sessions_win = normal_window_in_tab(previous_sessions, tabpage)
			and previous_sessions ~= host_win
			and previous_sessions
		or nil
	if not sessions_win then
		vim.api.nvim_set_current_win(host_win)
		local sessions_width = math.max(16, tonumber(config.window.sessions_width) or 30)
		vim.cmd(("topleft %dvsplit"):format(sessions_width))
		sessions_win = vim.api.nvim_get_current_win()
	end
	for _, winid in pairs({ previous_output, previous_host, previous_sessions }) do
		if valid_win(winid) and winid ~= host_win and winid ~= output_win and winid ~= sessions_win then
			close_window(winid)
		end
	end

	state.tabpage = tabpage
	state.output_win = output_win
	state.output_host_win = host_win
	state.sessions_win = sessions_win
	vim.api.nvim_set_current_win(state.output_host_win)
	vim.api.nvim_win_set_buf(state.output_host_win, state.output_host_buf)
	configure_host_window(state.output_host_win)
	local sessions_width = math.max(16, tonumber(config.window.sessions_width) or 30)
	vim.api.nvim_win_set_buf(state.sessions_win, state.sessions_buf)
	configure_sessions_window(state.sessions_win)
	pcall(vim.api.nvim_win_set_width, state.sessions_win, sessions_width)
	vim.wo[state.sessions_win].winbar =
		view.sessions_winbar(state.sessions_count or 1, state.threads_loading, state.cwd)
	vim.api.nvim_set_current_win(state.output_host_win)

	if not open_composer() then
		error("Could not create the Codex composer")
	end
	render_sessions()
	refresh_output_view(0)
	pcall(vim.cmd, "redraw")
	update_chrome()
	focus_input(false)
end

local function add_context_from_source(range, file_only)
	if not state then
		return false
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local winid = vim.api.nvim_get_current_win()
	if not valid_buf(bufnr) or vim.bo[bufnr].buftype ~= "" then
		bufnr = state.source_buf
		winid = state.source_win
	end
	if not valid_buf(bufnr) then
		notify("No source file is available for context", vim.log.levels.WARN)
		return false
	end
	remember_source(bufnr, winid)
	local item
	if range and not file_only then
		item = context.selection(bufnr, range, state.cwd, config.context)
	else
		item = context.file(bufnr, state.cwd)
	end
	if not item then
		notify("The current buffer has no file path", vim.log.levels.WARN)
		return false
	end
	context.add(state.contexts, item)
	update_chrome()
	notify(("Added context: %s"):format(item.label))
	return true
end

local function stream_block_id(kind, item_id)
	local base = tostring(item_id or kind)
	if not state.chat.by_id[base] then
		return base
	end
	local index = 2
	while state.chat.by_id[("%s:%s:%d"):format(base, kind, index)] do
		index = index + 1
	end
	return ("%s:%s:%d"):format(base, kind, index)
end

local function active_stream_block(block_id, kind)
	if block_id == nil then
		return nil
	end
	local block = state.chat.by_id[block_id]
	if block and block.kind == kind and state.chat.blocks[#state.chat.blocks] == block then
		return block
	end
end

local function ensure_agent_item(item_id)
	local block = state.agent_item == item_id and active_stream_block(state.agent_block_id, "agent")
	if block then
		return block.id
	end
	state.agent_item = item_id
	state.agent_block_id = stream_block_id("agent", item_id)
	block = append_chat_block(function(chat)
		return chat:ensure_agent(state.agent_block_id)
	end)
	return block and block.id or state.agent_block_id
end

local function ensure_plan_item(item_id)
	local block = state.plan_item == item_id and active_stream_block(state.plan_block_id, "plan")
	if block then
		return block.id
	end
	state.plan_item = item_id
	state.plan_block_id = stream_block_id("plan", item_id)
	block = append_chat_block(function(chat)
		return chat:ensure_plan(state.plan_block_id)
	end)
	return block and block.id or state.plan_block_id
end

local function active_turn(thread)
	for index = #(thread.turns or {}), 1, -1 do
		local turn = thread.turns[index]
		if turn.status == "inProgress" then
			return turn
		end
	end
end

local function apply_thread_response(result)
	local thread = result and result.thread
	if type(thread) ~= "table" or type(thread.id) ~= "string" then
		return false
	end
	state.thread_id = thread.id
	state.cwd = result.cwd or thread.cwd or state.cwd
	state.model = result.model or state.model
	state.effort = present(result.reasoningEffort) and result.reasoningEffort or state.effort
	state.service_tier = present(result.serviceTier) and result.serviceTier or state.service_tier
	state.diff = render.thread_diff(thread)
	state.streamed_items = {}
	state.items = {}
	for _, history_turn in ipairs(thread.turns or {}) do
		for _, item in ipairs(history_turn.items or {}) do
			if item.id then
				state.items[item.id] = item
			end
		end
	end
	state.agent_item = nil
	state.agent_block_id = nil
	state.plan_item = nil
	state.plan_block_id = nil
	state.contexts = {}
	state.queue = {}
	state.pending_instructions = {}
	reset_output_position()
	local turn = active_turn(thread)
	state.turn_id = turn and turn.id or nil
	state.busy = turn ~= nil
	set_chat(blocks.from_thread(thread))
	set_status(state.busy and "running" or "ready")
	update_chrome()
	local found = false
	local current_thread = thread
	for index, listed in ipairs(state.threads or {}) do
		if listed.id == thread.id then
			current_thread = vim.tbl_extend("force", listed, thread)
			state.threads[index] = current_thread
			found = true
			break
		end
	end
	if state.threads and not found then
		table.insert(state.threads, 1, thread)
	end
	state.current_thread = current_thread
	render_sessions()
	return true
end

local function flush_thread_waiters(ok, value)
	local waiters = state.start_waiters
	state.start_waiters = {}
	state.starting = false
	for _, callback in ipairs(waiters) do
		callback(ok, value)
	end
end

local function ensure_thread(callback)
	if state.thread_id then
		callback(true, state.thread_id)
		return
	end
	table.insert(state.start_waiters, callback)
	if state.starting then
		return
	end
	state.starting = true
	set_status("starting thread")
	client:start_thread({
		cwd = state.cwd,
		model = state.model,
		approval_policy = config.approval_policy,
		sandbox = config.sandbox,
		personality = state.personality,
		service_tier = state.service_tier,
	}, function(result, err)
		if err or not apply_thread_response(result) then
			local message = err or "Codex did not create a thread"
			set_status("error")
			append_notice("error", message)
			flush_thread_waiters(false, message)
			return
		end
		flush_thread_waiters(true, state.thread_id)
	end)
end

local function prepared_prompt(text)
	local contexts = vim.deepcopy(state.contexts)
	if config.auto_context and valid_buf(state.source_buf) then
		context.add(contexts, context.file(state.source_buf, state.cwd))
	end
	local extra_input, additional, labels = context.turn_payload(contexts)
	local input = { { type = "text", text = text, text_elements = {} } }
	vim.list_extend(input, extra_input)
	return {
		text = text,
		labels = labels,
		payload = {
			input = input,
			additional_context = additional,
			cwd = state.cwd,
			model = state.model,
			effort = state.effort,
			personality = state.personality,
			service_tier = state.service_tier,
		},
	}
end

local function append_user(envelope, suffix)
	append_chat_block(function(chat)
		return chat:add_user(envelope.text, envelope.labels, {
			suffix = suffix,
			steer = suffix ~= nil,
		})
	end)
end

local function start_envelope(envelope)
	remove_pending_instruction(envelope._acp_instruction_id, false)
	reset_output_position()
	state.busy = true
	state.agent_item = nil
	state.agent_block_id = nil
	state.plan_item = nil
	state.plan_block_id = nil
	state.streamed_items = {}
	state.items = {}
	append_user(envelope)
	set_status("starting turn")
	client:start_turn(state.thread_id, envelope.payload, function(result, err)
		if err or type(result) ~= "table" or type(result.turn) ~= "table" then
			state.busy = false
			state.turn_id = nil
			reset_output_position()
			set_status("error")
			append_notice("error", err or "Codex did not start the turn")
			drain_queue()
			return
		end
		state.turn_id = result.turn.id
		state.busy = true
		set_status("running")
	end)
end

local function dispatch_prompt(envelope, follow_up)
	ensure_thread(function(ok)
		if not ok then
			return
		end
		if state.busy then
			if (follow_up or config.follow_up) == "steer" and state.turn_id then
				local instruction = add_pending_instruction("steer", envelope)
				append_user(envelope, " (steer)")
				set_status("steering")
				client:steer_turn(state.thread_id, state.turn_id, envelope.payload, function(_, err)
					if err then
						remove_pending_instruction(instruction.id, false)
						append_notice("error", ("Steer failed: %s"):format(err))
					else
						instructions.accept(state, instruction.id)
					end
					set_status(err and "running" or "steered")
				end)
			else
				table.insert(state.queue, envelope)
				add_pending_instruction("queued", envelope)
				set_status("running")
			end
			update_chrome()
			return
		end
		start_envelope(envelope)
	end)
end

drain_queue = function()
	if not state or state.busy or #state.queue == 0 then
		update_chrome()
		return
	end
	local envelope = table.remove(state.queue, 1)
	vim.schedule(function()
		if state and not state.busy then
			start_envelope(envelope)
		end
	end)
end

local function local_command(text)
	local name, args = text:match("^%s*/([%w_-]+)%s*(.-)%s*$")
	if not name then
		return false
	end
	if name == "model" then
		select_model()
	elseif name == "reasoning" then
		select_reasoning()
	elseif name == "review" then
		start_review(args ~= "" and args or nil)
	elseif name == "compact" then
		compact_thread()
	elseif name == "status" then
		show_status()
	elseif name == "new" then
		M.new_chat()
	elseif name == "threads" then
		open_threads()
	elseif name == "login" then
		M.login()
	elseif name == "reload" then
		reloader.reload()
	else
		return false
	end
	return true
end

local function submit_prompt(follow_up)
	if not state then
		M.open()
	end
	local text = input_text():gsub("%s+$", "")
	if text:match("^%s*$") then
		notify("Prompt is empty", vim.log.levels.WARN)
		return
	end
	if local_command(text) then
		set_input("")
		return
	end
	local envelope = prepared_prompt(text)
	state.contexts = {}
	set_input("")
	update_chrome()
	dispatch_prompt(envelope, follow_up)
end

function M.send()
	submit_prompt()
end

function M.steer()
	submit_prompt("steer")
end

local function native_output_redraw()
	local control_l = vim.api.nvim_replace_termcodes("<C-l>", true, false, true)
	pcall(vim.cmd, "normal! " .. control_l)
end

local function sync_output_position()
	if not state or not state.busy or not valid_win(state.output_win) then
		native_output_redraw()
		return
	end
	if output_position_synced() then
		native_output_redraw()
		return
	end
	if not center_output_position() then
		native_output_redraw()
	end
end

local function set_buffer_keymaps()
	local opts = { buffer = state.input_buf, silent = true }
	vim.keymap.set({ "n", "i" }, "<C-s>", M.steer, vim.tbl_extend("force", opts, { desc = "Steer active Codex turn" }))
	vim.keymap.set({ "n", "i" }, "<C-CR>", M.send, vim.tbl_extend("force", opts, { desc = "Send Codex prompt" }))
	vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "Close Codex tab" }))

	local output_opts = { buffer = state.output_buf, silent = true }
	vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", output_opts, { desc = "Close Codex tab" }))
	vim.keymap.set("n", "i", function()
		focus_input(true)
	end, vim.tbl_extend("force", output_opts, { desc = "Focus Codex prompt" }))
	vim.keymap.set("n", "n", M.new_chat, vim.tbl_extend("force", output_opts, { desc = "New Codex chat" }))
	vim.keymap.set("n", "t", function()
		M.focus_sessions()
	end, vim.tbl_extend("force", output_opts, { desc = "Focus Codex sessions" }))
	vim.keymap.set("n", "d", M.open_diff, vim.tbl_extend("force", output_opts, { desc = "Open Codex diff" }))
	vim.keymap.set("n", "m", function()
		select_model()
	end, vim.tbl_extend("force", output_opts, { desc = "Select Codex model" }))
	vim.keymap.set("n", "r", function()
		select_reasoning()
	end, vim.tbl_extend("force", output_opts, { desc = "Select Codex reasoning" }))
	vim.keymap.set("n", "s", M.stop, vim.tbl_extend("force", output_opts, { desc = "Stop Codex turn" }))
	vim.keymap.set(
		"n",
		"<C-l>",
		sync_output_position,
		vim.tbl_extend("force", output_opts, { desc = "Center active Codex response or redraw" })
	)
	vim.keymap.set("n", "]]", function()
		output_ui.jump_section(state, 1)
	end, vim.tbl_extend("force", output_opts, { desc = "Next Codex output section" }))
	vim.keymap.set("n", "[[", function()
		output_ui.jump_section(state, -1)
	end, vim.tbl_extend("force", output_opts, { desc = "Previous Codex output section" }))
	vim.keymap.set("n", "]o", function()
		output_ui.jump_item(state, 1)
	end, vim.tbl_extend("force", output_opts, { desc = "Next Codex output item" }))
	vim.keymap.set("n", "[o", function()
		output_ui.jump_item(state, -1)
	end, vim.tbl_extend("force", output_opts, { desc = "Previous Codex output item" }))
	vim.keymap.set("n", "<CR>", function()
		output_ui.open_current(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Open Codex output item" }))
	vim.keymap.set("n", "K", function()
		output_ui.inspect(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Inspect Codex output item" }))
	vim.keymap.set("n", "gf", function()
		output_ui.open_reference(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Open Codex output file reference" }))
	vim.keymap.set("n", "?", function()
		output_ui.actions(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Codex output actions" }))
	vim.keymap.set("n", "<leader>a?", function()
		output_ui.help(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Codex output help" }))
	vim.keymap.set("n", "<leader>ax", function()
		output_ui.search(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Search Codex output" }))
	vim.keymap.set("n", "<leader>am", function()
		output_ui.open_map(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Open Codex output map" }))
	vim.keymap.set("n", "<leader>aO", function()
		output_ui.open_items(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Open Codex output items" }))
	vim.keymap.set("n", "<leader>ay", function()
		output_ui.yank_section(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Yank Codex output section" }))
	vim.keymap.set("n", "<leader>ai", function()
		output_ui.draft_section(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Draft Codex output section" }))
	vim.keymap.set("n", "<leader>av", function()
		output_ui.open_outline(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Open Codex output outline" }))
	vim.keymap.set("n", "<leader>ab", function()
		output_ui.open_code_blocks(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Open Codex code blocks" }))
	vim.keymap.set("n", "<leader>aB", function()
		output_ui.code_blocks_quickfix(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Send Codex code blocks to quickfix" }))
	vim.keymap.set("n", "<leader>aY", function()
		output_ui.yank_code_block(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Yank Codex code block" }))
	vim.keymap.set("n", "<leader>ag", function()
		output_ui.open_locations(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Open Codex output locations" }))
	vim.keymap.set("n", "<leader>ae", function()
		output_ui.open_problems(state)
	end, vim.tbl_extend("force", output_opts, { desc = "Open Codex output problems" }))
	vim.keymap.set(
		"n",
		"<leader>az",
		"za",
		vim.tbl_extend("force", output_opts, {
			desc = "Toggle Codex output fold",
			remap = false,
		})
	)

	if valid_buf(state.sessions_buf) then
		local sessions_opts = { buffer = state.sessions_buf, silent = true }
		vim.keymap.set("n", "<CR>", function()
			M.select_session()
		end, vim.tbl_extend("force", sessions_opts, { desc = "Resume Codex session" }))
		vim.keymap.set("n", "r", function()
			refresh_threads()
		end, vim.tbl_extend("force", sessions_opts, { desc = "Refresh Codex sessions" }))
		vim.keymap.set("n", "n", M.new_chat, vim.tbl_extend("force", sessions_opts, { desc = "New Codex chat" }))
		vim.keymap.set("n", "i", function()
			focus_input(true)
		end, vim.tbl_extend("force", sessions_opts, { desc = "Focus Codex prompt" }))
		vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", sessions_opts, { desc = "Close Codex tab" }))
	end
end

function M.open(opts)
	if type(opts) == "string" then
		opts = { prompt = opts }
	else
		opts = opts or {}
	end
	local origin_buf = vim.api.nvim_get_current_buf()
	local origin_win = vim.api.nvim_get_current_win()
	local origin_tab = vim.api.nvim_get_current_tabpage()
	if not state then
		state = fresh_state(current_cwd())
	end
	if valid_buf(origin_buf) and vim.bo[origin_buf].buftype == "" then
		state.origin_win = origin_win
		state.origin_tab = origin_tab
		remember_source(origin_buf, origin_win)
		if not state.thread_id then
			state.cwd = current_cwd()
		end
	end
	if opts.new then
		if not M.new_chat({ keep_layout = true }) then
			return
		end
	end
	if opts.range then
		add_context_from_source(opts.range, false)
	elseif opts.file_context then
		add_context_from_source(nil, true)
	end

	create_buffers()
	if not state.keymaps_set then
		set_buffer_keymaps()
		state.keymaps_set = true
	end
	open_layout()
	if state.threads == nil and not state.threads_loading then
		refresh_threads()
	end
	if opts.prompt and opts.prompt ~= "" then
		set_input(opts.prompt)
		M.send()
	end
end

function M.new_chat(opts)
	opts = opts or {}
	if state and (state.busy or state.starting) then
		notify("Stop or wait for the active Codex turn before starting a new chat", vim.log.levels.WARN)
		return false
	end
	local previous_thread = state and state.thread_id
	if not state then
		state = fresh_state(current_cwd())
	else
		local windows = {
			sessions_buf = state.sessions_buf,
			output_host_buf = state.output_host_buf,
			output_buf = state.output_buf,
			input_buf = state.input_buf,
			instruction_buf = state.instruction_buf,
			sessions_win = state.sessions_win,
			output_host_win = state.output_host_win,
			output_win = state.output_win,
			input_win = state.input_win,
			instruction_win = state.instruction_win,
			tabpage = state.tabpage,
			origin_win = state.origin_win,
			origin_tab = state.origin_tab,
			source_buf = state.source_buf,
			source_win = state.source_win,
			keymaps_set = state.keymaps_set,
			threads = state.threads,
		}
		state = vim.tbl_extend("force", fresh_state(current_cwd()), windows)
	end
	if previous_thread and client and client.unsubscribe_thread then
		client:unsubscribe_thread(previous_thread, function(_, err)
			if err then
				notify(("Could not unload the previous Codex thread: %s"):format(err), vim.log.levels.WARN)
			end
		end)
	end
	if valid_buf(state.output_buf) then
		set_chat(blocks.new())
	end
	if valid_buf(state.input_buf) then
		set_input("")
	end
	render_sessions()
	update_chrome()
	if not opts.keep_layout then
		M.open()
	end
	return true
end

local function resume_thread(thread)
	if state.busy or state.starting then
		notify("Stop or wait for the active Codex turn before switching threads", vim.log.levels.WARN)
		return
	end
	local previous_thread = state.thread_id
	set_status("resuming")
	client:resume_thread(thread.id, { cwd = thread.cwd or state.cwd }, function(result, err)
		if err or not apply_thread_response(result) then
			set_status("error")
			notify(err or "Failed to resume Codex thread", vim.log.levels.ERROR)
			return
		end
		if previous_thread and previous_thread ~= state.thread_id and client.unsubscribe_thread then
			client:unsubscribe_thread(previous_thread, function(_, unload_err)
				if unload_err then
					notify(("Could not unload the previous Codex thread: %s"):format(unload_err), vim.log.levels.WARN)
				end
			end)
		end
		focus_input(false)
	end)
end

refresh_threads = function(callback)
	if not state or not client then
		if callback then
			callback(nil)
		end
		return
	end
	state.thread_waiters = state.thread_waiters or {}
	if callback then
		table.insert(state.thread_waiters, callback)
	end
	if state.threads_loading then
		return
	end
	state.threads_loading = true
	state.threads_error = nil
	render_sessions()
	update_chrome()
	local request_state = state
	client:list_threads({
		cwd = state.cwd,
		source_kinds = config.thread_sources,
		max_threads = config.max_threads,
	}, function(threads, err)
		if state ~= request_state then
			return
		end
		state.threads_loading = false
		local waiters = state.thread_waiters or {}
		state.thread_waiters = {}
		if err then
			state.threads_error = err
			render_sessions()
			update_chrome()
			notify(err, vim.log.levels.ERROR)
			for _, waiter in ipairs(waiters) do
				waiter(nil)
			end
			return
		end
		state.threads = threads
		state.threads_error = nil
		render_sessions()
		update_chrome()
		for _, waiter in ipairs(waiters) do
			waiter(threads)
		end
	end)
end

open_threads = function()
	if not state then
		M.open()
	end
	refresh_threads(function(threads)
		if not threads or #threads == 0 then
			notify("No Codex threads found for this working directory")
			return
		end
		vim.ui.select(threads, {
			prompt = "Codex threads",
			format_item = render.thread_label,
		}, function(choice)
			if choice then
				resume_thread(choice)
			end
		end)
	end)
end

function M.select_session()
	if not state or not valid_win(state.sessions_win) then
		return
	end
	local line = vim.api.nvim_win_get_cursor(state.sessions_win)[1]
	local entry = state.thread_rows and state.thread_rows[line]
	if not entry then
		return
	end
	if entry.current then
		focus_input(false)
		return
	end
	resume_thread(entry.thread)
end

function M.focus_sessions()
	if not state then
		M.open()
	else
		create_buffers()
		if not state.keymaps_set then
			set_buffer_keymaps()
			state.keymaps_set = true
		end
		open_layout()
	end
	if valid_win(state.sessions_win) then
		vim.api.nvim_set_current_win(state.sessions_win)
	end
	refresh_threads()
end

local function model_by_id(id)
	for _, model in ipairs(state.models or {}) do
		if model.id == id or model.model == id then
			return model
		end
	end
end

local function load_models(callback)
	if state.models then
		callback(state.models)
		return
	end
	set_status("loading models")
	client:list_models(function(models, err)
		if err then
			set_status(state.busy and "running" or "ready")
			notify(err, vim.log.levels.ERROR)
			callback(nil)
			return
		end
		state.models = models
		set_status(state.busy and "running" or "ready")
		callback(models)
	end)
end

select_model = function()
	if not state then
		M.open()
	end
	load_models(function(models)
		if not models then
			return
		end
		vim.ui.select(models, {
			prompt = "Codex model",
			format_item = function(model)
				local current = model.id == state.model and " (current)" or ""
				local default = model.isDefault and " [default]" or ""
				return ("%s%s%s — %s"):format(
					model.displayName or model.id,
					current,
					default,
					model.description or ""
				)
			end,
		}, function(choice)
			if not choice then
				return
			end
			state.model = choice.id or choice.model
			local supported = {}
			for _, option in ipairs(choice.supportedReasoningEfforts or {}) do
				supported[option.reasoningEffort] = true
			end
			if not supported[state.effort] then
				state.effort = choice.defaultReasoningEffort
			end
			update_chrome()
		end)
	end)
end

select_reasoning = function()
	if not state then
		M.open()
	end
	load_models(function(models)
		if not models then
			return
		end
		local model = model_by_id(state.model)
		if not model then
			for _, candidate in ipairs(models) do
				if candidate.isDefault then
					model = candidate
					break
				end
			end
		end
		local options = model and model.supportedReasoningEfforts or {}
		if #options == 0 then
			notify("The selected model does not advertise reasoning options", vim.log.levels.WARN)
			return
		end
		vim.ui.select(options, {
			prompt = "Codex reasoning effort",
			format_item = function(option)
				local current = option.reasoningEffort == state.effort and " (current)" or ""
				return ("%s%s — %s"):format(option.reasoningEffort, current, option.description or "")
			end,
		}, function(choice)
			if choice then
				state.effort = choice.reasoningEffort
				update_chrome()
			end
		end)
	end)
end

start_review = function(instructions)
	if not state then
		M.open()
	end
	ensure_thread(function(ok)
		if not ok then
			return
		end
		if state.busy then
			notify("Wait for the active turn before starting a review", vim.log.levels.WARN)
			return
		end
		local target = instructions and { type = "custom", instructions = instructions }
			or { type = "uncommittedChanges" }
		reset_output_position()
		state.busy = true
		set_status("starting review")
		client:review(state.thread_id, target, config.review_delivery, function(result, err)
			if err or type(result) ~= "table" then
				state.busy = false
				reset_output_position()
				set_status("error")
				notify(err or "Failed to start Codex review", vim.log.levels.ERROR)
				return
			end
			if result.reviewThreadId and result.reviewThreadId ~= state.thread_id then
				state.thread_id = result.reviewThreadId
			end
			state.turn_id = result.turn and result.turn.id or nil
			set_status("reviewing")
		end)
	end)
end

compact_thread = function()
	if not state or not state.thread_id then
		notify("Start or resume a Codex thread first", vim.log.levels.WARN)
		return
	end
	client:compact(state.thread_id, function(_, err)
		if err then
			notify(err, vim.log.levels.ERROR)
		else
			set_status("compacting")
		end
	end)
end

show_status = function()
	if not state then
		notify("Codex tab is not open")
		return
	end
	local usage = state.tokens and tostring(state.tokens.totalTokens or 0) or "unknown"
	notify(table.concat({
		("Thread: %s"):format(state.thread_id or "not started"),
		("Model: %s"):format(state.model or "default"),
		("Reasoning: %s"):format(state.effort or "default"),
		("Status: %s"):format(state.status),
		("Tokens: %s"):format(usage),
		("Working directory: %s"):format(state.cwd),
	}, "\n"))
end

function M.stop()
	if not state or not state.thread_id or not state.turn_id or not state.busy then
		notify("No active Codex turn", vim.log.levels.WARN)
		return
	end
	set_status("stopping")
	client:interrupt_turn(state.thread_id, state.turn_id, function(_, err)
		if err then
			set_status("running")
			notify(err, vim.log.levels.ERROR)
		end
	end)
end

function M.open_diff()
	if not state or not state.diff or state.diff == "" then
		notify("The current Codex thread has no diff", vim.log.levels.WARN)
		return
	end
	local return_win = vim.api.nvim_get_current_win()
	vim.cmd("tabnew")
	local tabpage = vim.api.nvim_get_current_tabpage()
	local winid = vim.api.nvim_get_current_win()
	local bufnr = vim.api.nvim_create_buf(false, true)
	pcall(
		vim.api.nvim_buf_set_name,
		bufnr,
		("acp://codex/diff/%s/%s"):format(state.thread_id or "new", tostring(vim.uv.hrtime()))
	)
	vim.api.nvim_win_set_buf(winid, bufnr)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "diff"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(state.diff, "\n", { plain = true }))
	vim.bo[bufnr].modifiable = false
	vim.wo[winid].winbar = " Codex changes · q close tab "
	vim.keymap.set("n", "q", function()
		close_tab(tabpage, return_win)
	end, { buffer = bufnr, silent = true, desc = "Close Codex diff tab" })
end

function M.login()
	client:read_account(function(result, err)
		if err then
			notify(err, vim.log.levels.ERROR)
			return
		end
		if result and result.account and result.account ~= vim.NIL then
			local account = result.account
			notify(present(account.email) and ("Signed in as " .. account.email) or ("Signed in with " .. account.type))
			return
		end
		client:login(function(login, login_err)
			if login_err then
				notify(login_err, vim.log.levels.ERROR)
				return
			end
			local url = login and (login.authUrl or login.verificationUrl)
			if not url then
				notify("Codex login started")
				return
			end
			local opened = false
			if vim.ui.open then
				opened = pcall(vim.ui.open, url)
			end
			if not opened then
				notify(("Open this URL to sign in:\n%s"):format(url))
			end
		end)
	end)
end

function M.open_actions()
	local actions = {
		{ label = "New chat", run = M.new_chat },
		{ label = "Open recent threads", run = open_threads },
		{
			label = "Add current file",
			run = function()
				add_context_from_source(nil, true)
			end,
		},
		{ label = "Choose model", run = select_model },
		{ label = "Choose reasoning effort", run = select_reasoning },
		{
			label = "Review uncommitted changes",
			run = function()
				start_review()
			end,
		},
		{ label = "Open latest diff", run = M.open_diff },
		{
			label = "Output actions",
			run = function()
				output_ui.actions(state)
			end,
		},
		{ label = "Compact context", run = compact_thread },
		{ label = "Show status", run = show_status },
		{ label = "Stop active turn", run = M.stop },
		{
			label = "Reload acp.nvim",
			run = function()
				reloader.reload()
			end,
		},
	}
	vim.ui.select(actions, {
		prompt = "Codex actions",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if choice then
			choice.run()
		end
	end)
end

local function notification_thread_id(method, params)
	if params.threadId then
		return params.threadId
	end
	if method == "thread/started" and type(params.thread) == "table" then
		return params.thread.id
	end
	return nil
end

function M._handle_notification(method, params)
	params = params or {}
	if method == "account/login/completed" then
		notify(
			params.success and "Codex sign-in completed" or (params.error or "Codex sign-in failed"),
			params.success and vim.log.levels.INFO or vim.log.levels.ERROR
		)
		return
	end
	if not state then
		return
	end
	local thread_id = notification_thread_id(method, params)
	if thread_id and state.thread_id and thread_id ~= state.thread_id then
		return
	end

	if method == "turn/started" then
		if not state.busy then
			reset_output_position()
		end
		state.busy = true
		state.turn_id = params.turn and params.turn.id or state.turn_id
		set_status("running")
	elseif method == "item/started" then
		local item = params.item or {}
		if item.id then
			state.items[item.id] = item
		end
		if item.type == "agentMessage" then
			consume_steering_instructions()
			ensure_agent_item(item.id)
		elseif action.kind(item) then
			append_chat_block(function(chat)
				return chat:start_item(item)
			end)
		end
		set_status(render.item_status(item))
	elseif method == "item/agentMessage/delta" then
		consume_steering_instructions()
		local block_id = ensure_agent_item(params.itemId)
		state.streamed_items[params.itemId] = true
		append_text(block_id, params.delta or "")
		set_status("responding")
	elseif method == "item/plan/delta" then
		consume_steering_instructions()
		local block_id = ensure_plan_item(params.itemId)
		state.streamed_items[params.itemId] = true
		append_text(block_id, params.delta or "")
		set_status("planning")
	elseif method == "item/reasoning/summaryTextDelta" or method == "item/reasoning/textDelta" then
		consume_steering_instructions()
		set_status("thinking")
	elseif method == "item/commandExecution/outputDelta" then
		append_action_output(params.itemId, params.delta or "")
		set_status("running command")
	elseif method == "item/mcpToolCall/progress" then
		append_chat_block(function(chat)
			return chat:update_item_progress(params.itemId, params.message)
		end)
		set_status(params.message or "using tool")
	elseif method == "item/completed" then
		flush_output_text()
		flush_action_output()
		local item = params.item or {}
		if item.id then
			state.items[item.id] = item
		end
		if action.kind(item) then
			append_chat_block(function(chat)
				return chat:complete_item(item)
			end)
		elseif item.type == "agentMessage" then
			if not state.streamed_items[item.id] and item.text and item.text ~= "" then
				local block_id = ensure_agent_item(item.id)
				append_text(block_id, item.text)
			end
		elseif not state.streamed_items[item.id] then
			append_chat_block(function(chat)
				return chat:add_item(item)
			end)
		end
		set_status("working")
	elseif method == "turn/diff/updated" then
		state.diff = params.diff or state.diff
	elseif method == "thread/tokenUsage/updated" then
		local context_window = params.tokenUsage and params.tokenUsage.modelContextWindow
		if not present(context_window) then
			context_window = nil
		end
		state.tokens = params.tokenUsage
				and vim.tbl_extend("force", params.tokenUsage.total or {}, {
					modelContextWindow = context_window,
				})
			or state.tokens
		update_chrome()
	elseif method == "model/rerouted" then
		state.model = params.toModel or state.model
		append_notice("notice", ("Model changed from `%s` to `%s`."):format(params.fromModel or "unknown", state.model))
		update_chrome()
	elseif method == "error" then
		local message = params.error and params.error.message or "Codex error"
		append_notice("error", message)
		set_status(params.willRetry and "retrying" or "error")
	elseif method == "warning" or method == "configWarning" then
		local message = params.message or params.warning or "Codex warning"
		append_notice("warning", message)
	elseif method == "thread/compacted" then
		append_notice("notice", "Conversation context compacted.")
		set_status("ready")
	elseif method == "turn/completed" then
		flush_output_text()
		flush_action_output()
		local instructions_changed = clear_pending_instructions("steer", false)
		local turn = params.turn or {}
		state.busy = false
		state.turn_id = nil
		reset_output_position()
		if turn.status == "failed" and turn.error then
			append_notice("error", turn.error.message or "Turn failed")
		end
		set_status(turn.status or "completed")
		if instructions_changed then
			update_chrome()
		end
		output_ui.schedule_refresh(state, performance_delay("semantic_debounce_ms", 200))
		refresh_threads()
		drain_queue()
	elseif method == "thread/name/updated" or method == "thread/archived" or method == "thread/unarchived" then
		refresh_threads()
	end
end

local function handle_stderr(data)
	for _, entry in ipairs(server_log.parse(data)) do
		-- Model catalog refreshes run independently of turns. Their timeout is
		-- non-actionable here; explicit model/list failures still notify users.
		if not server_log.is_background_noise(entry) then
			if state and valid_buf(state.output_buf) then
				append_notice(entry.kind, entry.message, {
					lines = entry.lines,
					metadata = entry.metadata,
				})
			else
				notify(entry.message, entry.kind == "error" and vim.log.levels.ERROR or vim.log.levels.WARN)
			end
		end
	end
end

local function handle_request(method, params, reply)
	if state and params.itemId and state.items[params.itemId] then
		params = vim.tbl_extend("force", vim.deepcopy(params), { item = state.items[params.itemId] })
	end
	return requests.handle(method, params, reply)
end

local function client_handlers()
	return {
		on_notification = M._handle_notification,
		on_request = handle_request,
		on_stderr = handle_stderr,
		on_error = function(message)
			notify(message, vim.log.levels.ERROR)
		end,
		on_exit = function(_, message)
			if state then
				state.busy = false
				state.turn_id = nil
				reset_output_position()
				set_status("disconnected")
				append_notice("warning", message)
			end
		end,
	}
end

local function bind_client(instance)
	if instance and instance.set_handlers then
		instance:set_handlers(client_handlers())
	end
end

local function make_client()
	local options = {
		command = config.command,
		timeout_ms = config.timeout_ms,
		client_info = config.client_info,
		capabilities = config.capabilities,
		service_name = config.service_name,
	}
	local instance = Codex.new(vim.tbl_extend("force", options, client_handlers()))
	return instance
end

local function command_range(command)
	if command.range and command.range > 0 then
		return { line1 = command.line1, line2 = command.line2 }
	end
end

local function create_command(name, callback, opts)
	opts = vim.tbl_extend("force", opts or {}, { force = true })
	vim.api.nvim_create_user_command(name, callback, opts)
end

local function schedule_composer_sync()
	if
		not state
		or state.composer_layout_pending
		or not valid_win(state.output_host_win)
		or not valid_win(state.output_win)
		or not composer.is_open(state, state.output_host_win)
	then
		return
	end
	local request_state = state
	state.composer_layout_pending = true
	vim.schedule(function()
		if state ~= request_state then
			return
		end
		state.composer_layout_pending = false
		sync_composer()
	end)
end

local function defer_semantic_refresh()
	if state and state.output_refresh_pending and not state.busy then
		output_ui.schedule_refresh(state, performance_delay("semantic_debounce_ms", 200))
	end
end

local function schedule_output_cursor_update()
	if not state or state.cursor_update_pending or not valid_win(state.output_win) then
		return
	end
	defer_semantic_refresh()
	local request_state = state
	state.cursor_update_pending = true
	vim.defer_fn(function()
		if state ~= request_state then
			return
		end
		state.cursor_update_pending = false
		if valid_win(state.output_win) and valid_buf(state.output_buf) then
			output_ui.cursor_moved(state)
			update_output_winbar()
		end
	end, performance_delay("cursor_interval_ms", 16))
end

local function register_commands()
	local function output_action(callback)
		return function()
			if not state then
				M.open()
			end
			callback(state)
		end
	end

	create_command("AcpChat", function(command)
		M.open({ prompt = command.args ~= "" and command.args or nil, range = command_range(command) })
	end, { nargs = "*", range = true })
	create_command("AcpNew", function(command)
		M.open({ new = true, prompt = command.args ~= "" and command.args or nil, range = command_range(command) })
	end, { nargs = "*", range = true })
	create_command("AcpThreads", open_threads)
	create_command("AcpSessions", M.focus_sessions)
	create_command("AcpAddContext", function(command)
		if not state then
			M.open()
		end
		add_context_from_source(command_range(command), command.range == 0)
	end, { range = true })
	create_command("AcpAddFile", function()
		if not state then
			M.open()
		end
		add_context_from_source(nil, true)
	end)
	create_command("AcpModel", select_model)
	create_command("AcpReasoning", select_reasoning)
	create_command("AcpReview", function(command)
		start_review(command.args ~= "" and command.args or nil)
	end, { nargs = "*" })
	create_command("AcpDiff", M.open_diff)
	create_command("AcpOutput", output_action(output_ui.open_outline))
	create_command("AcpOutputMap", output_action(output_ui.open_map))
	create_command("AcpOutputSearch", output_action(output_ui.search))
	create_command("AcpOutputItems", output_action(output_ui.open_items))
	create_command("AcpOutputItemsQuickfix", output_action(output_ui.items_quickfix))
	create_command("AcpOutputYank", output_action(output_ui.yank_section))
	create_command("AcpOutputDraft", output_action(output_ui.draft_section))
	create_command("AcpOutputOpen", output_action(output_ui.open_current))
	create_command("AcpOutputInspect", output_action(output_ui.inspect))
	create_command("AcpOutputActions", output_action(output_ui.actions))
	create_command("AcpOutputHelp", output_action(output_ui.help))
	create_command(
		"AcpOutputNextItem",
		output_action(function(value)
			output_ui.jump_item(value, 1)
		end)
	)
	create_command(
		"AcpOutputPrevItem",
		output_action(function(value)
			output_ui.jump_item(value, -1)
		end)
	)
	create_command("AcpCodeBlocks", output_action(output_ui.open_code_blocks))
	create_command("AcpCodeBlocksQuickfix", output_action(output_ui.code_blocks_quickfix))
	create_command("AcpCodeBlockDraft", output_action(output_ui.draft_code_block))
	create_command("AcpCodeBlockYank", output_action(output_ui.yank_code_block))
	create_command("AcpOutputLocations", output_action(output_ui.open_locations))
	create_command("AcpOutputQuickfix", output_action(output_ui.locations_quickfix))
	create_command("AcpOutputProblems", output_action(output_ui.open_problems))
	create_command("AcpActions", M.open_actions)
	create_command("AcpLogin", M.login)
	create_command("AcpSend", M.send)
	create_command("AcpStop", M.stop)
	create_command("AcpClose", M.close)
	create_command("AcpReload", function()
		reloader.reload()
	end)
end

local function register_autocmds()
	local group = vim.api.nvim_create_augroup("acp.nvim", { clear = true })
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = group,
		callback = schedule_composer_sync,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(event)
			local winid = tonumber(event.match)
			if composer.handle_win_closed(state, winid) == "prompt" then
				instructions.stop_spinner(state)
			end
			if state and winid == state.output_win then
				state.output_win = nil
			elseif state and winid == state.output_host_win then
				state.output_host_win = nil
			elseif state and winid == state.sessions_win then
				state.sessions_win = nil
			end
		end,
	})
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			view.define_highlights()
			refresh_output_view(0)
			update_chrome()
		end,
	})
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		callback = function(event)
			if state and event.buf == state.output_buf then
				leave_centered_output_if_moved()
				schedule_output_cursor_update()
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		callback = function(event)
			if state and event.buf == state.input_buf then
				defer_semantic_refresh()
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = group,
		callback = function(event)
			if state and tonumber(event.match) == state.output_win then
				leave_centered_output_if_moved()
				defer_semantic_refresh()
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			instructions.stop_spinner(state)
			if client then
				client:stop()
			end
		end,
	})
end

local function register_runtime()
	treesitter.setup()
	view.define_highlights()
	register_commands()
	register_autocmds()
	if state and valid_buf(state.input_buf) and valid_buf(state.output_buf) then
		create_buffers()
		set_buffer_keymaps()
		state.keymaps_set = true
		open_layout()
	end
	if state then
		if valid_win(state.sessions_win) then
			configure_sessions_window(state.sessions_win)
		end
		if valid_win(state.output_host_win) then
			configure_host_window(state.output_host_win)
		end
		if valid_win(state.output_win) then
			configure_window(state.output_win, true)
		end
		refresh_output_view(0)
		update_chrome()
	end
end

function M.setup(opts)
	if state then
		M._reset()
	elseif client then
		client:stop()
	end
	setup_opts = vim.deepcopy(opts or {})
	config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), setup_opts)
	client = make_client()
	client_managed = true
	register_runtime()
	return M
end

function M.get_config()
	return vim.deepcopy(config)
end

function M._export_runtime()
	if state then
		instructions.stop_spinner(state)
		flush_output_text()
		flush_action_output()
		output_ui.flush_refresh(state)
	end
	return {
		setup_opts = vim.deepcopy(setup_opts),
		config = vim.deepcopy(config),
		client = client,
		client_managed = client_managed,
		state = state,
	}
end

function M._adopt_runtime(runtime)
	if type(runtime) ~= "table" then
		error("Invalid acp.nvim runtime")
	end
	setup_opts = vim.deepcopy(runtime.setup_opts or {})
	if runtime.setup_opts ~= nil then
		config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), setup_opts)
	else
		config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), runtime.config or {})
	end
	local previous_state = runtime.state
	local had_chat = type(previous_state) == "table" and type(previous_state.chat) == "table"
	state = apply_state_defaults(previous_state)
	if state then
		if had_chat then
			state.chat = blocks.adopt(state.chat)
		else
			state.chat = blocks.new()
		end
		if valid_buf(state.output_buf) then
			blocks.bind(state.output_buf, state.chat)
			local current = vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false)
			local expected = state.chat:render_lines()
			if not vim.deep_equal(current, expected) then
				set_output(expected, { preserve_view = true })
			end
		end
	end
	client = runtime.client
	client_managed = runtime.client_managed == true
	if client_managed and client then
		client = Codex.adopt(client)
	end
	bind_client(client)
	register_runtime()
	return M
end

function M._state()
	return state
end

function M._client()
	return client
end

function M._set_client(value, opts)
	opts = opts or {}
	if client and client ~= value and client.stop then
		client:stop()
	end
	client = value
	client_managed = opts.managed == true
	bind_client(client)
end

function M._reset()
	if client and client.stop then
		client:stop()
	end
	if state then
		local buffers = {
			state.sessions_buf,
			state.output_host_buf,
			state.input_buf,
			state.instruction_buf,
			state.output_buf,
		}
		M.close()
		blocks.unbind(state.output_buf)
		for _, bufnr in pairs(buffers) do
			if valid_buf(bufnr) then
				pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
			end
		end
	end
	state = nil
	client = nil
	client_managed = false
end

return M
