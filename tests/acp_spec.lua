local approval = require("acp.approval")
local Client = require("acp.codex").Client
local context = require("acp.context")
local health = require("acp.health")
local jsonrpc = require("acp.jsonrpc")
local permission = require("acp.permission")
local render = require("acp.render")
local requests = require("acp.requests")
local ui = require("acp.ui")

local tests = {}

local function test(name, callback)
	table.insert(tests, { name = name, callback = callback })
end

local function eq(actual, expected)
	if not vim.deep_equal(actual, expected) then
		error(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)), 2)
	end
end

local function ok(value, message)
	if not value then
		error(message or "expected truthy value", 2)
	end
end

local function contains(text, fragment)
	ok(tostring(text):find(fragment, 1, true), ("expected %q to contain %q"):format(text, fragment))
end

local function count(text, fragment)
	local total = 0
	local start = 1
	while true do
		local first, last = text:find(fragment, start, true)
		if not first then
			return total
		end
		total = total + 1
		start = last + 1
	end
end

local function fake_process()
	local process = { writes = {} }
	local handle = {}

	function handle:write(data)
		for line in data:gmatch("[^\n]+") do
			table.insert(process.writes, vim.json.decode(line))
		end
	end

	function handle:kill(signal)
		process.killed = signal
	end

	process.spawn = function(command, options, on_exit)
		process.command = command
		process.options = options
		process.on_exit = on_exit
		return handle
	end

	return process
end

local function with_permission_select(replacement, callback)
	local original = permission.select
	permission.select = replacement
	local passed, err = pcall(callback)
	permission.select = original
	if not passed then
		error(err, 2)
	end
end

test("app-server messages omit the JSON-RPC version field", function()
	local request = jsonrpc.request(1, "thread/list", { limit = 10 })
	local notification = jsonrpc.notification("initialized")
	local response = jsonrpc.result(1, { ready = true })

	eq(request.method, "thread/list")
	eq(request.params.limit, 10)
	eq(request.jsonrpc, nil)
	eq(notification.method, "initialized")
	eq(notification.params, nil)
	eq(notification.jsonrpc, nil)
	eq(response.result.ready, true)
end)

test("line buffer emits complete non-empty JSONL records", function()
	local lines = {}
	local buffer = jsonrpc.LineBuffer.new()
	buffer:push('{"one":1}\n{"two":', function(line)
		table.insert(lines, line)
	end)
	buffer:push("2}\r\n\n", function(line)
		table.insert(lines, line)
	end)
	eq(lines, { '{"one":1}', '{"two":2}' })
	buffer:reset()
	eq(buffer.data, "")
end)

