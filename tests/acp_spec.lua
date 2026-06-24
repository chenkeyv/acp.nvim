local jsonrpc = require("acp.jsonrpc")
local acp_changes = require("acp.changes")
local acp_context = require("acp.context")
local acp_diagnostics = require("acp.diagnostics")
local file_review = require("acp.file_review")
local history = require("acp.history")
local permission = require("acp.permission")
local Connection = require("acp.connection").Connection

local tests = {}

local function test(name, fn)
	table.insert(tests, { name = name, fn = fn })
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

test("jsonrpc line buffer emits complete non-empty lines", function()
	local lines = {}
	local buffer = jsonrpc.LineBuffer.new()

	buffer:push('{"jsonrpc":"2.0"}\n{"partial":', function(line)
		table.insert(lines, line)
	end)
	buffer:push('"value"}\r\n\n', function(line)
		table.insert(lines, line)
	end)

	eq(lines, {
		'{"jsonrpc":"2.0"}',
		'{"partial":"value"}',
	})
end)

test("setup registers public user commands", function()
	require("acp").setup({
		default_adapter = "test",
		default_mode = "window",
		adapters = {
			test = {
				command = { "missing-acp-test-command" },
				timeout_ms = 10,
				metadata = {
					model = "test-model",
					context_window = 1000,
				},
			},
		},
	})

	for _, command in ipairs({
		"AcpChat",
		"AcpChatContext",
		"AcpReview",
		"AcpChatTab",
		"AcpChatFloat",
		"AcpChatWindow",
		"AcpChatBuffer",
		"AcpSend",
		"AcpPromptPrev",
		"AcpPromptNext",
		"AcpStop",
		"AcpSessions",
		"AcpChanges",
		"AcpHistory",
		"AcpHistoryDraft",
		"AcpAddContext",
		"AcpFixDiagnostics",
		"AcpHealth",
	}) do
		eq(vim.fn.exists(":" .. command), 2)
	end
end)

