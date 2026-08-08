local Codex = require("acp.codex").Client
local context = require("acp.context")
local render = require("acp.render")
local requests = require("acp.requests")

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
	thread_sources = { "appServer", "vscode" },
	max_threads = 100,
	window = {
		input_height = 6,
	},
}

local config = vim.deepcopy(defaults)
local client
local state

local select_model
local select_reasoning
local open_threads
local start_review
local compact_thread
local show_status
local drain_queue

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

local function escaped_winbar(text)
	return tostring(text or ""):gsub("%%", "%%%%")
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
		diff = "",
		streamed_items = {},
		items = {},
		agent_item = nil,
		plan_item = nil,
		models = nil,
		threads = nil,
		tokens = nil,
	}
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

local function at_output_bottom()
	if not state or not valid_win(state.output_win) or not valid_buf(state.output_buf) then
		return false
	end
	local cursor = vim.api.nvim_win_get_cursor(state.output_win)[1]
	return cursor >= vim.api.nvim_buf_line_count(state.output_buf) - 2
end

local function follow_output(was_at_bottom)
	if not was_at_bottom or not valid_win(state.output_win) or not valid_buf(state.output_buf) then
		return
	end
	pcall(vim.api.nvim_win_set_cursor, state.output_win, { vim.api.nvim_buf_line_count(state.output_buf), 0 })
end

local function set_output(lines)
	if not state or not valid_buf(state.output_buf) then
		return
	end
	with_modifiable(state.output_buf, function()
		vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, lines)
	end)
	follow_output(true)
end

local function append_lines(lines)
	if not state or not valid_buf(state.output_buf) or type(lines) ~= "table" or #lines == 0 then
		return
	end
	local follow = at_output_bottom()
	local values = {}
	for _, line in ipairs(lines) do
		table.insert(values, tostring(line or ""))
	end
	with_modifiable(state.output_buf, function()
		vim.api.nvim_buf_set_lines(state.output_buf, -1, -1, false, values)
	end)
	follow_output(follow)
end

local function append_text(text)
	if not state or not valid_buf(state.output_buf) or not text or text == "" then
		return
	end
	local follow = at_output_bottom()
	local parts = vim.split(text, "\n", { plain = true })
	with_modifiable(state.output_buf, function()
		local count = vim.api.nvim_buf_line_count(state.output_buf)
		local last = vim.api.nvim_buf_get_lines(state.output_buf, count - 1, count, false)[1] or ""
		parts[1] = last .. parts[1]
		vim.api.nvim_buf_set_lines(state.output_buf, count - 1, count, false, parts)
	end)
	follow_output(follow)
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

local function update_chrome()
	if not state then
		return
	end
	local model = state.model or "default model"
	local effort = state.effort and (" · " .. state.effort) or ""
	local usage = ""
	if state.tokens then
		local total = state.tokens.totalTokens or 0
		local window = state.tokens.modelContextWindow
		usage = window and (" · %d/%d tokens"):format(total, window) or (" · %d tokens"):format(total)
	end
	if valid_win(state.output_win) then
		vim.wo[state.output_win].winbar =
			escaped_winbar((" Codex · %s%s · %s%s "):format(model, effort, state.status or "idle", usage))
	end
	if valid_win(state.input_win) then
		local context_count = #(state.contexts or {})
		local queued = #state.queue > 0 and (" · %d queued"):format(#state.queue) or ""
		vim.wo[state.input_win].winbar = escaped_winbar(
			(" Prompt · %d context%s%s · <C-s> send "):format(context_count, context_count == 1 and "" or "s", queued)
		)
	end
end

local function set_status(status)
	if not state then
		return
	end
	state.status = status
	update_chrome()
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
	local current_win = vim.api.nvim_get_current_win()
	local current_tab = vim.api.nvim_get_current_tabpage()
	local chat_tab = valid_tab(state.tabpage) and state.tabpage or nil
	local return_win = chat_tab == current_tab and state.origin_win or current_win
	if not close_tab(chat_tab, return_win) then
		close_window(state.input_win)
		if valid_win(state.output_win) then
			local output_tab = vim.api.nvim_win_get_tabpage(state.output_win)
			if #vim.api.nvim_list_tabpages() == 1 and #vim.api.nvim_tabpage_list_wins(output_tab) == 1 then
				vim.api.nvim_set_current_win(state.output_win)
				vim.cmd("enew!")
			else
				close_window(state.output_win)
			end
		end
	end
	state.input_win = nil
	state.output_win = nil
	state.tabpage = nil
	if valid_win(return_win) then
		pcall(vim.api.nvim_set_current_win, return_win)
	elseif valid_tab(state.origin_tab) then
		pcall(vim.api.nvim_set_current_tabpage, state.origin_tab)
	end
