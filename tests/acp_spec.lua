local approval = require("acp.approval")
local blocks = require("acp.blocks")
local Client = require("acp.codex").Client
local context = require("acp.context")
local health = require("acp.health")
local icons = require("acp.icons")
local jsonrpc = require("acp.jsonrpc")
local output = require("acp.output")
local output_ui = require("acp.output_ui")
local permission = require("acp.permission")
local render = require("acp.render")
local requests = require("acp.requests")
local transcript = require("acp.transcript")
local ui = require("acp.ui")
local view = require("acp.view")

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

local function chunks_text(chunks)
	local values = {}
	for _, chunk in ipairs(chunks or {}) do
		table.insert(values, type(chunk) == "table" and (chunk[1] or "") or tostring(chunk))
	end
	return table.concat(values)
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
	contains(text, render.header("user"))
	contains(text, "Please fix it")
	contains(text, "nvim --headless")
	ok(not text:find("\27", 1, true), "ANSI escape sequences should be removed")
	contains(text, "lua/acp/ui.lua")
	contains(text, render.header("agent"))
	contains(text, "Done.")
	ok(not text:find("Working directory:", 1, true), "working-directory metadata belongs in window chrome")
	eq(render.thread_diff(thread), "--- a\n+++ b")
	contains(render.thread_label(thread), "Fix the parser")
	local failed_change = render.completed_item({
		type = "fileChange",
		status = "failed",
		changes = { { path = "lua/acp/ui.lua", kind = { type = "update", move_path = vim.NIL } } },
	})[1]
	contains(failed_change, "File changes: failed")
	eq(output.activity_kind(failed_change), nil)
end)