test("prompt history recalls sent prompts and restores draft", function()
	local input_buf
	local original_notify = vim.notify
	vim.notify = function() end

	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()

		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "first prompt" })
		vim.cmd("AcpSend")
		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "second prompt", "details" })
		vim.cmd("AcpSend")

		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "draft prompt" })
		vim.cmd("AcpPromptPrev")
		eq(table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"), "second prompt\ndetails")

		vim.cmd("AcpPromptPrev")
		eq(table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"), "first prompt")

		vim.cmd("AcpPromptNext")
		eq(table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"), "second prompt\ndetails")

		vim.cmd("AcpPromptNext")
		eq(table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"), "draft prompt")
	end)

	vim.notify = original_notify
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("sessions command opens a picker from source buffers", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_set_current_buf(source_buf)
	local source_win = vim.api.nvim_get_current_win()
	vim.cmd("AcpChatWindow test")
	local input_buf = vim.api.nvim_get_current_buf()
	ok(vim.api.nvim_buf_get_name(input_buf):find("/input", 1, true))

	vim.api.nvim_set_current_win(source_win)
	vim.cmd("AcpSessions")
	local picker_buf = vim.api.nvim_get_current_buf()
	eq(vim.bo[picker_buf].filetype, "acp-sessions")
	local text = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
	ok(text:find("ACP Sessions", 1, true))
	ok(text:find("test", 1, true))

	local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
	vim.api.nvim_feedkeys(keys, "xt", false)
	local focused_buf = vim.api.nvim_get_current_buf()
	ok(vim.api.nvim_buf_get_name(focused_buf):find("/input", 1, true))

	pcall(vim.api.nvim_set_current_win, source_win)
	pcall(vim.api.nvim_buf_delete, focused_buf, { force = true })
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
end)

test("changes module records unique written files for quickfix", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(vim.fs.joinpath(root, "nested"), "p")
	local first = vim.fs.joinpath(root, "example.txt")
	local second = vim.fs.joinpath(root, "nested", "other.txt")
	vim.fn.writefile({ "one" }, first)
	vim.fn.writefile({ "two" }, second)

	local state = {
		id = 12,
		connection = {
			cwd = root,
		},
	}
	acp_changes.record(state, first)
	acp_changes.record(state, first)
	acp_changes.record(state, second)

	eq(acp_changes.count(state), 2)
	local items = acp_changes.items(state)
	eq(items[1].filename, vim.fs.normalize(first))
	eq(items[1].text, "ACP wrote example.txt (2 writes)")
	eq(items[2].filename, vim.fs.normalize(second))
	eq(items[2].text, "ACP wrote nested/other.txt")

	ok(acp_changes.open_quickfix(state), "quickfix should open for recorded changes")
	local qf = vim.fn.getqflist({ title = 1, items = 1 })
	eq(qf.title, "ACP changes #12")
	eq(#qf.items, 2)
	vim.cmd("cclose")

	vim.fn.delete(root, "rf")
end)

test("history saves transcript metadata and lists entries", function()
	local state = {
		id = 424242,
		adapter = "test-adapter",
		title = "History Test",
		model = "test-model",
	}
	local path = history.save(state, {
		"ACP: test-adapter",
		"",
		"You",
		"",
		"hello",
	})
	ok(path, "history path should be returned")
	ok(vim.fn.filereadable(path) == 1, "history file should exist")

	local text = table.concat(vim.fn.readfile(path), "\n")
	ok(text:find("# ACP Transcript", 1, true))
	ok(text:find("Title: History Test", 1, true))
	ok(text:find("Adapter: test-adapter", 1, true))
	ok(text:find("Model: test-model", 1, true))
	ok(text:find("hello", 1, true))

	local found
	for _, entry in ipairs(history.entries()) do
		if entry.path == path then
			found = entry
			break
		end
	end

	ok(found, "history entry should be listed")
	eq(found.title, "History Test")
	eq(found.adapter, "test-adapter")
	eq(found.model, "test-model")

	vim.fn.delete(path)
end)

test("history replay prompt is bounded and includes metadata", function()
	local state = {
		id = 424244,
		adapter = "test-adapter",
		title = "History Replay Test",
		model = "test-model",
	}
	local path = history.save(state, {
		"ACP: test-adapter",
		"",
		"You",
		"",
		"first line",
		"second line",
		"third line",
	})
	local entry = {
		path = path,
		title = "History Replay Test",
		adapter = "test-adapter",
		updated = "now",
	}

	local prompt = history.replay_prompt(entry, { max_lines = 5 })
	ok(prompt:find("Use this saved ACP transcript as context", 1, true))
	ok(prompt:find("Transcript: History Replay Test", 1, true))
	ok(prompt:find("Adapter: test-adapter", 1, true))
	ok(prompt:find("Updated: now", 1, true))
	ok(prompt:find("ACP: test-adapter", 1, true))
	ok(prompt:find("first line", 1, true))
	ok(prompt:find("... transcript truncated ...", 1, true))
	ok(not prompt:find("second line", 1, true))

	vim.fn.delete(path)
end)

test("history browser opens when entries exist", function()
	local state = {
		id = 424243,
		adapter = "test-adapter",
		title = "History Browser Test",
		model = "test-model",
	}
	local path = history.save(state, { "ACP: test-adapter", "" })

	ok(history.open_browser(), "history browser should open")
	local bufnr = vim.api.nvim_get_current_buf()
	eq(vim.bo[bufnr].filetype, "acp-history")

	local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
	vim.api.nvim_feedkeys(keys, "xt", false)
	local entry_bufnr = vim.api.nvim_get_current_buf()
	eq(vim.bo[entry_bufnr].filetype, "acp")
	ok(vim.api.nvim_buf_get_name(entry_bufnr):find("ACP History://", 1, true))

	pcall(vim.cmd, "tabclose!")
	vim.fn.delete(path)
end)

test("history browser can draft a chat from an entry", function()
	local state = {
		id = 424245,
		adapter = "test-adapter",
		title = "History Draft Test",
		model = "test-model",
	}
	local path = history.save(state, { "ACP: test-adapter", "", "hello from history" })
	local selected

	ok(history.open_browser({
		open_chat = function(entry)
			selected = entry
		end,
	}), "history browser should open")
	local bufnr = vim.api.nvim_get_current_buf()
	eq(vim.bo[bufnr].filetype, "acp-history")
	local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	ok(text:find("draft a chat", 1, true))

	local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
	vim.api.nvim_feedkeys(keys, "xt", false)
	ok(selected and selected.path == path, "selected entry should be passed to callback")

	vim.fn.delete(path)
end)

test("filesystem requests are scoped to cwd", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")

	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 10, file_write_review_delay_ms = 0 },
		cwd = root,
	})
	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end
	local original_select = file_review.select
	file_review.select = function(_, callback)
		callback(true)
	end

	local passed, err = pcall(function()
		connection:handle_fs_write(1, {
			path = "nested/example.txt",
			content = "alpha\nbeta\ngamma",
		})
		connection:handle_fs_read(2, {
			path = "nested/example.txt",
			line = 2,
			limit = 1,
		})
		connection:handle_fs_read(3, {
			path = "../outside.txt",
		})
	end)

	file_review.select = original_select
	if not passed then
		vim.fn.delete(root, "rf")
		error(err, 2)
	end

	eq(writes[1].id, 1)
	eq(writes[1].result, vim.NIL)
	eq(writes[2].result.content, "beta")
	eq(writes[3].error.code, jsonrpc.errors.invalid_params)

	vim.fn.delete(root, "rf")
end)

test("async prompt response clears pending request", function()
	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 10 },
		cwd = vim.fn.getcwd(),
	})
	connection.session_id = "session-1"

	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	local stop_reason
	ok(connection:prompt("hello", {
		done = function(reason)
			stop_reason = reason
		end,
	}))

	local id = writes[1].id
	ok(connection.pending[id], "prompt request should start pending")
	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = id,
		result = { stopReason = "end_turn" },
	}))

	eq(stop_reason, "end_turn")
	eq(connection.pending[id], nil)