end

local function create_buffers()
	local created = false
	if not valid_buf(state.output_buf) then
		created = true
		state.output_buf = vim.api.nvim_create_buf(false, true)
		pcall(vim.api.nvim_buf_set_name, state.output_buf, "acp://codex/chat")
		vim.bo[state.output_buf].buftype = "nofile"
		vim.bo[state.output_buf].bufhidden = "hide"
		vim.bo[state.output_buf].swapfile = false
		vim.bo[state.output_buf].filetype = "markdown"
		vim.bo[state.output_buf].modifiable = false
		set_output(render.thread({ turns = {} }, state.cwd))
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
		vim.wo[winid].conceallevel = 2
	end
end

local function open_layout()
	if
		valid_win(state.output_win)
		and valid_win(state.input_win)
		and vim.api.nvim_win_get_tabpage(state.output_win) == vim.api.nvim_win_get_tabpage(state.input_win)
	then
		state.tabpage = vim.api.nvim_win_get_tabpage(state.output_win)
		vim.api.nvim_win_set_buf(state.output_win, state.output_buf)
		vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
		configure_window(state.output_win, true)
		configure_window(state.input_win, false)
		update_chrome()
		focus_input(false)
		return
	end

	local previous_output = state.output_win
	local previous_input = state.input_win
	local tabpage = valid_tab(state.tabpage) and state.tabpage or nil
	if not tabpage then
		vim.cmd("tabnew")
		tabpage = vim.api.nvim_get_current_tabpage()
	else
		vim.api.nvim_set_current_tabpage(tabpage)
	end

	local output_win
	for _, winid in ipairs({ previous_output, previous_input }) do
		if valid_win(winid) and vim.api.nvim_win_get_tabpage(winid) == tabpage then
			output_win = winid
			break
		end
	end
	output_win = output_win or vim.api.nvim_tabpage_list_wins(tabpage)[1]
	for _, winid in ipairs({ previous_output, previous_input }) do
		if valid_win(winid) and winid ~= output_win then
			close_window(winid)
		end
	end

	state.tabpage = tabpage
	state.output_win = output_win
	state.input_win = nil
	vim.api.nvim_set_current_win(state.output_win)
	vim.api.nvim_win_set_buf(state.output_win, state.output_buf)
	configure_window(state.output_win, true)

	vim.cmd(("belowright %dsplit"):format(math.max(3, tonumber(config.window.input_height) or 6)))
	state.input_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
	configure_window(state.input_win, false)
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

local function ensure_agent_item(item_id)
	if state.agent_item == item_id then
		return
	end
	state.agent_item = item_id
	append_lines({ "", "## Codex", "" })
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
	state.plan_item = nil
	state.contexts = {}
	state.queue = {}
	local turn = active_turn(thread)
	state.turn_id = turn and turn.id or nil
	state.busy = turn ~= nil
	set_output(render.thread(thread, state.cwd))
	set_status(state.busy and "running" or "ready")
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
			append_lines({ "", ("> Error: %s"):format(message), "" })
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
	append_lines({ "", ("## You%s"):format(suffix or ""), "" })
	append_lines(vim.split(envelope.text, "\n", { plain = true }))
	if #envelope.labels > 0 then
		append_lines({ "", ("> Context: %s"):format(table.concat(envelope.labels, ", ")) })
	end
end

local function start_envelope(envelope)
	state.busy = true
	state.agent_item = nil
	state.plan_item = nil
	state.streamed_items = {}
	state.items = {}
	append_user(envelope)
	set_status("starting turn")
	client:start_turn(state.thread_id, envelope.payload, function(result, err)
		if err or type(result) ~= "table" or type(result.turn) ~= "table" then
			state.busy = false
			state.turn_id = nil
			set_status("error")
			append_lines({ "", ("> Error: %s"):format(err or "Codex did not start the turn"), "" })
			drain_queue()
			return
		end
		state.turn_id = result.turn.id
		state.busy = true
		set_status("running")
	end)
end