test("chat blocks preserve roles, grouped activity, code, and failures", function()
	local chat = blocks.from_thread({
		turns = {
			{
				items = {
					{ id = "user-1", type = "userMessage", content = { { type = "text", text = "Inspect it" } } },
					{
						id = "command-1",
						type = "commandExecution",
						command = "rg blocks",
						status = "completed",
						exitCode = 0,
					},
					{
						id = "change-1",
						type = "fileChange",
						status = "completed",
						changes = { { path = "lua/acp/blocks.lua", kind = { type = "update" } } },
					},
					{
						id = "agent-1",
						type = "agentMessage",
						text = "Implemented.\n```lua\nreturn true\n```\nDone.",
					},
					{
						id = "command-2",
						type = "commandExecution",
						command = "false",
						status = "completed",
						exitCode = 1,
					},
				},
			},
		},
	})

	eq(
		vim.tbl_map(function(block)
			return block.kind
		end, chat.blocks),
		{ "user", "activity", "agent", "error" }
	)
	eq(#chat.blocks[2].children, 2)
	eq(chat.blocks[2].children[1].kind, "command")
	eq(chat.blocks[2].children[2].kind, "file")
	local activity = chat:activities()[1]
	eq(activity.line, chat.blocks[2].line1)
	eq(activity.line2, chat.blocks[2].line2)
	eq(activity.counts, { command = 1, tool = 0, file = 1 })

	local code
	for _, child in ipairs(chat.by_id["agent-1"].children) do
		if child.kind == "code" then
			code = child
		end
	end
	eq(code.language, "lua")
	eq(code.text, "return true")
	eq(chat:render_lines()[code.line1], "```lua")
	eq(chat:render_lines()[code.line2], "```")
	ok(code.line1 >= chat.by_id["agent-1"].line1)
	ok(code.line2 <= chat.by_id["agent-1"].line2)
	eq(chat:block_at(code.line1).id, "agent-1")
	eq(chat:section_at(code.line1).kind, "AGENT")

	local text = table.concat(chat:render_lines(), "\n")
	contains(text, render.header("user"))
	contains(text, render.header("agent"))
	contains(text, icons.get("command") .. " Command")
	contains(text, icons.get("changes") .. " update")
	contains(text, icons.get("error") .. " Command")
	contains(text, "lua/acp/blocks.lua")
	contains(text, "Command completed (exit 1)")
	eq(#chat:diagnostics(), 1)
	eq(#chat:code_blocks(), 1)
	local section_text, range = chat:section_text(code.line1)
	contains(section_text, render.header("agent"))
	contains(section_text, "Done.")
	eq(range.block_id, "agent-1")
end)

test("legacy transcripts keep sections, activity, and code after block migration", function()
	local fence = string.rep(string.char(96), 3)
	local chat = blocks.from_lines({
		"## You",
		"Inspect the migration.",
		"> Command completed (exit 0): `rg blocks`",
		"> Tool completed: `inspect`",
		"## Codex",
		"Done.",
		fence .. "lua",
		"return true",
		fence,
	})

	eq(
		vim.tbl_map(function(section)
			return section.kind
		end, chat:sections()),
		{ "USER", "COMMAND", "TOOL", "AGENT" }
	)
	local activity = chat:activity_at(3)
	eq(activity.line, 3)
	eq(activity.line2, 4)
	eq(#chat:activities(), 1)
	eq(chat:code_block_at(8).language, "lua")
	local text, range = chat:section_text(8)
	contains(text, render.header("agent"))
	eq(range.line1, 5)
	contains(table.concat(chat:render_lines(), "\n"), icons.get("command") .. " Command")
	ok(
		not table.concat(chat:render_lines(), "\n"):find("## ", 1, true),
		"legacy role headings should migrate to direct icons"
	)
end)

test("live chat blocks emit bounded incremental buffer operations", function()
	local chat = blocks.new()
	local spacer_rows = 3
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "", "", "", "" })
	local function apply(operation)
		vim.api.nvim_buf_set_lines(bufnr, operation.start_row, operation.end_row, false, operation.lines)
		local expected = chat:render_lines()
		for _ = 1, spacer_rows do
			table.insert(expected, "")
		end
		eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), expected)
	end

	local user_operation = chat:add_user("Build it", {})
	eq(user_operation.start_row, 0)
	eq(user_operation.end_row, 1)
	apply(user_operation)

	local agent_operation = chat:ensure_agent("agent-live")
	eq(agent_operation.start_row, #user_operation.lines)
	apply(agent_operation)
	local first_delta = chat:append_text("agent-live", "One")
	eq(first_delta.type, "replace")
	eq(first_delta.lines, { "One" })
	apply(first_delta)
	local second_delta = chat:append_text("agent-live", "\nTwo")
	eq(second_delta.lines, { "One", "Two" })
	apply(second_delta)

	local activity_operation = chat:add_item({
		id = "command-live-1",
		type = "commandExecution",
		command = "true",
		status = "completed",
		exitCode = 0,
	})
	apply(activity_operation)
	local merge_operation, activity_block = chat:add_item({
		id = "tool-live-1",
		type = "dynamicToolCall",
		tool = "inspect",
		status = "completed",
	})
	apply(merge_operation)
	eq(merge_operation.type, "insert")
	eq(#activity_block.children, 2)
	local activity_line = activity_block.line1
	local late_delta = chat:append_text("agent-live", "\nThree")
	apply(late_delta)
	eq(activity_block.line1, activity_line + 1)
	eq(activity_block.children[1].line1, activity_block.line1)
	eq(chat.line_count, #chat:render_lines())
	eq(vim.api.nvim_buf_get_lines(bufnr, chat.line_count, -1, false), { "", "", "" })
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("large block transcripts keep lookup and streaming edits bounded", function()
	local thread = { turns = {} }
	for turn = 1, 250 do
		local response = {}
		for line = 1, 14 do
			response[line] = ("response %d line %d"):format(turn, line)
		end
		thread.turns[turn] = {
			items = {
				{
					id = "user-" .. turn,
					type = "userMessage",
					content = { { type = "text", text = "prompt " .. turn } },
				},
				{
					id = "command-" .. turn,
					type = "commandExecution",
					command = "true",
					status = "completed",
					exitCode = 0,
				},
				{
					id = "agent-" .. turn,
					type = "agentMessage",
					text = table.concat(response, "\n"),
				},
			},
		}
	end

	local started = (vim.uv or vim.loop).hrtime()
	local chat = blocks.from_thread(thread)
	eq(chat.line_count, 5000)
	for line = 1, chat.line_count, 5 do
		ok(chat:block_at(line))
	end
	local elapsed_ms = ((vim.uv or vim.loop).hrtime() - started) / 1000000
	ok(elapsed_ms < 1000, ("expected 5,000-line block indexing under 1s, got %.2fms"):format(elapsed_ms))
	local semantic = chat:semantic_data(vim.fn.getcwd())
	ok(chat:semantic_data(vim.fn.getcwd()) == semantic, "expected model-wide semantics to reuse the current revision")

	local operation = chat:append_text("agent-250", "\nfinal streamed line")
	eq(operation.type, "replace")
	eq(operation.start_row, 4999)
	eq(operation.end_row, 5000)
	eq(#operation.lines, 2)
	eq(chat.line_count, 5001)
	ok(chat:semantic_data(vim.fn.getcwd()) ~= semantic, "expected a streamed edit to invalidate model-wide semantics")
end)

test("chat view keeps the prompt inset and styles transcript roles", function()
	eq(
		view.prompt_geometry({ row = 1, col = 31, width = 89, height = 30 }, {
			input_height = 6,
			input_padding = 2,
		}),
		{
			row = 23,
			col = 33,
			width = 83,
			height = 4,
			outer_width = 85,
			outer_height = 6,
			reserved_rows = 8,
		}
	)
	local instruction_block = view.instruction_block({
		pending_instructions = {
			{ id = "steer-1", kind = "steer", text = "Keep the public API unchanged" },
			{ id = "queue-1", kind = "queued", text = "Run the tests afterward" },
		},
	}, 52, 4)
	eq(#instruction_block.lines, 2)
	contains(instruction_block.lines[1], icons.get("send") .. " STEER")
	contains(instruction_block.lines[1], "Keep the public API unchanged")
	contains(instruction_block.lines[2], icons.get("history") .. " QUEUED")
	contains(chunks_text(instruction_block.title), "1 steer")
	contains(chunks_text(instruction_block.title), "1 queued")
	local clipped_instructions = view.instruction_block({
		pending_instructions = {
			{ id = "queue-1", kind = "queued", text = "first" },
			{ id = "queue-2", kind = "queued", text = "second" },
			{ id = "queue-3", kind = "queued", text = "third" },
		},
	}, 28, 2)
	eq(#clipped_instructions.lines, 2)
	contains(clipped_instructions.lines[2], "+2 more instructions")

	local bufnr = vim.api.nvim_create_buf(false, true)
	local direct_lines = {
		transcript.header("user"),
		"Use `turn/steer`.",
		transcript.header("agent"),
		transcript.line("command", "Command completed: `nvim --headless`"),
		transcript.line("tool", "Tool completed: `mcp/read`"),
		transcript.line("changes", "update `lua/acp/view.lua`"),
		transcript.line("warning", "Warning: check this result"),
		transcript.line("error", "Error: failed to apply change"),
		transcript.header("plan"),
		"```lua",
	}
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, direct_lines)
	view.define_highlights()
	view.refresh_transcript(bufnr, 0)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, view.transcript_namespace, 0, -1, { details = true })
	local groups = {}
	for _, extmark in ipairs(marks) do
		local details = extmark[4] or {}
		if details.hl_group then
			groups[details.hl_group] = true
		end
		ok(not details.sign_text, "chat icons should be buffer text, not signs")
		ok(details.conceal == nil, "direct transcript icons should not need conceal extmarks")
	end
	ok(groups.AcpUserHeader)
	ok(groups.AcpAgentHeader)
	ok(groups.AcpTranscriptTool)
	ok(groups.AcpCodeFence)
	ok(groups.AcpInlineCode)
	for _, expected in ipairs({
		{ 1, "user" },
		{ 3, "agent" },
		{ 4, "command" },
		{ 5, "tool" },
		{ 6, "changes" },
		{ 7, "warning" },
		{ 8, "error" },
		{ 9, "section" },
	}) do
		contains(direct_lines[expected[1]], icons.get(expected[2]))
	end
	local evaluated = vim.api.nvim_eval_statusline(
		view.chat_winbar({
			status = "running command",
			busy = true,
			tokens = { totalTokens = 42000, modelContextWindow = 272000 },
		}),
		{ maxwidth = 49 }
	)
	contains(evaluated.str, icons.get("agent") .. " Codex")
	contains(evaluated.str, "running command")
	local previous_have_nerd_font = vim.g.have_nerd_font
	vim.g.have_nerd_font = false
	eq(icons.get("user"), "U")
	eq(icons.get("code"), "{}")
	eq(icons.get("send"), ">")
	eq(icons.get("history"), "+")
	eq(transcript.header("user"), "U You")
	eq(transcript.line("warning", "Warning: check"), "! Warning: check")
	vim.g.have_nerd_font = previous_have_nerd_font
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("custom output model restores sections, items, folds, references, and problems", function()
	local lines = {
		"## You",
		"Please inspect the transcript.",
		"## Codex",
		"I will check it.",
		"> Command completed: `nvim --headless`",
		"> update `lua/acp/view.lua`",
		"### Plan",
		"1. Verify behavior",
		"```lua",
		"print('ok')",
		"```",
		"> Warning: check this result",
		"> Error: failed to apply change",
	}

	local sections = output.sections(lines)
	eq(#sections, 7)
	eq(sections[1].kind, "USER")
	eq(sections[2].kind, "AGENT")
	eq(sections[3].kind, "COMMAND")
	eq(sections[4].kind, "FILE")
	eq(sections[5].kind, "PLAN")
	eq(output.next_section(lines, 1, 1), 3)
	eq(output.fold_level(lines, 1), ">1")
	eq(output.fold_level(lines, 2), "1")
	eq(output.fold_expr("preamble", 1), "0")
	eq(output.fold_expr("preamble", 2), "=")
	eq(output.fold_expr("## Codex", 3), ">1")
	contains(output.fold_text(lines, 1, 2), "USER")

	local blocks = output.code_blocks(lines)
	eq(#blocks, 1)
	eq(blocks[1].filetype, "lua")
	eq(output.code_block_text(blocks[1]), "print('ok')")

	local references = output.file_references(lines, { cwd = vim.fn.getcwd() })
	eq(#references, 1)
	contains(references[1].display_path, "lua/acp/view.lua")
	eq(references[1].line, 1)

	local diagnostics = output.problem_diagnostics(lines)
	eq(#diagnostics, 2)
	eq(diagnostics[1].severity, vim.diagnostic.severity.WARN)
	eq(diagnostics[2].severity, vim.diagnostic.severity.ERROR)

	local items = output.output_items(lines, { cwd = vim.fn.getcwd() })
	eq(#items, 5)
	eq(items[1].kind, "activity")
	eq(output.transcript_stats(lines, { cwd = vim.fn.getcwd() }), {
		sections = 7,
		code_blocks = 1,
		locations = 1,
		changes = 0,
	})
	ok(#output.output_map_entries(lines, { cwd = vim.fn.getcwd() }) > #sections)
end)

test("completed activity groups collapse together while failures stay visible", function()
	local lines = {
		"## Codex",
		"> Command completed (exit 0): `rg error lua/acp`",
		"> Tool completed: `mcp/read`",
		"> update `lua/acp/output.lua`",
		"> Command failed (exit 1): `nvim --headless`",
		"> Warning: inspect the failure",
	}

	local groups = output.activity_groups(lines)
	eq(#groups, 1)
	eq(groups[1].line, 2)
	eq(groups[1].line2, 4)
	eq(groups[1].counts, { command = 1, tool = 1, file = 1 })
	contains(groups[1].label, "3 completed")
	eq(output.activity_kind(lines[5]), nil)
	eq(output.activity_kind("> Command running: `sleep 1`"), nil)
	eq(output.fold_expr(lines[2], 2, lines[1], lines[3]), ">2")
	eq(output.fold_expr(lines[3], 3, lines[2], lines[4]), "2")
	eq(output.fold_expr(lines[4], 4, lines[3], lines[5]), "2")
	eq(output.fold_expr(lines[5], 5, lines[4], lines[6]), ">1")
	contains(output.fold_text({ lines[2], lines[3], lines[4] }, 1, 3), "ACTIVITY")

	local item = output.current_output_item(lines, 3, 0, { cwd = vim.fn.getcwd() })
	eq(item.kind, "activity")
	eq(item.line, 2)
	eq(item.line2, 4)
	eq(output.current_output_item(lines, 4, 10, { cwd = vim.fn.getcwd() }).kind, "reference")
	eq(
		output.current_output_item(lines, 4, 10, {
			cwd = vim.fn.getcwd(),
			prefer_activity = true,
		}).kind,
		"activity"
	)
	local preview = output.output_map_preview(lines, item)
	eq(preview.lines, { lines[2], lines[3], lines[4] })
	contains(preview.title, "3 completed")

	local diagnostics = output.problem_diagnostics(lines)
	eq(#diagnostics, 2)
	eq(diagnostics[1].severity, vim.diagnostic.severity.ERROR)
	eq(diagnostics[2].severity, vim.diagnostic.severity.WARN)
end)

test("output UI restores semantic visuals and section drafting", function()
	local output_buf = vim.api.nvim_create_buf(false, true)
	local input_buf = vim.api.nvim_create_buf(false, true)
	local lines = {
		"## You",
		"Review `lua/acp/view.lua:1`.",
		"## Codex",
		"```lua",
		"return true",
		"```",
		"> Warning: inspect this",
	}
	vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, lines)
	local output_win = vim.api.nvim_open_win(output_buf, false, {
		relative = "editor",
		row = 0,
		col = 0,
		width = 40,
		height = 5,
		style = "minimal",
	})
	vim.api.nvim_win_set_cursor(output_win, { 2, lines[2]:find("lua", 1, true) - 1 })
	local state = {
		cwd = vim.fn.getcwd(),
		output_buf = output_buf,
		output_win = output_win,
		input_buf = input_buf,
	}

	output_ui.refresh(state)
	eq(state.output_cache.changedtick, vim.api.nvim_buf_get_changedtick(output_buf))
	local current_cache = state.output_cache
	output_ui.refresh(state)
	ok(state.output_cache == current_cache, "an unchanged transcript should reuse its semantic and visual cache")
	local visual_marks = vim.api.nvim_buf_get_extmarks(output_buf, output_ui.namespaces.visual, 0, -1, {
		details = true,
	})
	ok(#visual_marks > 0)
	local reference_highlighted = false
	for _, extmark in ipairs(visual_marks) do
		local details = extmark[4] or {}
		ok(not details.virt_text, "semantic icons and code languages should not be virtual text")
		if details.hl_group == "AcpOutputReference" then
			reference_highlighted = true
		end
		ok(not details.sign_text, "transcript references should not add sign icons")
		if details.virt_text_pos == "right_align" then
			for _, chunk in ipairs(details.virt_text or {}) do
				ok(not tostring(chunk[1]):find("REF", 1, true), "transcript references should not add REF badges")
			end
		end
	end
	ok(reference_highlighted, "transcript references should remain highlighted")
	local current_marks = vim.api.nvim_buf_get_extmarks(output_buf, output_ui.namespaces.current, 0, -1, {
		details = true,
	})
	ok(#current_marks > 0, "the current reference should remain highlighted")
	for _, extmark in ipairs(current_marks) do
		ok(not (extmark[4] or {}).virt_text, "cursor highlights should not add virtual text")
	end
	eq(#vim.diagnostic.get(output_buf, { namespace = output_ui.namespaces.diagnostics }), 1)
	ok(output_ui.yank_section(state))
	contains(vim.fn.getreg('"'), "Review")
	ok(output_ui.draft_section(state))
	contains(table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"), "follow-up context")

	output_ui.close(state)
	vim.api.nvim_win_close(output_win, true)
	vim.api.nvim_buf_delete(output_buf, { force = true })
	vim.api.nvim_buf_delete(input_buf, { force = true })
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
	local fake = { stopped = false }
	function fake:set_handlers(handlers)
		self.handlers = handlers
	end
	function fake:list_threads(_, callback)
		callback({})
	end
	function fake:stop()
		self.stopped = true
	end
	ui._set_client(fake)
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
		eq(#vim.api.nvim_tabpage_list_wins(chat_tab), 3)
		eq(vim.bo[state.sessions_buf].filetype, "acp-sessions")
		eq(vim.bo[state.output_buf].filetype, "acp")
		eq(vim.bo[state.input_buf].filetype, "acp-prompt")
		eq(vim.bo[state.sessions_buf].undolevels, -1)
		eq(vim.bo[state.output_buf].undolevels, -1)
		eq(vim.wo[state.output_win].foldmethod, "expr")
		eq(vim.wo[state.output_win].foldexpr, "v:lua.acp_nvim_output_foldexpr()")
		eq(vim.wo[state.output_win].foldlevel, 1)
		eq(vim.wo[state.output_win].foldcolumn, "1")
		eq(vim.wo[state.output_win].signcolumn, "no")
		eq(vim.wo[state.output_win].statuscolumn, "%C ")
		eq(vim.wo[state.output_win].breakindent, false)
		eq(vim.wo[state.output_win].showbreak, "")
		eq(vim.b[state.output_buf].indent_guide, false)
		local output_keymaps = {}
		for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(state.output_buf, "n")) do
			output_keymaps[keymap.desc] = true
		end
		for _, description in ipairs({
			"Next Codex output section",
			"Previous Codex output item",
			"Inspect Codex output item",
			"Search Codex output",
			"Open Codex output map",
			"Yank Codex code block",
		}) do
			ok(output_keymaps[description], "missing output keymap: " .. description)
		end
		eq(vim.fn.exists(":AcpOutputMap"), 2)
		eq(vim.fn.exists(":AcpOutputItemsQuickfix"), 2)
		eq(vim.fn.exists(":AcpCodeBlockDraft"), 2)
		ok(output_ui.open_map(state))
		ok(vim.api.nvim_win_is_valid(state.output_map_win))
		eq(vim.api.nvim_win_get_config(state.output_map_win).relative, "win")
		contains(table.concat(vim.api.nvim_buf_get_lines(state.output_map_buf, 0, -1, false), "\n"), "Output Map")
		output_ui.close(state)
		eq(vim.fn.winlayout(), {
			"row",
			{
				{ "leaf", state.sessions_win },
				{ "leaf", state.output_win },
			},
		})
		local prompt = vim.api.nvim_win_get_config(state.input_win)
		eq(prompt.relative, "editor")
		eq(prompt.zindex, 50)
		contains(chunks_text(prompt.title), "Prompt")
		contains(chunks_text(prompt.footer), "<C-s> steer")
		contains(chunks_text(prompt.footer), "<C-CR> send")
		local output_position = vim.api.nvim_win_get_position(state.output_win)
		local output_info = vim.fn.getwininfo(state.output_win)[1]
		eq(prompt.col, output_position[2] + output_info.textoff + 2)
		ok(prompt.width < vim.api.nvim_win_get_width(state.output_win))
		ok(vim.wo[state.output_win].scrolloff > 0)
		eq(vim.wo[state.output_win].fillchars, "eob: ")
		eq(vim.wo[state.input_win].fillchars, "eob: ")
		contains(vim.wo[state.input_win].winhighlight, "AcpPromptBorder")
		eq(vim.api.nvim_win_get_position(state.sessions_win)[2], 0)
		eq(vim.api.nvim_win_get_tabpage(state.output_win), chat_tab)
		eq(vim.api.nvim_win_get_tabpage(state.input_win), chat_tab)
		eq(vim.api.nvim_win_get_tabpage(state.sessions_win), chat_tab)

		vim.api.nvim_win_close(state.input_win, true)
		ui.open()
		state = ui._state()
		eq(vim.api.nvim_get_current_tabpage(), chat_tab)
		eq(state.tabpage, chat_tab)
		eq(#vim.api.nvim_list_tabpages(), tab_count + 1)
		eq(#vim.api.nvim_tabpage_list_wins(chat_tab), 3)
		eq(vim.api.nvim_win_get_config(state.input_win).relative, "editor")
		eq(vim.api.nvim_tabpage_list_wins(origin_tab), origin_windows)

		vim.api.nvim_win_close(state.sessions_win, true)
		vim.cmd("AcpSessions")
		state = ui._state()
		eq(#vim.api.nvim_tabpage_list_wins(chat_tab), 3)
		eq(vim.api.nvim_get_current_win(), state.sessions_win)
		eq(vim.api.nvim_win_get_position(state.sessions_win)[2], 0)
		eq(vim.api.nvim_win_get_config(state.input_win).relative, "editor")

		local old_prompt_width = vim.api.nvim_win_get_config(state.input_win).width
		vim.api.nvim_win_set_width(state.sessions_win, 20)
		vim.api.nvim_exec_autocmds("WinResized", {})
		ok(
			vim.wait(100, function()
				return vim.api.nvim_win_get_config(state.input_win).width > old_prompt_width
			end),
			"expected the floating prompt to follow chat-window resizing"
		)

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
	eq(fake.stopped, true)
	if not passed then
		error(err, 2)
	end
end)

test("sessions split lists and resumes Codex threads", function()
	ui._reset()
	ui.setup({ auto_context = false, command = { "missing-codex" } })
	local fake = {
		threads = {
			{ id = "thread-a", preview = "First session", cwd = "/tmp/project" },
			{ id = "thread-b", preview = "Second session", cwd = "/tmp/project" },
		},
	}

	function fake:set_handlers(handlers)
		self.handlers = handlers
	end

	function fake:list_threads(opts, callback)
		self.list_opts = opts
		callback(vim.deepcopy(self.threads))
	end

	function fake:resume_thread(thread_id, opts, callback)
		self.resumed = { thread_id = thread_id, opts = opts }
		callback({
			thread = {
				id = thread_id,
				cwd = opts.cwd,
				turns = {
					{
						items = {
							{
								id = "restored-user",
								type = "userMessage",
								content = { { type = "text", text = "Restore the blocks" } },
							},
							{
								id = "restored-command",
								type = "commandExecution",
								command = "true",
								status = "completed",
								exitCode = 0,
							},
							{
								id = "restored-tool",
								type = "dynamicToolCall",
								tool = "inspect",
								status = "completed",
							},
							{
								id = "restored-agent",
								type = "agentMessage",
								text = "Restored.\n```lua\nreturn true\n```",
							},
						},
					},
				},
			},
			cwd = opts.cwd,
		})
	end

	function fake:stop() end

	ui._set_client(fake)
	local passed, err = pcall(function()
		ui.open()
		local state = ui._state()
		eq(fake.list_opts.cwd, vim.fs.normalize(vim.fn.getcwd()))
		eq(fake.list_opts.source_kinds, { "cli", "vscode", "appServer" })
		eq(vim.api.nvim_buf_get_lines(state.sessions_buf, 0, -1, false), {
			"* New chat",
			"  First session",
			"  Second session",
		})

		vim.api.nvim_set_current_win(state.sessions_win)
		vim.api.nvim_win_set_cursor(state.sessions_win, { 1, 0 })
		ui.select_session()
		eq(fake.resumed, nil)
		eq(vim.api.nvim_get_current_win(), state.input_win)

		vim.api.nvim_set_current_win(state.sessions_win)
		vim.api.nvim_win_set_cursor(state.sessions_win, { 3, 0 })
		ui.select_session()

		eq(fake.resumed.thread_id, "thread-b")
		eq(state.thread_id, "thread-b")
		eq(vim.api.nvim_get_current_win(), state.input_win)
		eq(
			vim.tbl_map(function(block)
				return block.kind
			end, state.chat.blocks),
			{ "user", "activity", "agent" }
		)
		eq(#state.chat:activities(), 1)
		eq(state.chat:code_block_at(state.chat.by_id["restored-agent"].line2 - 1).language, "lua")
		local lines = vim.api.nvim_buf_get_lines(state.sessions_buf, 0, -1, false)
		eq(lines, { "* Second session", "  First session" })

		fake.threads = { fake.threads[1] }
		vim.cmd("AcpSessions")
		lines = vim.api.nvim_buf_get_lines(state.sessions_buf, 0, -1, false)
		eq(lines, { "* Second session", "  First session" })
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
		fake.handlers.on_notification("item/completed", {
			threadId = "thread-1",
			turnId = "turn-1",
			item = {
				id = "command-1",
				type = "commandExecution",
				command = "rg blocks",
				status = "completed",
				exitCode = 0,
			},
		})
		fake.handlers.on_notification("item/completed", {
			threadId = "thread-1",
			turnId = "turn-1",
			item = {
				id = "tool-1",
				type = "dynamicToolCall",
				tool = "inspect",
				status = "completed",
			},
		})

		fake.handlers.on_notification("item/agentMessage/delta", {
			threadId = "thread-1",
			turnId = "turn-1",
			itemId = "message-1",
			delta = "Implemented.",
		})
		local buffered_tick = vim.api.nvim_buf_get_changedtick(state.output_buf)
		local detail_lines = {}
		for index = 1, 40 do
			table.insert(detail_lines, ("Detail line %d"):format(index))
		end
		fake.handlers.on_notification("item/agentMessage/delta", {
			threadId = "thread-1",
			turnId = "turn-1",
			itemId = "message-1",
			delta = "\n" .. table.concat(detail_lines, "\n"),
		})
		eq(vim.api.nvim_buf_get_changedtick(state.output_buf), buffered_tick)
		ok(
			vim.wait(250, function()
				local text = table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n")
				return text:find("Detail line 40", 1, true) ~= nil
			end, 5),
			"expected batched output to flush promptly"
		)
		ok(
			state.output_cache.changedtick ~= vim.api.nvim_buf_get_changedtick(state.output_buf),
			"full semantic parsing should stay paused during an active turn"
		)
		local content_line = vim.api.nvim_buf_line_count(state.output_buf) - state.prompt_spacer_rows
		vim.cmd("redraw")
		local last_position = vim.fn.screenpos(state.output_win, content_line, 1)
		local prompt_top = vim.api.nvim_win_get_config(state.input_win).row + 1
		ok(last_position.row > 0, "expected the latest response line to remain visible")
		ok(last_position.row < prompt_top, "the floating prompt must not cover the latest response")
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
		ok(
			vim.wait(350, function()
				return state.output_cache.changedtick == vim.api.nvim_buf_get_changedtick(state.output_buf)
			end, 5),
			"expected semantic output metadata to refresh after the turn"
		)

		local output = table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n")
		contains(output, "Simplify this plugin")
		contains(output, "Implemented.")
		eq(count(output, "Implemented."), 1)
		eq(state.diff, "--- a/file\n+++ b/file")
		eq(state.tokens.totalTokens, 42)
		eq(state.busy, false)
		eq(
			vim.tbl_map(function(block)
				return block.kind
			end, state.chat.blocks),
			{ "user", "activity", "agent" }
		)
		contains(state.chat.by_id["message-1"].text, "Detail line 40")
		eq(state.output_cache.chat_blocks, state.chat.blocks)
		local activity = state.chat:activities()[1]
		eq(activity.counts, { command = 1, tool = 1, file = 0 })
		eq(
			vim.api.nvim_win_call(state.output_win, function()
				return vim.fn.foldlevel(activity.line)
			end),
			2
		)
		eq(
			vim.api.nvim_win_call(state.output_win, function()
				return vim.fn.foldclosed(activity.line)
			end),
			activity.line
		)
		vim.api.nvim_win_set_cursor(state.output_win, { state.chat.blocks[1].header_line, 0 })
		ok(output_ui.jump_section(state, 1))
		eq(vim.api.nvim_win_get_cursor(state.output_win)[1], activity.line)
		ok(output_ui.jump_section(state, 1))
		eq(vim.api.nvim_win_get_cursor(state.output_win)[1], state.chat.by_id["message-1"].header_line)
		vim.api.nvim_win_set_cursor(state.output_win, { activity.line, 0 })
		eq(output_ui.current_item(state).kind, "activity")
		ok(output_ui.yank_section(state))
		local activity_text = vim.fn.getreg('"')
		contains(activity_text, "rg blocks")
		contains(activity_text, "inspect")
		ok(not activity_text:find("Simplify this plugin", 1, true))
		local windows_before = {}
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			windows_before[winid] = true
		end
		ok(output_ui.inspect(state, activity))
		local preview_win
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			if not windows_before[winid] then
				preview_win = winid
				break
			end
		end
		ok(preview_win and vim.api.nvim_win_is_valid(preview_win), "expected an activity detail float")
		local preview_text =
			table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview_win), 0, -1, false), "\n")
		contains(preview_text, "rg blocks")
		contains(preview_text, "inspect")
		vim.api.nvim_win_close(preview_win, true)
		eq(vim.api.nvim_buf_get_lines(state.output_buf, 0, state.chat.line_count, false), state.chat:render_lines())
		eq(vim.api.nvim_buf_line_count(state.output_buf), state.chat.line_count + state.prompt_spacer_rows)
		eq(ui.new_chat({ keep_layout = true }), true)
		eq(#ui._state().chat.blocks, 0)
		eq(fake.unsubscribed, "thread-1")
	end)
	ui._reset()
	if not passed then
		error(err, 2)
	end
	eq(fake.stopped, true)
end)

test("control-s steers the active turn instead of queueing", function()
	ui._reset()
	ui.setup({ auto_context = false, follow_up = "queue", command = { "missing-codex" } })
	local fake = { turns = {}, steers = {} }

	function fake:set_handlers(handlers)
		self.handlers = handlers
	end

	function fake:start_thread(opts, callback)
		callback({
			thread = { id = "thread-steer", cwd = opts.cwd, turns = {} },
			cwd = opts.cwd,
		})
	end

	function fake:start_turn(thread_id, payload, callback)
		table.insert(self.turns, { thread_id = thread_id, payload = payload })
		callback({ turn = { id = "turn-steer", status = "inProgress" } })
	end

	function fake:steer_turn(thread_id, turn_id, payload, callback)
		table.insert(self.steers, { thread_id = thread_id, turn_id = turn_id, payload = payload })
		self.steer_callback = callback
	end

	function fake:list_threads(_, callback)
		callback({})
	end

	function fake:stop() end

	ui._set_client(fake)
	local passed, err = pcall(function()
		ui.open()
		local state = ui._state()
		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "Start the implementation" })
		ui.send()
		eq(state.turn_id, "turn-steer")
		eq(#fake.turns, 1)
		fake.handlers.on_notification("item/agentMessage/delta", {
			threadId = "thread-steer",
			turnId = "turn-steer",
			itemId = "shared-message",
			delta = "Before steering.",
		})
		ok(
			vim.wait(250, function()
				return state.chat.by_id["shared-message"] ~= nil
			end, 5),
			"expected the initial response block to flush"
		)

		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "Keep the public API unchanged" })
		vim.api.nvim_set_current_win(state.input_win)
		local control_s = vim.api.nvim_replace_termcodes("<C-s>", true, false, true)
		vim.api.nvim_feedkeys(control_s, "x", false)

		eq(#fake.steers, 1)
		eq(fake.steers[1].thread_id, "thread-steer")
		eq(fake.steers[1].turn_id, "turn-steer")
		eq(fake.steers[1].payload.input[1].text, "Keep the public API unchanged")
		eq(#state.queue, 0)
		eq(#state.pending_instructions, 1)
		eq(state.pending_instructions[1].kind, "steer")
		ok(vim.api.nvim_win_is_valid(state.instruction_win))
		eq(vim.api.nvim_get_current_win(), state.input_win)
		local prompt_config = vim.api.nvim_win_get_config(state.input_win)
		local instruction_config = vim.api.nvim_win_get_config(state.instruction_win)
		eq(instruction_config.relative, "editor")
		eq(instruction_config.focusable, false)
		eq(instruction_config.col, prompt_config.col)
		eq(instruction_config.width, prompt_config.width)
		eq(instruction_config.row + instruction_config.height + 1, prompt_config.row)
		local instruction_text = table.concat(vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false), "\n")
		contains(instruction_text, "STEER")
		contains(instruction_text, "Keep the public API unchanged")
		fake.handlers.on_notification("item/reasoning/textDelta", {
			threadId = "thread-steer",
			turnId = "turn-steer",
			delta = "Still finishing the previous thought.",
		})
		eq(#state.pending_instructions, 1)
		fake.steer_callback({})
		contains(
			table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n"),
			transcript.header("user", " (steer)")
		)

		fake.handlers.on_notification("item/agentMessage/delta", {
			threadId = "thread-steer",
			turnId = "turn-steer",
			itemId = "shared-message",
			delta = "After steering.",
		})
		eq(#state.pending_instructions, 0)
		ok(not state.instruction_win or not vim.api.nvim_win_is_valid(state.instruction_win))
		ok(
			vim.wait(250, function()
				local continuation = state.chat.by_id["shared-message:agent:2"]
				return continuation and continuation.text == "After steering."
			end, 5),
			"expected a continuation response after the steer block"
		)
		local ordered = table.concat(state.chat:render_lines(), "\n")
		local before = ordered:find("Before steering.", 1, true)
		local steer = ordered:find("Keep the public API unchanged", 1, true)
		local after = ordered:find("After steering.", 1, true)
		ok(before and steer and after and before < steer and steer < after, "streamed output must preserve event order")
		eq(vim.api.nvim_buf_get_lines(state.output_buf, 0, state.chat.line_count, false), state.chat:render_lines())

		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "Run the tests afterward" })
		ui.send()
		eq(#fake.steers, 1)
		eq(#state.queue, 1)
		eq(#state.pending_instructions, 1)
		eq(state.pending_instructions[1].kind, "queued")
		ok(vim.api.nvim_win_is_valid(state.instruction_win))
		instruction_text = table.concat(vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false), "\n")
		contains(instruction_text, "QUEUED")
		contains(instruction_text, "Run the tests afterward")

		fake.handlers.on_notification("turn/completed", {
			threadId = "thread-steer",
			turn = { id = "turn-steer", status = "completed" },
		})
		ok(vim.wait(100, function()
			return #fake.turns == 2
		end))
		eq(fake.turns[2].payload.input[1].text, "Run the tests afterward")
		eq(#state.pending_instructions, 0)
		ok(not state.instruction_win or not vim.api.nvim_win_is_valid(state.instruction_win))
	end)
	ui._reset()
	if not passed then
		error(err, 2)
	end
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
	state.instruction_sequence = 1
	state.queue = {
		{
			_acp_instruction_id = "instruction:1",
			text = "Preserve this queued instruction",
			payload = { input = { { type = "text", text = "Preserve this queued instruction" } } },
		},
	}
	state.pending_instructions = {
		{ id = "instruction:1", kind = "queued", text = "Preserve this queued instruction" },
	}
	ui.open()
	ok(vim.api.nvim_win_is_valid(state.instruction_win))
	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "preserve this draft" })
	live_client.on_notification("item/agentMessage/delta", {
		threadId = "thread-hot-reload",
		turnId = "turn-hot-reload",
		itemId = "message-before-reload",
		delta = "Before reload.",
	})
	ok(
		vim.wait(250, function()
			return state.chat.by_id["message-before-reload"] ~= nil
		end, 5),
		"expected a structured block before reload"
	)
	local legacy_block = state.chat.by_id["message-before-reload"]
	legacy_block.lines[legacy_block.header_offset] = "## Codex"
	vim.bo[state.output_buf].modifiable = true
	vim.api.nvim_buf_set_lines(
		state.output_buf,
		legacy_block.header_line - 1,
		legacy_block.header_line,
		false,
		{ "## Codex" }
	)
	vim.bo[state.output_buf].modifiable = false
	vim.bo[state.output_buf].filetype = "markdown"

	local tabpage = state.tabpage
	local sessions_buf = state.sessions_buf
	local sessions_win = state.sessions_win
	local output_buf = state.output_buf
	local input_buf = state.input_buf
	local input_win = state.input_win
	local instruction_buf = state.instruction_buf
	local instruction_win = state.instruction_win
	local chat = state.chat
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
		ok(state.chat == chat, "expected the same chat model table")
		ok(getmetatable(state.chat) == require("acp.blocks").Model, "expected methods from the reloaded block model")
		ok(require("acp.blocks").for_buffer(output_buf) == state.chat, "expected the output buffer to rebind")
		contains(state.chat.by_id["message-before-reload"].text, "Before reload.")
		eq(
			vim.api.nvim_buf_get_lines(
				output_buf,
				state.chat.by_id["message-before-reload"].header_line - 1,
				state.chat.by_id["message-before-reload"].header_line,
				false
			)[1],
			render.header("agent")
		)
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
		eq(state.sessions_buf, sessions_buf)
		eq(state.sessions_win, sessions_win)
		eq(state.output_buf, output_buf)
		eq(state.input_buf, input_buf)
		eq(state.input_win, input_win)
		eq(state.instruction_buf, instruction_buf)
		eq(state.instruction_win, instruction_win)
		ok(vim.api.nvim_win_is_valid(state.instruction_win))
		contains(
			table.concat(vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false), "\n"),
			"Preserve this queued instruction"
		)
		eq(vim.bo[state.output_buf].filetype, "acp")
		eq(vim.api.nvim_win_get_config(state.input_win).relative, "editor")
		eq(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), { "preserve this draft" })

		live_client.on_notification("item/agentMessage/delta", {
			threadId = "thread-hot-reload",
			turnId = "turn-hot-reload",
			itemId = "message-after-reload",
			delta = "Still connected.",
		})
		ok(
			vim.wait(250, function()
				return table
					.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n")
					:find("Still connected.", 1, true) ~= nil
			end, 5),
			"expected output from the reloaded client to flush promptly"
		)
		local output = table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n")
		eq(
			vim.tbl_map(function(block)
				return block.kind
			end, state.chat.blocks),
			{ "agent", "agent" }
		)
		eq(vim.api.nvim_buf_get_lines(output_buf, 0, state.chat.line_count, false), state.chat:render_lines())
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