end)

test("async prompt starts session without blocking before sending prompt", function()
	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 1000 },
		cwd = vim.fn.getcwd(),
	})
	function connection:start()
		return true
	end

	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	local started = false
	local done_reason
	ok(connection:prompt_async("hello", {
		started = function()
			started = true
		end,
		done = function(reason)
			done_reason = reason
		end,
	}))

	eq(#writes, 1)
	eq(writes[1].method, "initialize")
	eq(started, false)

	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = writes[1].id,
		result = {
			authMethods = {},
		},
	}))

	eq(#writes, 2)
	eq(writes[2].method, "session/new")
	eq(started, false)

	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = writes[2].id,
		result = {
			sessionId = "session-1",
		},
	}))

	eq(#writes, 3)
	eq(writes[3].method, "session/prompt")
	eq(writes[3].params.sessionId, "session-1")
	eq(started, true)

	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = writes[3].id,
		result = {
			stopReason = "end_turn",
		},
	}))

	eq(done_reason, "end_turn")
end)

test("editor context includes source line and diagnostics", function()
	local previous_buf = vim.api.nvim_get_current_buf()
	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local alpha = 1",
		"local beta = alpha + missing",
	})
	vim.bo[bufnr].filetype = "lua"
	vim.api.nvim_set_current_buf(bufnr)
	vim.api.nvim_win_set_cursor(0, { 2, 6 })

	local ns = vim.api.nvim_create_namespace("acp.nvim.test.diagnostics")
	vim.diagnostic.set(ns, bufnr, {
		{
			lnum = 0,
			col = 0,
			severity = vim.diagnostic.severity.WARN,
			message = "unused local alpha",
		},
		{
			lnum = 1,
			col = 0,
			severity = vim.diagnostic.severity.ERROR,
			message = "undefined global missing",
		},
	})

	local original_get_clients = vim.lsp.get_clients
	vim.lsp.get_clients = function(opts)
		if opts and opts.bufnr == bufnr then
			return {
				{ name = "test-ls" },
				{ name = "lua_ls" },
			}
		end
		return {}
	end

	local source = acp_context.capture(bufnr, vim.api.nvim_get_current_win())
	local rendered = acp_context.render(source)
	vim.lsp.get_clients = original_get_clients

	ok(rendered:find("Context", 1, true))
	ok(rendered:find("Filetype: lua", 1, true))
	ok(rendered:find("Cursor: 2:7", 1, true))
	ok(rendered:find("LSP clients: lua_ls, test-ls", 1, true))
	ok(rendered:find("Line: local beta = alpha + missing", 1, true))
	ok(rendered:find("Diagnostics:", 1, true))
	ok(rendered:find("ERROR: undefined global missing", 1, true))
	ok(rendered:find("Buffer diagnostics:", 1, true))
	ok(rendered:find("Summary: 1 error(s), 1 warning(s), 0 info, 0 hint(s)", 1, true))
	ok(rendered:find("1:1 WARN: unused local alpha", 1, true))

	vim.diagnostic.reset(ns, bufnr)
	vim.api.nvim_set_current_buf(previous_buf)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("editor context includes selected range text", function()
	local previous_buf = vim.api.nvim_get_current_buf()
	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local one = 1",
		"local two = 2",
		"local three = one + two",
	})
	vim.bo[bufnr].filetype = "lua"
	vim.api.nvim_set_current_buf(bufnr)
	vim.api.nvim_win_set_cursor(0, { 2, 0 })

	local source = acp_context.capture(bufnr, vim.api.nvim_get_current_win(), {
		line1 = 2,
		line2 = 3,
	})
	local rendered = acp_context.render(source)

	ok(rendered:find("Selection: lines 2-3 (2 line(s))", 1, true))
	ok(rendered:find("Selected text:", 1, true))
	ok(rendered:find("local two = 2", 1, true))
	ok(rendered:find("local three = one + two", 1, true))

	vim.api.nvim_set_current_buf(previous_buf)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("editor context includes bounded tree-sitter node text", function()
	local previous_buf = vim.api.nvim_get_current_buf()
	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"function example()",
		"  return alpha + beta",
		"end",
	})
	vim.bo[bufnr].filetype = "lua"
	vim.api.nvim_set_current_buf(bufnr)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })

	local fake_node = {}
	function fake_node:type()
		return "function_declaration"
	end
	function fake_node:range()
		return 0, 0, 2, 3
	end

	local original_treesitter = vim.treesitter
	local original_get_node = original_treesitter and original_treesitter.get_node
	local original_get_node_text = original_treesitter and original_treesitter.get_node_text
	vim.treesitter = vim.treesitter or {}
	vim.treesitter.get_node = function()
		return fake_node
	end
	vim.treesitter.get_node_text = function()
		return "function example()\n  return alpha + beta\nend"
	end

	local source = acp_context.capture(bufnr, vim.api.nvim_get_current_win())
	local rendered = acp_context.render(source, {
		treesitter_text_lines = 2,
	})

	if original_treesitter then
		vim.treesitter.get_node = original_get_node
		vim.treesitter.get_node_text = original_get_node_text
	else
		vim.treesitter = nil
	end

	ok(rendered:find("Tree-sitter: function_declaration at 1:1-3:3", 1, true))
	ok(rendered:find("Tree-sitter text:", 1, true))
	ok(rendered:find("function example()", 1, true))
	ok(rendered:find("  return alpha + beta", 1, true))
	ok(rendered:find("...", 1, true))
	ok(not rendered:find("\nend", 1, true))

	vim.api.nvim_set_current_buf(previous_buf)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("diagnostics renderer filters by selected range", function()
	local previous_buf = vim.api.nvim_get_current_buf()
	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local alpha = 1",
		"local beta = missing",
		"local gamma = beta",
		"print(unused)",
	})
	vim.api.nvim_set_current_buf(bufnr)

	local ns = vim.api.nvim_create_namespace("acp.nvim.test.render-diagnostics")
	vim.diagnostic.set(ns, bufnr, {
		{
			lnum = 1,
			col = 13,
			severity = vim.diagnostic.severity.ERROR,
			message = "undefined global missing",
			source = "lua_ls",
			code = "undefined-global",
		},
		{
			lnum = 3,
			col = 6,
			severity = vim.diagnostic.severity.WARN,
			message = "undefined global unused",
			source = "lua_ls",
		},
	})

	local rendered = acp_diagnostics.render(bufnr, {
		range = {
			line1 = 1,
			line2 = 3,
		},
	})

	ok(rendered:find("Diagnostics", 1, true))
	ok(rendered:find("Summary: 1 error(s), 0 warning(s), 0 info, 0 hint(s)", 1, true))
	ok(rendered:find("Range: lines 1-3", 1, true))
	ok(rendered:find("2:14 ERROR [lua_ls] (undefined-global): undefined global missing", 1, true))
	ok(not rendered:find("undefined global unused", 1, true))

	vim.diagnostic.reset(ns, bufnr)
	vim.api.nvim_set_current_buf(previous_buf)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("fix diagnostics command opens a prefilled prompt", function()
	local previous_buf = vim.api.nvim_get_current_buf()
	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local value = missing",
	})
	vim.bo[bufnr].filetype = "lua"
	vim.api.nvim_set_current_buf(bufnr)
	vim.api.nvim_win_set_cursor(0, { 1, 6 })

	local ns = vim.api.nvim_create_namespace("acp.nvim.test.fix-diagnostics")
	vim.diagnostic.set(ns, bufnr, {
		{
			lnum = 0,
			col = 14,
			severity = vim.diagnostic.severity.ERROR,
			message = "undefined global missing",
			source = "lua_ls",
		},
	})

	vim.cmd("AcpFixDiagnostics test")
	local input_buf = vim.api.nvim_get_current_buf()
	eq(vim.bo[input_buf].filetype, "markdown")
	local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
	ok(prompt:find("Fix the diagnostics below", 1, true))
	ok(prompt:find("Context", 1, true))
	ok(prompt:find("Filetype: lua", 1, true))
	ok(prompt:find("Diagnostics", 1, true))
	ok(prompt:find("ERROR [lua_ls]: undefined global missing", 1, true))

	vim.diagnostic.reset(ns, bufnr)
	vim.api.nvim_set_current_buf(previous_buf)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("review command opens a range-aware draft prompt", function()
	local previous_buf = vim.api.nvim_get_current_buf()
	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local function add(a, b)",
		"  return a + b",
		"end",
	})
	vim.bo[bufnr].filetype = "lua"
	vim.api.nvim_set_current_buf(bufnr)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })

	vim.cmd("1,2AcpReview test")
	local input_buf = vim.api.nvim_get_current_buf()
	eq(vim.bo[input_buf].filetype, "markdown")
	local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
	ok(prompt:find("Review this code. Prioritize correctness, edge cases, and maintainability.", 1, true))
	ok(prompt:find("Context", 1, true))
	ok(prompt:find("Filetype: lua", 1, true))
	ok(prompt:find("Selection: lines 1-2 (2 line(s))", 1, true))
	ok(prompt:find("local function add(a, b)", 1, true))
	ok(prompt:find("  return a + b", 1, true))
	ok(not prompt:find("\nend", 1, true))

	vim.api.nvim_set_current_buf(previous_buf)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("file write review renders a diff preview", function()
	local lines = file_review.lines({
		display_path = "lua/example.lua",
		before = "local value = 1\n",
		after = "local value = 2\n",
	})
	local text = table.concat(lines, "\n")

	ok(text:find("File write review", 1, true))
	ok(text:find("File: lua/example.lua", 1, true))
	ok(text:find("1. Apply write", 1, true))
	ok(text:find("2. Cancel", 1, true))
	ok(text:find("-local value = 1", 1, true))
	ok(text:find("+local value = 2", 1, true))
end)