test("client performs the app-server handshake in order", function()
	local process = fake_process()
	local client = Client.new({ command = "codex", spawn = process.spawn })
	local initialized

	client:initialize(function(success, result)
		initialized = { success = success, result = result }
	end)

	eq(process.command, { "codex", "app-server" })
	eq(#process.writes, 1)
	eq(process.writes[1].method, "initialize")
	eq(process.writes[1].params.clientInfo.name, "acp_nvim")
	eq(process.writes[1].params.capabilities, nil)
	eq(initialized, nil)

	client:handle_message({ id = 0, result = { serverInfo = { name = "codex" } } })
	eq(process.writes[2].method, "initialized")
	eq(initialized.success, true)
	eq(initialized.result.serverInfo.name, "codex")
	client:stop()
	eq(process.killed, 15)
end)

test("requests wait for initialization and route responses", function()
	local process = fake_process()
	local client = Client.new({ spawn = process.spawn })
	local models

	client:list_models(function(result, err)
		eq(err, nil)
		models = result
	end)
	eq(#process.writes, 1)
	eq(process.writes[1].method, "initialize")

	client:handle_message({ id = 0, result = { serverInfo = {} } })
	eq(process.writes[2].method, "initialized")
	eq(process.writes[3].method, "model/list")
	client:handle_message({ id = 1, result = { data = { { id = "gpt-test" } }, nextCursor = vim.NIL } })
	eq(models[1].id, "gpt-test")
	eq(#process.writes, 3)
	client:stop()
end)

test("turn requests use the current stable app-server shape", function()
	local process = fake_process()
	local client = Client.new({ spawn = process.spawn })
	client:start()
	client.initialized = true

	client:start_turn("thread-1", {
		text = "fix this",
		cwd = "/tmp/project",
		model = "gpt-test",
		effort = "high",
		additional_context = {
			["nvim:1"] = { kind = "application", value = "Selected line" },
		},
	}, function() end)

	local message = process.writes[1]
	eq(message.method, "turn/start")
	eq(message.params.threadId, "thread-1")
	eq(message.params.input[1], { type = "text", text = "fix this", text_elements = {} })
	eq(message.params.cwd, "/tmp/project")
	eq(message.params.model, "gpt-test")
	eq(message.params.effort, "high")
	eq(message.params.additionalContext["nvim:1"].kind, "application")
	client:stop()
end)

test("thread listing paginates and preserves extension sources", function()
	local process = fake_process()
	local client = Client.new({ spawn = process.spawn })
	client:start()
	client.initialized = true
	local threads

	client:list_threads({
		cwd = "/tmp/project",
		source_kinds = { "appServer", "vscode" },
		max_threads = 3,
	}, function(result)
		threads = result
	end)

	eq(process.writes[1].params.cwd, "/tmp/project")
	eq(process.writes[1].params.sourceKinds, { "appServer", "vscode" })
	client:handle_message({ id = 0, result = { data = { { id = "a" } }, nextCursor = "next" } })
	eq(process.writes[2].params.cursor, "next")
	client:handle_message({ id = 1, result = { data = { { id = "b" } }, nextCursor = vim.NIL } })
	eq({ threads[1].id, threads[2].id }, { "a", "b" })
	eq(#process.writes, 2)
	client:stop()
end)

test("client dispatches notifications and replies to server requests", function()
	local process = fake_process()
	local notification
	local client = Client.new({
		spawn = process.spawn,
		on_notification = function(method, params)
			notification = { method = method, params = params }
		end,
		on_request = function(method, params, reply)
			eq(method, "test/request")
			reply({ echoed = params.value })
			return true
		end,
	})
	client:start()
	client.initialized = true

	client:handle_message({ method = "test/event", params = { value = 3 } })
	eq(notification, { method = "test/event", params = { value = 3 } })
	client:handle_message({ id = 7, method = "test/request", params = { value = 4 } })
	eq(process.writes[1], { id = 7, result = { echoed = 4 } })

	client.on_request = nil
	client:handle_message({ id = 8, method = "unknown/request" })
	eq(process.writes[2].error.code, jsonrpc.errors.method_not_found)
	client:stop()
end)

test("editor context becomes mentions and bounded application context", function()
	local bufnr = vim.api.nvim_create_buf(false, false)
	vim.bo[bufnr].swapfile = false
	local path = vim.fn.getcwd() .. "/lua/acp/example.lua"
	vim.api.nvim_buf_set_name(bufnr, path)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three", "four" })

	local file = context.file(bufnr, vim.fn.getcwd())
	local selection = context.selection(bufnr, { line1 = 2, line2 = 4 }, vim.fn.getcwd(), { max_lines = 2 })
	local contexts = {}
	eq(context.add(contexts, file), true)
	eq(context.add(contexts, file), false)
	eq(context.add(contexts, selection), true)

	local input, additional, labels = context.turn_payload(contexts)
	eq(input[1], { type = "mention", name = "example.lua", path = path })
	contains(additional["nvim:2"].value, "lines 2-4")
	contains(additional["nvim:2"].value, "selection truncated")
	eq(labels, { "lua/acp/example.lua", "lua/acp/example.lua:2-4" })
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("thread renderer reconstructs history and diffs", function()
	local thread = {
		id = "thread-1",
		preview = "Fix the parser",
		updatedAt = 1,
		turns = {
			{
				items = {
					{ type = "userMessage", content = { { type = "text", text = "Please fix it" } } },
					{
						type = "commandExecution",
						command = "\27[31mnvim --headless\27[0m",
						status = "completed",
						exitCode = 0,
					},
					{
						type = "fileChange",
						status = "completed",
						changes = {
							{
								path = "lua/acp/ui.lua",
								kind = { type = "update", move_path = vim.NIL },
								diff = "--- a\n+++ b",
							},
						},
					},
					{ type = "agentMessage", text = "Done." },
				},
			},
		},
	}
	local text = table.concat(render.thread(thread, "/tmp/project"), "\n")
	contains(text, "# Codex")
	contains(text, "## You")
	contains(text, "Please fix it")
	contains(text, "nvim --headless")
	ok(not text:find("\27", 1, true), "ANSI escape sequences should be removed")
	contains(text, "lua/acp/ui.lua")
	contains(text, "## Codex")
	contains(text, "Done.")
	eq(render.thread_diff(thread), "--- a\n+++ b")
	contains(render.thread_label(thread), "Fix the parser")
end)

test("approval requests return Codex decision payloads", function()
	local captured
	with_permission_select(function(params, callback)
		captured = params
		callback(params.options[2])
	end, function()
		local response
		ok(approval.handle("item/commandExecution/requestApproval", {
			command = "git status",
			cwd = "/tmp/project",
			reason = "Inspect the worktree",
			availableDecisions = { "accept", "acceptForSession", "decline", "cancel" },
		}, function(result)
			response = result
		end))
		eq(captured.toolCall.title, "git status")
		eq(response, { decision = "acceptForSession" })
	end)
end)

test("file approvals show the affected files", function()
	with_permission_select(function(params, callback)
		local text = table.concat(permission.lines(params), "\n")
		contains(text, "Apply changes to 2 file(s)")
		contains(text, "lua/acp/ui.lua")
		contains(text, "lua/acp/codex.lua")
		callback(params.options[1])
	end, function()
		local response
		approval.handle("item/fileChange/requestApproval", {
			reason = "Apply the proposed patch",
			item = {
				changes = {
					{ path = "lua/acp/ui.lua" },
					{ path = "lua/acp/codex.lua" },
				},
			},
		}, function(result)
			response = result
		end)
		eq(response, { decision = "accept" })
	end)
end)

test("server input requests use native Neovim selectors", function()
	local original_select = vim.ui.select
	local original_input = vim.ui.input
	vim.ui.select = function(items, _, callback)
		callback(items[2])
	end
	vim.ui.input = function(_, callback)
		callback("free form")
	end
	local response
	local passed, err = pcall(function()
		ok(requests.handle("item/tool/requestUserInput", {
			questions = {
				{
					id = "choice",
					header = "Approach",
					question = "Which approach?",
					options = { { label = "A" }, { label = "B" } },
				},
				{ id = "note", header = "Note", question = "Anything else?" },
			},
		}, function(result)
			response = result
		end))
	end)
	vim.ui.select = original_select
	vim.ui.input = original_input
	if not passed then
		error(err, 2)
	end
	eq(response.answers.choice.answers, { "B" })
	eq(response.answers.note.answers, { "free form" })
end)

test("permission profile requests can grant the turn", function()
	with_permission_select(function(params, callback)
		callback(params.options[1])
	end, function()
		local response
		ok(requests.handle("item/permissions/requestApproval", {
			cwd = "/tmp/project",
			reason = "Needs network access",
			permissions = { network = { enabled = true } },
		}, function(result)
			response = result
		end))
		eq(response.scope, "turn")
		eq(response.permissions.network.enabled, true)
	end)
end)

test("permission UI is Codex-specific and self-contained", function()
	local lines = permission.lines({
		toolCall = { title = "Run tests", kind = "command", location = "/tmp/project" },
		options = { { optionId = "accept", name = "Allow once" } },
	})
	local text = table.concat(lines, "\n")
	contains(text, "Codex permission request")
	contains(text, "Run tests")
	contains(text, "Allow once")
	contains(text, "1-9 to choose")
end)

test("closing a permission buffer cancels the request", function()
	local selected = "pending"
	local bufnr = permission.select({
		toolCall = { title = "Run tests" },
		options = { { optionId = "accept", name = "Allow once" } },
	}, function(option)
		selected = option
	end)
	vim.api.nvim_buf_delete(bufnr, { force = true })
	eq(selected, nil)
end)

test("setup exposes only the focused Codex command surface", function()
	ui.setup({ command = { "codex", "app-server" } })
	for _, command in ipairs({
		"AcpChat",
		"AcpNew",
		"AcpThreads",
		"AcpSessions",
		"AcpAddContext",
		"AcpAddFile",
		"AcpModel",
		"AcpReasoning",
		"AcpReview",
		"AcpDiff",
		"AcpActions",
		"AcpLogin",
		"AcpSend",
		"AcpStop",
		"AcpClose",
		"AcpReload",
	}) do
		eq(vim.fn.exists(":" .. command), 2)
	end
	eq(vim.fn.exists(":AcpChatWindow"), 0)
	eq(ui.get_config().command, { "codex", "app-server" })
end)

test("Codex chat uses a dedicated tab and preserves the source layout", function()
	ui._reset()
	ui.setup({ auto_context = false, command = { "missing-codex" } })
	vim.cmd("enew!")
	local origin_tab = vim.api.nvim_get_current_tabpage()
	local origin_win = vim.api.nvim_get_current_win()
	local origin_windows = vim.api.nvim_tabpage_list_wins(origin_tab)
	local tab_count = #vim.api.nvim_list_tabpages()

	local passed, err = pcall(function()
		ui.open()
		local state = ui._state()
		local chat_tab = vim.api.nvim_get_current_tabpage()
		ok(chat_tab ~= origin_tab)
		eq(state.tabpage, chat_tab)
		eq(#vim.api.nvim_list_tabpages(), tab_count + 1)
		eq(vim.api.nvim_tabpage_list_wins(origin_tab), origin_windows)
		eq(#vim.api.nvim_tabpage_list_wins(chat_tab), 2)
		eq(vim.api.nvim_win_get_tabpage(state.output_win), chat_tab)
		eq(vim.api.nvim_win_get_tabpage(state.input_win), chat_tab)

		vim.api.nvim_win_close(state.input_win, true)
		ui.open()
		state = ui._state()
		eq(vim.api.nvim_get_current_tabpage(), chat_tab)
		eq(state.tabpage, chat_tab)
		eq(#vim.api.nvim_list_tabpages(), tab_count + 1)
		eq(#vim.api.nvim_tabpage_list_wins(chat_tab), 2)
		eq(vim.api.nvim_tabpage_list_wins(origin_tab), origin_windows)

		local chat_windows = vim.api.nvim_tabpage_list_wins(chat_tab)
		state.thread_id = "thread-1"
		state.diff = "--- a/file\n+++ b/file"
		ui.open_diff()
		local diff_tab = vim.api.nvim_get_current_tabpage()
		ok(diff_tab ~= chat_tab)
		eq(#vim.api.nvim_list_tabpages(), tab_count + 2)
		eq(vim.api.nvim_tabpage_list_wins(origin_tab), origin_windows)
		eq(vim.api.nvim_tabpage_list_wins(chat_tab), chat_windows)
		vim.cmd("tabclose!")
		eq(vim.api.nvim_get_current_tabpage(), chat_tab)

		ui.close()
		eq(vim.api.nvim_get_current_tabpage(), origin_tab)
		eq(vim.api.nvim_get_current_win(), origin_win)
		eq(#vim.api.nvim_list_tabpages(), tab_count)
		eq(vim.api.nvim_tabpage_list_wins(origin_tab), origin_windows)
	end)
	ui._reset()
	if not passed then
		error(err, 2)
	end
end)

test("native Codex tab starts a thread, streams a turn, and tracks its diff", function()
	ui._reset()
	ui.setup({ auto_context = false, command = { "missing-codex" } })
	local fake = { turns = {}, stopped = false }

	function fake:set_handlers(handlers)
		self.handlers = handlers
	end

	function fake:start_thread(opts, callback)
		self.thread_opts = opts
		callback({
			thread = { id = "thread-1", cwd = opts.cwd, turns = {} },
			cwd = opts.cwd,
			model = "gpt-test",
			reasoningEffort = "high",
		})
	end

	function fake:start_turn(thread_id, payload, callback)
		table.insert(self.turns, { thread_id = thread_id, payload = payload })
		callback({ turn = { id = "turn-1", status = "inProgress" } })
	end

	function fake:list_threads(_, callback)
		callback({})
	end

	function fake:unsubscribe_thread(thread_id, callback)
		self.unsubscribed = thread_id
		callback({})
	end

	function fake:stop()
		self.stopped = true
	end

	ui._set_client(fake)
	local passed, err = pcall(function()
		ui.open()
		local state = ui._state()
		vim.api.nvim_win_close(state.input_win, true)
		ui.open()
		state = ui._state()
		ok(vim.api.nvim_win_is_valid(state.output_win))
		ok(vim.api.nvim_win_is_valid(state.input_win))
		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "Simplify this plugin" })
		ui.send()

		eq(fake.turns[1].thread_id, "thread-1")
		eq(fake.turns[1].payload.input[1].text, "Simplify this plugin")
		eq(state.busy, true)

		fake.handlers.on_notification("item/agentMessage/delta", {
			threadId = "thread-1",
			turnId = "turn-1",
			itemId = "message-1",
			delta = "Implemented.",
		})
		fake.handlers.on_notification("item/completed", {
			threadId = "thread-1",
			turnId = "turn-1",
			item = { id = "message-1", type = "agentMessage", text = "Implemented." },
		})
		fake.handlers.on_notification("turn/diff/updated", {
			threadId = "thread-1",
			turnId = "turn-1",
			diff = "--- a/file\n+++ b/file",
		})
		fake.handlers.on_notification("thread/tokenUsage/updated", {
			threadId = "thread-1",
			turnId = "turn-1",
			tokenUsage = { total = { totalTokens = 42 }, modelContextWindow = 1000 },
		})
		fake.handlers.on_notification("turn/completed", {
			threadId = "thread-1",
			turn = { id = "turn-1", status = "completed" },
		})

		local output = table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n")
		contains(output, "Simplify this plugin")
		contains(output, "Implemented.")
		eq(count(output, "Implemented."), 1)
		eq(state.diff, "--- a/file\n+++ b/file")
		eq(state.tokens.totalTokens, 42)
		eq(state.busy, false)
		eq(ui.new_chat({ keep_layout = true }), true)
		eq(fake.unsubscribed, "thread-1")
	end)
	ui._reset()
	if not passed then
		error(err, 2)
	end
	eq(fake.stopped, true)
end)

test("health reports the direct app-server architecture", function()
	ui.setup({ command = "sh" })
	local reports = {}
	local original = {
		start = vim.health.start,
		ok = vim.health.ok,
		warn = vim.health.warn,
		error = vim.health.error,
	}
	vim.health.start = function(message)
		table.insert(reports, message)
	end
	vim.health.ok = function(message)
		table.insert(reports, message)
	end
	vim.health.warn = function(message)
		table.insert(reports, message)
	end
	vim.health.error = function(message)
		table.insert(reports, message)
	end
	local passed, err = pcall(health.check)
	for key, value in pairs(original) do
		vim.health[key] = value
	end
	ui._reset()
	if not passed then
		error(err, 2)
	end
	local text = table.concat(reports, "\n")
	contains(text, "Neovim supports vim.system")
	contains(text, "Codex executable found: sh")
	contains(text, "codex app-server directly")
end)

test("hot reload preserves the live client, thread, draft, and Codex tab", function()
	ui._reset()
	ui.setup({ auto_context = false, command = { "missing-codex" } })
	local process = fake_process()
	local live_client = Client.new({ spawn = process.spawn })
	live_client:start()
	live_client.initialized = true
	local pending_result
	live_client:request("test/pending", { value = 1 }, function(result, err)
		pending_result = { result = result, err = err }
	end)
	live_client.line_buffer.data = '{"partial":'
	local pending_requests = live_client.pending
	local line_buffer = live_client.line_buffer
	local process_handle = live_client.handle
	ui._set_client(live_client, { managed = true })
	ui.open()
	local state = ui._state()
	state.thread_id = "thread-hot-reload"
	state.turn_id = "turn-hot-reload"
	state.busy = true
	state.status = "responding"
	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "preserve this draft" })

	local tabpage = state.tabpage
	local output_buf = state.output_buf
	local input_buf = state.input_buf
	local process_client = ui._client()
	local reload = require("acp.reload")
	local current_ui = ui
	local original_export = ui._export_runtime
	local bad_file = vim.fn.tempname() .. ".lua"
	local passed, err = pcall(function()
		vim.fn.writefile({ "local broken =" }, bad_file)
		local preflight, preflight_err = reload.reload({ silent = true, _files = { bad_file } })
		ok(not preflight, "expected invalid Lua to fail reload preflight")
		contains(preflight_err, "Reload preflight failed")
		ok(package.loaded["acp.ui"] == ui, "preflight failure must not unload the UI module")
		ok(ui._client() == process_client, "preflight failure must preserve the app-server client")

		package.preload["acp.ui"] = function()
			error("simulated reload failure")
		end
		local failed, failure = reload.reload({ silent = true })
		package.preload["acp.ui"] = nil
		ok(not failed, "expected the simulated reload to fail")
		contains(failure, "simulated reload failure")
		ok(package.loaded["acp.ui"] == ui, "expected the previous UI module after rollback")
		ok(ui._state() == state, "rollback must preserve the state table")
		ok(ui._client() == process_client, "rollback must preserve the app-server client")
		ok(process.killed == nil, "rollback must not stop the app-server client")

		ui._export_runtime = nil
		local reloaded, new_ui = reload.reload({ silent = true })
		ok(reloaded, new_ui)
		current_ui = new_ui
		ok(new_ui ~= ui, "expected a newly loaded UI module")
		ok(new_ui._state() == state, "expected the same state table")
		ok(new_ui._client() == process_client, "expected the same app-server client")
		ok(live_client.handle == process_handle, "expected the same process handle")
		ok(live_client.pending == pending_requests, "expected the same pending request table")
		ok(live_client.line_buffer == line_buffer, "expected the same stream buffer")
		eq(live_client.line_buffer.data, '{"partial":')
		ok(process.killed == nil, "hot reload must not stop the app-server client")
		ok(getmetatable(live_client) == require("acp.codex").Client, "expected methods from the reloaded client module")
		eq(state.thread_id, "thread-hot-reload")
		eq(state.turn_id, "turn-hot-reload")
		eq(state.busy, true)
		eq(state.tabpage, tabpage)
		eq(state.output_buf, output_buf)
		eq(state.input_buf, input_buf)
		eq(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), { "preserve this draft" })

		live_client.on_notification("item/agentMessage/delta", {
			threadId = "thread-hot-reload",
			turnId = "turn-hot-reload",
			itemId = "message-after-reload",
			delta = "Still connected.",
		})
		local output = table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n")
		contains(output, "Still connected.")
		live_client:handle_message({ id = 0, result = { preserved = true } })
		eq(pending_result, { result = { preserved = true }, err = nil })
	end)
	package.preload["acp.ui"] = nil
	pcall(vim.fn.delete, bad_file)
	if package.loaded["acp.ui"] == ui then
		ui._export_runtime = original_export
	end
	current_ui._reset()
	eq(process.killed, 15)
	if not passed then
		error(err, 2)
	end
end)

local failures = {}
for _, case in ipairs(tests) do
	local passed, err = pcall(case.callback)
	if passed then
		print(("ok - %s"):format(case.name))
	else
		table.insert(failures, ("not ok - %s\n%s"):format(case.name, err))
	end
end

if #failures > 0 then
	vim.api.nvim_err_writeln(table.concat(failures, "\n"))
	vim.cmd("cquit 1")
end