local function dispatch_prompt(envelope)
	ensure_thread(function(ok)
		if not ok then
			return
		end
		if state.busy then
			if config.follow_up == "steer" and state.turn_id then
				append_user(envelope, " (steer)")
				set_status("steering")
				client:steer_turn(state.thread_id, state.turn_id, envelope.payload, function(_, err)
					if err then
						append_lines({ "", ("> Steer failed: %s"):format(err), "" })
					end
					set_status(err and "running" or "steered")
				end)
			else
				table.insert(state.queue, envelope)
				append_lines({ "", ("> Queued follow-up %d."):format(#state.queue), "" })
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
	else
		return false
	end
	return true
end

function M.send()
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
	dispatch_prompt(envelope)
end

local function set_buffer_keymaps()
	local opts = { buffer = state.input_buf, silent = true }
	vim.keymap.set({ "n", "i" }, "<C-s>", M.send, vim.tbl_extend("force", opts, { desc = "Send Codex prompt" }))
	vim.keymap.set({ "n", "i" }, "<C-CR>", M.send, vim.tbl_extend("force", opts, { desc = "Send Codex prompt" }))
	vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "Close Codex tab" }))

	local output_opts = { buffer = state.output_buf, silent = true }
	vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", output_opts, { desc = "Close Codex tab" }))
	vim.keymap.set("n", "i", function()
		focus_input(true)
	end, vim.tbl_extend("force", output_opts, { desc = "Focus Codex prompt" }))
	vim.keymap.set("n", "n", M.new_chat, vim.tbl_extend("force", output_opts, { desc = "New Codex chat" }))
	vim.keymap.set("n", "t", function()
		open_threads()
	end, vim.tbl_extend("force", output_opts, { desc = "Open Codex threads" }))
	vim.keymap.set("n", "d", M.open_diff, vim.tbl_extend("force", output_opts, { desc = "Open Codex diff" }))
	vim.keymap.set("n", "m", function()
		select_model()
	end, vim.tbl_extend("force", output_opts, { desc = "Select Codex model" }))
	vim.keymap.set("n", "r", function()
		select_reasoning()
	end, vim.tbl_extend("force", output_opts, { desc = "Select Codex reasoning" }))
	vim.keymap.set("n", "s", M.stop, vim.tbl_extend("force", output_opts, { desc = "Stop Codex turn" }))
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
			output_buf = state.output_buf,
			input_buf = state.input_buf,
			output_win = state.output_win,
			input_win = state.input_win,
			tabpage = state.tabpage,
			origin_win = state.origin_win,
			origin_tab = state.origin_tab,
			source_buf = state.source_buf,
			source_win = state.source_win,
			keymaps_set = state.keymaps_set,
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
		set_output(render.thread({ turns = {} }, state.cwd))
	end
	if valid_buf(state.input_buf) then
		set_input("")
	end
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

local function refresh_threads(callback)
	set_status("loading threads")
	client:list_threads({
		cwd = state.cwd,
		source_kinds = config.thread_sources,
		max_threads = config.max_threads,
	}, function(threads, err)
		if err then
			set_status(state.busy and "running" or "ready")
			notify(err, vim.log.levels.ERROR)
			if callback then
				callback(nil)
			end
			return
		end
		state.threads = threads
		set_status(state.busy and "running" or "ready")
		if callback then
			callback(threads)
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
		state.busy = true
		set_status("starting review")
		client:review(state.thread_id, target, config.review_delivery, function(result, err)
			if err or type(result) ~= "table" then
				state.busy = false
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
		{ label = "Compact context", run = compact_thread },
		{ label = "Show status", run = show_status },
		{ label = "Stop active turn", run = M.stop },
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
		state.busy = true
		state.turn_id = params.turn and params.turn.id or state.turn_id
		set_status("running")
	elseif method == "item/started" then
		local item = params.item or {}
		if item.id then
			state.items[item.id] = item
		end
		if item.type == "agentMessage" then
			ensure_agent_item(item.id)
		end
		set_status(render.item_status(item))
	elseif method == "item/agentMessage/delta" then
		ensure_agent_item(params.itemId)
		state.streamed_items[params.itemId] = true
		append_text(params.delta or "")
		set_status("responding")
	elseif method == "item/plan/delta" then
		if state.plan_item ~= params.itemId then
			state.plan_item = params.itemId
			append_lines({ "", "### Plan", "" })
		end
		state.streamed_items[params.itemId] = true
		append_text(params.delta or "")
		set_status("planning")
	elseif method == "item/reasoning/summaryTextDelta" or method == "item/reasoning/textDelta" then
		set_status("thinking")
	elseif method == "item/commandExecution/outputDelta" then
		set_status("running command")
	elseif method == "item/completed" then
		local item = params.item or {}
		if item.id then
			state.items[item.id] = item
		end
		if item.type == "agentMessage" then
			if not state.streamed_items[item.id] and item.text and item.text ~= "" then
				ensure_agent_item(item.id)
				append_text(item.text)
			end
		elseif not state.streamed_items[item.id] then
			append_lines(render.completed_item(item))
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
		append_lines({
			"",
			("> Model changed from `%s` to `%s`."):format(params.fromModel or "unknown", state.model),
			"",
		})
		update_chrome()
	elseif method == "error" then
		local message = params.error and params.error.message or "Codex error"
		append_lines({ "", ("> Error: %s"):format(message), "" })
		set_status(params.willRetry and "retrying" or "error")
	elseif method == "warning" or method == "configWarning" then
		local message = params.message or params.warning or "Codex warning"
		append_lines({ "", ("> Warning: %s"):format(message), "" })
	elseif method == "thread/compacted" then
		append_lines({ "", "> Conversation context compacted.", "" })
		set_status("ready")
	elseif method == "turn/completed" then
		local turn = params.turn or {}
		state.busy = false
		state.turn_id = nil
		if turn.status == "failed" and turn.error then
			append_lines({ "", ("> Error: %s"):format(turn.error.message or "Turn failed"), "" })
		end
		set_status(turn.status or "completed")
		refresh_threads()
		drain_queue()
	elseif method == "thread/name/updated" or method == "thread/archived" or method == "thread/unarchived" then
		refresh_threads()
	end
end

local function handle_stderr(data)
	local text = tostring(data):gsub("%s+$", "")
	if text == "" or text:find("could not create PATH aliases", 1, true) then
		return
	end
	if state and valid_buf(state.output_buf) then
		append_lines({ "", ("> Server: %s"):format(text:gsub("\n", " ")), "" })
	else
		notify(text, vim.log.levels.WARN)
	end
end

local function handle_request(method, params, reply)
	if state and params.itemId and state.items[params.itemId] then
		params = vim.tbl_extend("force", vim.deepcopy(params), { item = state.items[params.itemId] })
	end
	return requests.handle(method, params, reply)
end

local function make_client()
	local instance = Codex.new({
		command = config.command,
		timeout_ms = config.timeout_ms,
		client_info = config.client_info,
		capabilities = config.capabilities,
		service_name = config.service_name,
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
				set_status("disconnected")
				append_lines({ "", ("> %s"):format(message), "" })
			end
		end,
	})
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

function M.setup(opts)
	if state then
		M._reset()
	elseif client then
		client:stop()
	end
	config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	client = make_client()

	create_command("AcpChat", function(command)
		M.open({ prompt = command.args ~= "" and command.args or nil, range = command_range(command) })
	end, { nargs = "*", range = true })
	create_command("AcpNew", function(command)
		M.open({ new = true, prompt = command.args ~= "" and command.args or nil, range = command_range(command) })
	end, { nargs = "*", range = true })
	create_command("AcpThreads", open_threads)
	create_command("AcpSessions", open_threads)
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
	create_command("AcpActions", M.open_actions)
	create_command("AcpLogin", M.login)
	create_command("AcpSend", M.send)
	create_command("AcpStop", M.stop)
	create_command("AcpClose", M.close)

	local group = vim.api.nvim_create_augroup("acp.nvim", { clear = true })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			if client then
				client:stop()
			end
		end,
	})
	return M
end

function M.get_config()
	return vim.deepcopy(config)
end

function M._state()
	return state
end

function M._client()
	return client
end

function M._set_client(value)
	if client and client ~= value and client.stop then
		client:stop()
	end
	client = value
	if client and client.set_handlers then
		client:set_handlers({
			on_notification = M._handle_notification,
			on_request = handle_request,
		})
	end
end

function M._reset()
	if client and client.stop then
		client:stop()
	end
	if state then
		local buffers = { state.input_buf, state.output_buf }
		M.close()
		for _, bufnr in ipairs(buffers) do
			if valid_buf(bufnr) then
				pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
			end
		end
	end
	state = nil
	client = nil
end

return M