test("file write review renders batched diffs", function()
	local lines = file_review.lines({
		files = {
			{
				display_path = "lua/one.lua",
				before = "return 1\n",
				after = "return 2\n",
			},
			{
				display_path = "lua/two.lua",
				before = "",
				after = "return true\n",
			},
		},
	})
	local text = table.concat(lines, "\n")

	ok(text:find("Files: 2", 1, true))
	ok(text:find("1. Apply 2 writes", 1, true))
	ok(text:find("File 1/2: lua/one.lua", 1, true))
	ok(text:find("File 2/2: lua/two.lua", 1, true))
	ok(text:find("-return 1", 1, true))
	ok(text:find("+return 2", 1, true))
	ok(text:find("+return true", 1, true))
end)

test("quick file writes are reviewed as one batch", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")

	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 10, file_write_review_delay_ms = 20 },
		cwd = root,
	})
	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	local review_count = 0
	local reviewed_request
	local original_select = file_review.select
	file_review.select = function(request, callback)
		review_count = review_count + 1
		reviewed_request = request
		callback(true)
	end

	local passed, err = pcall(function()
		connection:handle_fs_write(41, {
			path = "one.txt",
			content = "one",
		})
		connection:handle_fs_write(42, {
			path = "nested/two.txt",
			content = "two",
		})
		ok(vim.wait(200, function()
			return #writes == 2
		end, 5), "batched write responses should be sent")
	end)

	file_review.select = original_select
	if not passed then
		vim.fn.delete(root, "rf")
		error(err, 2)
	end

	eq(review_count, 1)
	eq(#reviewed_request.files, 2)
	eq(writes[1].id, 41)
	eq(writes[1].result, vim.NIL)
	eq(writes[2].id, 42)
	eq(writes[2].result, vim.NIL)
	eq(table.concat(vim.fn.readfile(vim.fs.joinpath(root, "one.txt")), "\n"), "one")
	eq(table.concat(vim.fn.readfile(vim.fs.joinpath(root, "nested", "two.txt")), "\n"), "two")

	vim.fn.delete(root, "rf")
end)

test("file write cancellation leaves file unchanged", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	vim.fn.writefile({ "before" }, vim.fs.joinpath(root, "example.txt"))

	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 10, file_write_review_delay_ms = 0 },
		cwd = root,
	})
	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	local original_select = file_review.select
	file_review.select = function(_, callback)
		callback(false)
	end

	local passed, err = pcall(function()
		connection:handle_fs_write(4, {
			path = "example.txt",
			content = "after",
		})
	end)

	file_review.select = original_select
	if not passed then
		vim.fn.delete(root, "rf")
		error(err, 2)
	end

	local content = table.concat(vim.fn.readfile(vim.fs.joinpath(root, "example.txt")), "\n")
	eq(content, "before")
	eq(writes[1].id, 4)
	eq(writes[1].error.code, jsonrpc.errors.internal_error)

	vim.fn.delete(root, "rf")
end)

test("permission UI formats tool details and options", function()
	local lines = permission.lines({
		toolCall = {
			title = "Edit file",
			kind = "edit",
			description = "Patch a source file",
		},
		options = {
			{
				optionId = "allow",
				name = "Allow",
				description = "Apply the edit",
			},
			{
				optionId = "deny",
				name = "Deny",
			},
		},
	})
	local text = table.concat(lines, "\n")

	ok(text:find("Permission request", 1, true))
	ok(text:find("Tool: Edit file", 1, true))
	ok(text:find("Kind: edit", 1, true))
	ok(text:find("1. Allow", 1, true))
	ok(text:find("Outcome: allow", 1, true))
	ok(text:find("2. Deny", 1, true))
end)

test("permission request sends selected outcome", function()
	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 10 },
		cwd = vim.fn.getcwd(),
	})
	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	local original_select = permission.select
	permission.select = function(params, callback)
		callback(params.options[2])
	end

	local passed, err = pcall(function()
		connection:handle_permission_request(7, {
			options = {
				{ optionId = "allow", name = "Allow" },
				{ optionId = "deny", name = "Deny" },
			},
		})
	end)

	permission.select = original_select
	if not passed then
		error(err, 2)
	end

	eq(writes[1].id, 7)
	eq(writes[1].result.outcome, "deny")
end)

test("permission request cancellation sends error", function()
	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 10 },
		cwd = vim.fn.getcwd(),
	})
	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	local original_select = permission.select
	permission.select = function(_, callback)
		callback(nil)
	end

	local passed, err = pcall(function()
		connection:handle_permission_request(8, {
			options = {
				{ optionId = "allow", name = "Allow" },
			},
		})
	end)

	permission.select = original_select
	if not passed then
		error(err, 2)
	end

	eq(writes[1].id, 8)
	eq(writes[1].error.code, jsonrpc.errors.internal_error)
end)

test("permission request without options sends invalid params", function()
	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 10 },
		cwd = vim.fn.getcwd(),
	})
	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	connection:handle_permission_request(9, {
		options = {
		},
	})

	eq(writes[1].id, 9)
	eq(writes[1].error.code, jsonrpc.errors.invalid_params)
end)

local failures = {}
for _, case in ipairs(tests) do
	local passed, err = pcall(case.fn)
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
