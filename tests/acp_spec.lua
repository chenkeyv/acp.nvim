local jsonrpc = require("acp.jsonrpc")
local actions = require("acp.actions")
local acp_changes = require("acp.changes")
local code_actions = require("acp.code_actions")
local acp_commands = require("acp.commands")
local acp_config = require("acp.config")
local acp_context = require("acp.context")
local acp_diagnostics = require("acp.diagnostics")
local acp_health = require("acp.health")
local file_review = require("acp.file_review")
local hover = require("acp.hover")
local history = require("acp.history")
local acp_output = require("acp.output")
local permission = require("acp.permission")
local picker = require("acp.picker")
local prompt_view = require("acp.prompt_view")
local references = require("acp.references")
local session_view = require("acp.session_view")
local source_view = require("acp.source_view")
local symbols = require("acp.symbols")
local treesitter = require("acp.treesitter")
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
		"AcpActions",
		"AcpChanges",
		"AcpOutput",
		"AcpOutputSearch",
		"AcpOutputYank",
		"AcpOutputDraft",
		"AcpOutputOpen",
		"AcpOutputInspect",
		"AcpCodeBlocks",
		"AcpCodeBlockYank",
		"AcpOutputLocations",
		"AcpOutputQuickfix",
		"AcpOutputProblems",
		"AcpDiagnostics",
		"AcpCommands",
		"AcpConfig",
		"AcpCodeActions",
		"AcpHover",
		"AcpReferences",
		"AcpSymbols",
		"AcpTreeSitter",
		"AcpHistory",
		"AcpRestore",
		"AcpHistoryDraft",
		"AcpAddContext",
		"AcpFixDiagnostics",
		"AcpHealth",
	}) do
		eq(vim.fn.exists(":" .. command), 2)
	end
end)

test("action picker lines render workflow details", function()
	local run = function() end
	local lines, line_actions = actions.picker_lines({
		{
			label = "Output outline",
			detail = "Jump across transcript sections",
			key = "<leader>av",
			scope = "session",
			run = run,
		},
	})
	local text = table.concat(lines, "\n")

	ok(text:find("ACP Actions", 1, true))
	ok(text:find("Output outline", 1, true))
	ok(text:find("<leader>av", 1, true))
	ok(text:find("[session]", 1, true))
	eq(line_actions[3].run, run)
	eq(line_actions[4].run, run)
end)

test("floating picker filters rows while preserving source row mapping", function()
	local view = picker.open({
		name = "ACP://test-picker",
		filetype = "acp-test-picker",
		lines = {
			"ACP Test Picker",
			"",
			"alpha action",
			"beta action",
			"gamma detail",
			"",
			"Press <Enter> to select.",
		},
		title = " ACP test picker ",
	})

	view.filter("beta")
	local filtered = table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
	ok(filtered:find("Filter: beta", 1, true))
	ok(filtered:find("beta action", 1, true))
	ok(not filtered:find("alpha action", 1, true))
	vim.api.nvim_win_set_cursor(view.winid, { 3, 0 })
	eq(view.source_row(), 4)

	view.filter("")
	local restored = table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
	ok(restored:find("alpha action", 1, true))
	eq(view.source_row(), 3)
	view.close()
end)

test("floating picker renders preview windows for mapped source rows", function()
	local view = picker.open({
		name = "ACP://test-preview-picker",
		filetype = "acp-test-picker",
		lines = {
			"ACP Test Picker",
			"",
			"alpha action",
			"beta action",
		},
		title = " ACP test picker ",
		preview = function(row)
			if not row then
				return nil
			end
			return {
				lines = { ("preview row %d"):format(row) },
				filetype = "lua",
				title = " Preview ",
			}
		end,
	})

	ok(view.preview_winid and vim.api.nvim_win_is_valid(view.preview_winid), "preview window should open")
	eq(vim.bo[view.preview_bufnr].filetype, "lua")
	eq(vim.api.nvim_buf_get_lines(view.preview_bufnr, 0, -1, false)[1], "preview row 3")

	view.filter("beta")
	eq(vim.api.nvim_buf_get_lines(view.preview_bufnr, 0, -1, false)[1], "preview row 4")
	view.close()
	ok(not vim.api.nvim_win_is_valid(view.preview_winid), "preview window should close with picker")
end)

test("prompt view renders ghost text and draft stats", function()
	local empty = prompt_view.info({ "" })
	ok(empty.empty)
	ok(empty.ghost:find("<C%-s> send"))

	local busy = prompt_view.info({ "" }, { busy = true })
	ok(busy.ghost:find("responding", 1, true))

	local draft = prompt_view.info({ "hello ACP", "with context" })
	ok(not draft.empty)
	ok(draft.stats:find("2 lines", 1, true))
	ok(draft.stats:find("22 chars", 1, true))
	ok(draft.stats:find("4 words", 1, true))
end)

test("session panel view renders status and badges", function()
	local lines, line_ids, styles = session_view.panel({
		{
			id = 1,
			adapter = "test",
			model = "test-model",
			run_status = "streaming",
		},
		{
			id = 2,
			adapter = "test",
			run_status = "error: failed",
		},
	}, 1, function(session)
		return session.id == 1 and 2 or 0
	end)

	local text = table.concat(lines, "\n")
	ok(text:find("Sessions", 1, true))
	ok(text:find("> #1 test test-model", 1, true))
	ok(text:find("streaming  2 change(s)", 1, true))
	ok(text:find("error: failed", 1, true))
	eq(line_ids[3], 1)
	eq(line_ids[4], 1)
	eq(styles[1].line_hl_group, "AcpSessionHeader")
	eq(styles[3].line_hl_group, "AcpSessionCurrent")
	eq(styles[4].line_hl_group, "AcpSessionBusy")
	eq(styles[6].line_hl_group, "AcpSessionError")
end)

test("source view renders context range marks", function()
	local marks = source_view.marks({
		id = 9,
		source = {
			bufnr = 1,
			cursor = { 4, 0 },
			range = {
				line1 = 2,
				line2 = 4,
			},
		},
	})

	eq(#marks, 3)
	eq(marks[1].line, 2)
	eq(marks[3].line, 4)
	eq(marks[1].opts.line_hl_group, "AcpSourceContext")
	eq(marks[1].opts.virt_text[1][1], " ACP #9 context ")
	eq(marks[2].opts.virt_text, nil)
end)

test("health report checks adapter commands and metadata", function()
	local items = acp_health.items({
		default_adapter = "test",
		adapters = {
			test = {
				command = { "missing-acp-test-command" },
				metadata = {
					model = "test-model",
					context_window = 1000,
				},
			},
		},
	}, { adapter_name = "test" })
	local text = table.concat(vim.tbl_map(function(item)
		return ("%s:%s"):format(item.level, item.message)
	end, items), "\n")

	ok(text:find("error:test adapter command is missing: missing-acp-test-command", 1, true))
	ok(text:find("info:Prompt metadata model: test-model", 1, true))
	ok(text:find("info:Prompt metadata context window: 1000", 1, true))

	local codex_items = acp_health.items({
		default_adapter = "codex",
		adapters = {
			codex = {
				command = { "missing-acp-test-command" },
				codex_command = { "missing-codex-test-command" },
				metadata = "codex",
			},
		},
	}, { adapter_name = "codex" })
	local codex_text = table.concat(vim.tbl_map(function(item)
		return ("%s:%s"):format(item.level, item.message)
	end, codex_items), "\n")

	ok(codex_text:find("error:codex adapter command is missing: missing-acp-test-command", 1, true))
	ok(codex_text:find("warn:Codex CLI is missing: missing-codex-test-command", 1, true))
end)

test("health renderer uses Neovim health reporters", function()
	local reports = {}
	acp_health.render({
		{ level = "ok", message = "adapter ready" },
		{ level = "warn", message = "metadata partial" },
	}, {
		start = function(message)
			table.insert(reports, "start:" .. message)
		end,
		ok = function(message)
			table.insert(reports, "ok:" .. message)
		end,
		warn = function(message)
			table.insert(reports, "warn:" .. message)
		end,
	})

	eq(reports, {
		"start:acp.nvim",
		"ok:adapter ready",
		"warn:metadata partial",
	})
end)

test("output dashboard and section helpers are rendered", function()
	local lines = acp_output.dashboard_lines({
		id = 7,
		adapter = "test",
		mode = "window",
		model = "test-model",
		context_window = 1000,
	})
	local text = table.concat(lines, "\n")

	ok(text:find("ACP: test", 1, true))
	ok(text:find("Session: #7 | Mode: window", 1, true))
	ok(text:find("Model: test-model | Context: 1k", 1, true))
	ok(text:find("Transcript: 0 sections | 0 code | 0 locs | 0 changes", 1, true))
	ok(text:find("K inspect", 1, true))
	ok(text:find("[[/]] sections", 1, true))
	ok(text:find("<leader>ax search", 1, true))
	ok(text:find("<leader>ab code", 1, true))
	ok(text:find("<leader>ag locs", 1, true))

	eq(acp_output.line_style("You").line_hl_group, "AcpUserHeader")
	eq(acp_output.line_style("You").sign_text, "U>")
	eq(acp_output.line_style("You").separator, "---- USER: Prompt ----")
	eq(acp_output.line_style("Agent").sign_text, "A>")
	eq(acp_output.line_style("Agent").separator, "---- AGENT: Response ----")
	eq(acp_output.line_style("Transcript: 1 section | 0 code | 0 locs | 0 changes").line_hl_group, "AcpOutputMeta")
	eq(acp_output.line_style("Status: error: failed").line_hl_group, "AcpStatusError")
	eq(acp_output.line_style("Status: error: failed").sign_text, "E!")
	eq(acp_output.line_style("Status: error: failed").separator, "---- STATUS: Error ----")
	eq(acp_output.line_style("Tool: build").sign_text, "T>")
	eq(acp_output.line_style("Wrote lua/acp/init.lua").sign_text, "F>")
	eq(acp_output.next_section({ "ACP: test", "", "You", "hello", "Agent" }, 1, 1), 3)
	eq(acp_output.next_section({ "ACP: test", "", "You", "hello", "Agent" }, 5, -1), 3)

	local sections = acp_output.sections({ "ACP: test", "", "You", "hello", "Agent", "world" })
	eq(#sections, 3)
	eq(sections[2].kind, "USER")
	eq(sections[2].preview, "hello")
	local current = acp_output.current_section({ "ACP: test", "", "You", "hello", "Agent", "world" }, 4)
	eq(current.kind, "USER")
	eq(current.title, "Prompt")
	eq(current.line, 3)
	ok(acp_output.window_title({ id = 7, adapter = "test" }, { current_section = current }):find("at USER: Prompt", 1, true))
	local range = acp_output.section_range({ "ACP: test", "", "You", "hello", "", "Agent", "world" }, 4)
	eq(range.kind, "USER")
	eq(range.line1, 3)
	eq(range.line2, 5)
	local section_lines, section_range = acp_output.section_lines({ "ACP: test", "", "You", "hello", "", "Agent", "world" }, 4)
	eq(section_range.kind, "USER")
	eq(section_lines, { "You", "hello" })
	local section_text, text_range = acp_output.section_text({ "ACP: test", "", "You", "hello", "", "Agent", "world" }, 4)
	eq(text_range.line1, 3)
	eq(section_text, "You\nhello")
	local section_summaries = acp_output.section_summaries({
		"ACP: test",
		"Session: #7 | Mode: window",
		"You",
		"hello output",
		"",
		"Agent",
		"```lua",
		"print(1)",
		"```",
		"Status: done",
	})
	eq(section_summaries[1], nil)
	eq(section_summaries[3].label, " 1L | 2w ")
	eq(section_summaries[6].label, " 3L | 1 code ")
	eq(section_summaries[10], nil)
	local outline, line_sections = acp_output.outline_lines(sections)
	local outline_text = table.concat(outline, "\n")
	ok(outline_text:find("ACP Output Outline", 1, true))
	ok(outline_text:find("USER", 1, true))
	eq(line_sections[3].kind, "SESSION")
	local transcript_entries = acp_output.transcript_entries({ "ACP: test", "", "You", "hello", "Status: running" })
	eq(#transcript_entries, 4)
	eq(transcript_entries[2].kind, "USER")
	eq(transcript_entries[3].line, 4)
	local transcript_picker, line_entries = acp_output.transcript_entry_lines(transcript_entries)
	local transcript_text = table.concat(transcript_picker, "\n")
	ok(transcript_text:find("ACP Output Search", 1, true))
	ok(transcript_text:find("hello", 1, true))
	eq(line_entries[4].text, "You")

	local fold_lines = { "ACP: test", "Session: #7 | Mode: window", "You", "hello", "Agent", "world" }
	eq(acp_output.fold_level(fold_lines, 1), ">1")
	eq(acp_output.fold_level(fold_lines, 2), "1")
	eq(acp_output.fold_level(fold_lines, 3), ">1")
	local fold_text = acp_output.fold_text(fold_lines, 3, 4)
	ok(fold_text:find("USER", 1, true))
	ok(fold_text:find("2 lines", 1, true))
	ok(fold_text:find("hello", 1, true))

	eq(acp_output.animation_frame(1), "|")
	eq(acp_output.animation_frame(5), "|")
	ok(acp_output.ghost_text({ busy = true, run_status = "streaming" }, {}, 2):find("streaming", 1, true))
	ok(acp_output.ghost_text({ busy = false }, { "ACP: test", "" }):find("Ready", 1, true))
	ok(acp_output.cursor_hint({ "You", "hello" }, 1, 0):find("<leader>ay yank", 1, true))
	local blocks = acp_output.code_blocks({ "Agent", "```lua", "print(1)", "```", "```", "plain" })
	eq(#blocks, 2)
	eq(blocks[1].start_line, 2)
	eq(blocks[1].end_line, 4)
	eq(blocks[1].language, "lua")
	eq(blocks[1].filetype, "lua")
	eq(blocks[1].line_count, 1)
	eq(blocks[1].lines[1], "print(1)")
	eq(blocks[2].language, "text")
	eq(blocks[2].end_line, 6)
	eq(blocks[2].closed, false)
	eq(blocks[2].lines[1], "plain")
	local block_at = acp_output.code_block_at({ "Agent", "```lua", "print(1)", "```" }, 3)
	eq(block_at.language, "lua")
	eq(block_at.lines[1], "print(1)")
	eq(acp_output.code_block_text(block_at), "print(1)")
	ok(acp_output.cursor_hint({ "Agent", "```lua", "print(1)", "```" }, 3, 0):find("yank code", 1, true))
	local block_picker, line_blocks = acp_output.code_block_lines(blocks)
	local block_text = table.concat(block_picker, "\n")
	ok(block_text:find("ACP Output Code Blocks", 1, true))
	ok(block_text:find("lua", 1, true))
	ok(block_text:find("<leader>aY to yank", 1, true))
	eq(line_blocks[3].language, "lua")

	local ref_file = vim.fn.tempname() .. ".lua"
	vim.fn.writefile({ "local one = 1", "local two = 2" }, ref_file)
	local ref_line = ("Check %s:2:7 for details."):format(ref_file)
	local refs = acp_output.file_references({
		ref_line,
		"Ignore https://example.com:443 and missing-file.lua:3",
	})
	eq(#refs, 1)
	eq(refs[1].path, vim.fn.fnamemodify(ref_file, ":p"))
	eq(refs[1].line, 2)
	eq(refs[1].column, 7)
	eq(refs[1].source_col, ref_line:find(ref_file, 1, true))
	local ref_at = acp_output.file_reference_at({ ref_line }, 1, ref_line:find(ref_file, 1, true), {})
	eq(ref_at.path, refs[1].path)
	eq(ref_at.line, 2)
	eq(ref_at.column, 7)
	ok(acp_output.cursor_hint({ ref_line }, 1, ref_line:find(ref_file, 1, true), {}):find("gf source", 1, true))
	local ref_picker, line_refs = acp_output.file_reference_lines(refs)
	local ref_text = table.concat(ref_picker, "\n")
	ok(ref_text:find("ACP Output Locations", 1, true))
	ok(ref_text:find(":2:7", 1, true))
	ok(ref_text:find("Q for quickfix", 1, true))
	eq(line_refs[3].line, 2)
	local qf_items = acp_output.file_reference_quickfix_items(refs)
	eq(#qf_items, 1)
	eq(qf_items[1].filename, refs[1].path)
	eq(qf_items[1].lnum, 2)
	eq(qf_items[1].col, 7)
	local problem_items = acp_output.problem_diagnostics({
		"Status: error: failed to start session",
		"",
		"stderr:",
		"permission denied",
		"",
		"Terminal output truncated to the configured byte limit.",
	})
	eq(#problem_items, 3)
	eq(problem_items[1].lnum, 0)
	eq(problem_items[1].severity, vim.diagnostic.severity.ERROR)
	ok(problem_items[1].message:find("failed to start session", 1, true))
	eq(problem_items[2].message, "stderr: permission denied")
	eq(problem_items[3].severity, vim.diagnostic.severity.WARN)
	eq(acp_output.problem_diagnostic_at({ "Status: error: failed" }, 1).message, "error: failed")
	ok(acp_output.cursor_hint({ "Status: error: failed" }, 1, 0):find("problems", 1, true))
	local stats = acp_output.transcript_stats({
		"ACP: test",
		"```lua",
		"print(1)",
		"```",
		("See %s:2"):format(ref_file),
	}, { change_count = 2 })
	eq(stats.sections, 1)
	eq(stats.code_blocks, 1)
	eq(stats.locations, 1)
	eq(stats.changes, 2)
	vim.fn.delete(ref_file)
end)

test("LSP references are flattened and rendered for picker", function()
	local uri = vim.uri_from_fname("/tmp/acp-reference.lua")
	local flattened = references.flatten({
		{
			uri = uri,
			range = {
				start = { line = 1, character = 0 },
				["end"] = { line = 1, character = 5 },
			},
		},
		{
			targetUri = uri,
			targetSelectionRange = {
				start = { line = 3, character = 0 },
				["end"] = { line = 4, character = 1 },
			},
		},
		{
			uri = uri,
		},
	})

	eq(#flattened, 2)
	local range = references.range(flattened[2])
	eq(range.line1, 4)
	eq(range.line2, 5)

	local lines, line_references = references.picker_lines(flattened)
	local text = table.concat(lines, "\n")
	ok(text:find("acp%-reference%.lua:2"))
	ok(text:find("acp%-reference%.lua:4"))
	eq(line_references[3].uri, uri)
end)

test("diagnostic picker lines render source and code", function()
	local lines, line_items = acp_diagnostics.picker_lines({
		{
			lnum = 1,
			col = 4,
			severity = vim.diagnostic.severity.ERROR,
			source = "lua_ls",
			code = "undefined-global",
			message = "undefined global missing",
		},
	})
	local text = table.concat(lines, "\n")

	ok(text:find("2:5 ERROR [lua_ls] (undefined-global)", 1, true))
	ok(text:find("undefined global missing", 1, true))
	eq(line_items[3].message, "undefined global missing")
	eq(line_items[4].message, "undefined global missing")

	local range = acp_diagnostics.range({
		lnum = 2,
		end_lnum = 4,
	})
	eq(range.line1, 3)
	eq(range.line2, 5)
end)

test("LSP hover markdown content is normalized", function()
	local text = hover.text({
		contents = {
			{
				language = "lua",
				value = "local value: string",
			},
			"Second paragraph",
			{
				kind = "markdown",
				value = "**docs**",
			},
		},
	})

	eq(text, "local value: string\nSecond paragraph\n**docs**")
	eq(hover.text({ contents = {} }), nil)
end)

test("Tree-sitter nodes are collected and rendered for picker", function()
	local root = {}
	function root:type()
		return "chunk"
	end
	function root:range()
		return 0, 0, 4, 0
	end

	local child = {}
	function child:type()
		return "function_declaration"
	end
	function child:range()
		return 1, 2, 3, 5
	end
	function child:parent()
		return root
	end

	local original_treesitter = vim.treesitter
	local original_get_node = original_treesitter and original_treesitter.get_node
	vim.treesitter = vim.treesitter or {}
	vim.treesitter.get_node = function()
		return child
	end

	local node_list, err = treesitter.nodes(1, { 2, 0 })
	if original_treesitter then
		vim.treesitter.get_node = original_get_node
	else
		vim.treesitter = nil
	end

	eq(err, nil)
	eq(#node_list, 2)
	eq(node_list[1].type, "function_declaration")
	eq(node_list[2].type, "chunk")
	local line1, line2 = treesitter.range_lines(node_list[1])
	eq(line1, 2)
	eq(line2, 4)

	local lines, line_nodes = treesitter.picker_lines(node_list)
	local text = table.concat(lines, "\n")
	ok(text:find("function_declaration lines 2-4", 1, true))
	ok(text:find("  chunk lines 1-5", 1, true))
	eq(line_nodes[3].type, "function_declaration")
	eq(line_nodes[4].type, "chunk")
end)

test("LSP code actions are flattened and rendered for picker", function()
	local flattened = code_actions.flatten({
		{
			title = "Apply quick fix",
			kind = "quickfix",
			isPreferred = true,
			edit = {},
			diagnostics = {
				{ message = "missing value" },
			},
		},
		{
			title = "Run command",
			command = {
				command = "example.command",
			},
		},
		{
			title = "",
			kind = "empty",
		},
	})

	eq(#flattened, 2)
	eq(code_actions.kind_label(flattened[1]), "quickfix")
	eq(code_actions.kind_label(flattened[2]), "command")
	eq(code_actions.diagnostic_count(flattened[1]), 1)
	ok(code_actions.has_edit(flattened[1]))

	local lines, line_actions = code_actions.picker_lines(flattened)
	local text = table.concat(lines, "\n")
	ok(text:find("Apply quick fix  quickfix [preferred, edit]", 1, true))
	ok(text:find("1 diagnostic(s)", 1, true))
	ok(text:find("Run command  command [command]", 1, true))
	eq(line_actions[3].title, "Apply quick fix")
	eq(line_actions[5].title, "Run command")
end)

test("LSP symbols are flattened and rendered for picker", function()
	local flattened = symbols.flatten({
		{
			name = "Example",
			kind = 5,
			detail = "class detail",
			range = {
				start = { line = 0, character = 0 },
				["end"] = { line = 4, character = 3 },
			},
			children = {
				{
					name = "run",
					kind = 12,
					range = {
						start = { line = 1, character = 1 },
						["end"] = { line = 3, character = 2 },
					},
				},
			},
		},
		{
			name = "from-location",
			kind = 13,
			location = {
				range = {
					start = { line = 7, character = 0 },
					["end"] = { line = 7, character = 9 },
				},
			},
		},
	})

	eq(#flattened, 3)
	eq(flattened[1].name, "Example")
	eq(flattened[2].depth, 1)
	eq(symbols.kind_name(flattened[1].kind), "Class")
	local line1, line2 = symbols.range_lines(flattened[3])
	eq(line1, 8)
	eq(line2, 8)

	local lines, line_symbols = symbols.picker_lines(flattened)
	local text = table.concat(lines, "\n")
	ok(text:find("Example  Class lines 1-5", 1, true))
	ok(text:find("class detail", 1, true))
	ok(text:find("  run  Function lines 2-4", 1, true))
	ok(text:find("from-location  Variable lines 8-8", 1, true))
	eq(line_symbols[3].name, "Example")
	eq(line_symbols[5].name, "run")
end)

test("config option picker lines render selectable options", function()
	local lines, line_options = acp_config.picker_lines({
		{
			id = "mode",
			name = "Session Mode",
			description = "Controls permissions",
			category = "mode",
			type = "select",
			currentValue = "ask",
			options = {
				{ value = "ask", name = "Ask", description = "Request permission" },
				{ value = "code", name = "Code" },
			},
		},
		{
			id = "ignored",
			name = "Ignored",
			type = "text",
			currentValue = "no",
			options = {
				{ value = "no", name = "No" },
			},
		},
	})
	local text = table.concat(lines, "\n")

	ok(text:find("Session Mode: Ask [mode]", 1, true))
	ok(text:find("Controls permissions", 1, true))
	ok(not text:find("Ignored", 1, true))
	eq(line_options[3].id, "mode")

	local value_lines, line_values = acp_config.value_lines(line_options[3])
	local value_text = table.concat(value_lines, "\n")
	ok(value_text:find("1. Ask *", 1, true))
	ok(value_text:find("Request permission", 1, true))
	ok(value_text:find("2. Code", 1, true))
	eq(line_values[3].value, "ask")
	eq(line_values[5].value, "code")
end)

test("slash command picker lines and draft text are rendered", function()
	local lines, line_commands = acp_commands.picker_lines({
		{
			name = "plan",
			description = "Create a plan",
			input = {
				hint = "task",
			},
		},
		{
			name = "test",
			description = "Run tests",
		},
	})
	local text = table.concat(lines, "\n")

	ok(text:find("/plan", 1, true))
	ok(text:find("Create a plan", 1, true))
	ok(text:find("input: task", 1, true))
	ok(text:find("/test", 1, true))
	eq(acp_commands.slash_text(line_commands[3]), "/plan ")
	eq(acp_commands.slash_text(line_commands[6]), "/test")
end)

test("slash command completion items are rendered for completefunc", function()
	local commands = {
		{
			name = "plan",
			description = "Create a plan",
			input = {
				hint = "task",
			},
		},
		{
			name = "test",
			description = "Run tests",
		},
	}

	eq(acp_commands.completion_start("/pl", 3), 0)
	eq(acp_commands.completion_start("ask /pl", 7), -3)

	local plan_items = acp_commands.completion_items(commands, "/p")
	eq(#plan_items, 1)
	eq(plan_items[1].word, "/plan ")
	eq(plan_items[1].abbr, "/plan")
	eq(plan_items[1].menu, "task")
	eq(plan_items[1].info, "Create a plan")

	local all_items = acp_commands.completion_items(commands, "/")
	eq(#all_items, 2)
	eq(all_items[2].word, "/test")
	eq(all_items[2].menu, "ACP")
end)

test("available commands updates are forwarded to active handlers", function()
	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 10 },
		cwd = vim.fn.getcwd(),
	})
	local received
	connection.active_handlers = {
		available_commands = function(commands)
			received = commands
		end,
	}

	connection:handle_session_update({
		sessionUpdate = "available_commands_update",
		availableCommands = {
			{ name = "plan", description = "Create a plan" },
		},
	})

	eq(received[1].name, "plan")
end)

test("config option updates are forwarded to active handlers", function()
	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 10 },
		cwd = vim.fn.getcwd(),
	})
	local received
	connection.active_handlers = {
		config_options = function(options)
			received = options
		end,
	}

	connection:handle_session_update({
		sessionUpdate = "config_option_update",
		configOptions = {
			{
				id = "mode",
				name = "Session Mode",
				type = "select",
				currentValue = "ask",
				options = {
					{ value = "ask", name = "Ask" },
				},
			},
		},
	})

	eq(received[1].id, "mode")
	eq(connection.config_options[1].id, "mode")
end)

test("prompt history recalls sent prompts and restores draft", function()
	local input_buf
	local original_notify = vim.notify
	vim.notify = function() end

	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[input_buf].completefunc, "v:lua.acp_nvim_completefunc")
		local prompt_ns = vim.api.nvim_create_namespace("acp.nvim.prompt")
		local marks = vim.api.nvim_buf_get_extmarks(input_buf, prompt_ns, 0, -1, { details = true })
		local ghost = false
		for _, mark in ipairs(marks) do
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("Ask ACP", 1, true) then
					ghost = true
				end
			end
		end
		ok(ghost, "empty prompt should show ghost text")

		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "draft prompt" })
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = input_buf })
		marks = vim.api.nvim_buf_get_extmarks(input_buf, prompt_ns, 0, -1, { details = true })
		local stats = false
		for _, mark in ipairs(marks) do
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("2 words", 1, true) then
					stats = true
				end
			end
		end
		ok(stats, "non-empty prompt should show draft stats")

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

test("output buffer shows dashboard, chrome, and section navigation", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(source_buf, vim.fn.tempname() .. ".lua")
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local value = 1",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)

	local input_buf
	local output_buf
	local output_win
	local location_buf
	local unnamed_register
	local unnamed_register_type
	local original_notify = vim.notify
	vim.notify = function() end
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		local input_name = vim.api.nvim_buf_get_name(input_buf)
		local output_name = input_name:gsub("/input$", "/output")
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_get_name(bufnr) == output_name then
				output_buf = bufnr
				break
			end
		end
		ok(output_buf, "output buffer should exist")
		output_win = vim.fn.bufwinid(output_buf)
		ok(output_win and output_win > 0, "output window should be visible")

		local dashboard = table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, 7, false), "\n")
		ok(dashboard:find("ACP: test", 1, true))
		ok(dashboard:find("Session: #", 1, true))
		ok(dashboard:find("Model: test-model | Context: 1k", 1, true))
		ok(dashboard:find("Source:", 1, true))
		ok(dashboard:find("Transcript: 0 sections | 0 code | 0 locs | 0 changes", 1, true))
		ok(dashboard:find("[[/]] sections", 1, true))
		ok(dashboard:find("<leader>ax search", 1, true))
		ok(vim.wo[output_win].winbar:find("ACP test #", 1, true))
		eq(vim.wo[output_win].foldmethod, "expr")
		ok(vim.wo[output_win].foldexpr:find("acp_nvim_output_foldexpr", 1, true))
		ok(vim.wo[output_win].foldtext:find("acp_nvim_output_foldtext", 1, true))
		eq(vim.wo[output_win].foldlevel, 99)
		eq(vim.wo[output_win].foldcolumn, "1")
		eq(vim.wo[output_win].signcolumn, "yes:1")
		ok(
			vim.b[output_buf].acp_language_injection == "treesitter-markdown"
				or vim.b[output_buf].acp_language_injection == "fence-detection"
		)

		local function has_virt_line(mark, text)
			for _, virt_line in ipairs((mark[4] and mark[4].virt_lines) or {}) do
				for _, chunk in ipairs(virt_line) do
					if chunk[1] and chunk[1]:find(text, 1, true) then
						return true
					end
				end
			end
			return false
		end

		local function output_inspector_text(filetype)
			for _, winid in ipairs(vim.api.nvim_list_wins()) do
				local preview_bufnr = vim.api.nvim_win_get_buf(winid)
				if
					preview_bufnr ~= output_buf
					and vim.b[preview_bufnr].acp_output_inspector == output_buf
					and (not filetype or vim.bo[preview_bufnr].filetype == filetype)
				then
					return winid, table.concat(vim.api.nvim_buf_get_lines(preview_bufnr, 0, -1, false), "\n")
				end
			end
			return nil, nil
		end

		local ns = vim.api.nvim_create_namespace("acp.nvim.output")
		local marks = vim.api.nvim_buf_get_extmarks(output_buf, ns, 0, -1, { details = true })
		local highlighted_header = false
		local ghost_text = false
		local session_sign = false
		for _, mark in ipairs(marks) do
			if mark[4] and mark[4].line_hl_group == "AcpOutputHeader" then
				highlighted_header = true
			end
			if mark[4] and mark[4].sign_text == "S>" then
				session_sign = true
			end
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("Ready", 1, true) then
					ghost_text = true
				end
			end
		end
		ok(highlighted_header, "output header should be highlighted")
		ok(session_sign, "output session sign should be rendered")
		ok(ghost_text, "output ghost text should be rendered")

		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "hello output" })
		vim.cmd("AcpSend")
		local lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
		local text = table.concat(lines, "\n")
		ok(text:find("You", 1, true))
		ok(text:find("Agent", 1, true))
		ok(text:find("Status: error: failed to start session", 1, true))
		marks = vim.api.nvim_buf_get_extmarks(output_buf, ns, 0, -1, { details = true })
		local user_sign = false
		local agent_sign = false
		local error_sign = false
		local user_separator = false
		local agent_separator = false
		local user_summary = false
		for _, mark in ipairs(marks) do
			user_sign = user_sign or (mark[4] and mark[4].sign_text == "U>")
			agent_sign = agent_sign or (mark[4] and mark[4].sign_text == "A>")
			error_sign = error_sign or (mark[4] and mark[4].sign_text == "E!")
			user_separator = user_separator or has_virt_line(mark, "---- USER: Prompt ----")
			agent_separator = agent_separator or has_virt_line(mark, "---- AGENT: Response ----")
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("1L | 2w", 1, true) then
					user_summary = true
				end
			end
		end
		ok(user_sign, "output user sign should be rendered")
		ok(agent_sign, "output agent sign should be rendered")
		ok(error_sign, "output error sign should be rendered")
		ok(user_separator, "output user separator should be rendered")
		ok(agent_separator, "output agent separator should be rendered")
		ok(user_summary, "output section summary should be rendered")
		local updated_dashboard = table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, 7, false), "\n")
		ok(updated_dashboard:find("Transcript: 3 sections | 0 code | 0 locs | 0 changes", 1, true))
		local output_diagnostic_ns = vim.api.nvim_create_namespace("acp.nvim.output.diagnostics")
		local output_diagnostics = vim.diagnostic.get(output_buf, { namespace = output_diagnostic_ns })
		eq(#output_diagnostics, 1)
		eq(output_diagnostics[1].severity, vim.diagnostic.severity.ERROR)
		ok(output_diagnostics[1].message:find("failed to start session", 1, true))
		local problem_line
		for index, output_line in ipairs(lines) do
			if output_line:find("Status: error", 1, true) then
				problem_line = index
				break
			end
		end
		ok(problem_line, "output should contain a problem line")
		vim.api.nvim_set_current_win(output_win)
		vim.api.nvim_win_set_cursor(output_win, { problem_line, 0 })
		vim.cmd("AcpOutputInspect")
		local problem_preview_win, problem_preview = output_inspector_text("acp")
		ok(problem_preview and problem_preview:find("failed to start session", 1, true), "output inspector should preview problems")
		pcall(vim.api.nvim_win_close, problem_preview_win, true)
		vim.api.nvim_set_current_win(output_win)
		vim.cmd("AcpOutputProblems")
		local loclist = vim.fn.getloclist(output_win, { title = 1, items = 1 })
		ok(loclist.title:find("ACP output problems", 1, true))
		eq(#loclist.items, 1)
		ok(loclist.items[1].text:find("failed to start session", 1, true))
		vim.cmd("lclose")

		vim.api.nvim_set_current_win(output_win)
		vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
		local keys = vim.api.nvim_replace_termcodes("]]", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local line = vim.api.nvim_win_get_cursor(output_win)[1]
		eq(vim.api.nvim_buf_get_lines(output_buf, line - 1, line, false)[1], "You")
		ok(vim.wo[output_win].winbar:find("at USER: Prompt", 1, true))
		local current_ns = vim.api.nvim_create_namespace("acp.nvim.output.current_section")
		local current_marks = vim.api.nvim_buf_get_extmarks(output_buf, current_ns, 0, -1, { details = true })
		local current_section_highlight = false
		for _, mark in ipairs(current_marks) do
			if mark[2] == line - 1 and mark[4] and mark[4].line_hl_group == "AcpCurrentSection" then
				current_section_highlight = true
				break
			end
		end
		ok(current_section_highlight, "current output section should be highlighted")
		local hint_ns = vim.api.nvim_create_namespace("acp.nvim.output.hints")
		local hint_marks = vim.api.nvim_buf_get_extmarks(output_buf, hint_ns, 0, -1, { details = true })
		local section_hint = false
		for _, mark in ipairs(hint_marks) do
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("<leader>ai draft", 1, true) then
					section_hint = true
					break
				end
			end
		end
		ok(section_hint, "output cursor should show section action hints")

		vim.cmd("AcpOutputDraft")
		local draft = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(draft:find("Use this ACP output section as context for a follow-up.", 1, true))
		ok(draft:find("ACP output section (USER: Prompt):", 1, true))
		ok(draft:find("hello output", 1, true))
		ok(draft:find("Request:", 1, true))
		eq(vim.api.nvim_get_current_buf(), input_buf)
		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
		vim.api.nvim_set_current_win(output_win)

		unnamed_register = vim.fn.getreg('"')
		unnamed_register_type = vim.fn.getregtype('"')
		vim.cmd("AcpOutputYank")
		local yanked = vim.fn.getreg('"')
		ok(yanked:find("You", 1, true))
		ok(yanked:find("hello output", 1, true))
		ok(not yanked:find("Agent", 1, true), "yank should stay inside the current section")
		local pulse_ns = vim.api.nvim_create_namespace("acp.nvim.output.pulse")
		local pulse_marks = vim.api.nvim_buf_get_extmarks(output_buf, pulse_ns, 0, -1, { details = true })
		ok(#pulse_marks > 0, "yanking should pulse the output section")
		vim.fn.setreg('"', unnamed_register, unnamed_register_type)
		unnamed_register = nil
		unnamed_register_type = nil

		vim.cmd("AcpOutputSearch")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-output-search")
		local search_lines = vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false)
		local search_row
		for index, search_line in ipairs(search_lines) do
			if search_line:find("hello output", 1, true) then
				search_row = index
				break
			end
		end
		ok(search_row, "output search should include transcript text")
		vim.api.nvim_win_set_cursor(0, { search_row, 0 })
		vim.cmd("doautocmd CursorMoved")
		local search_preview = false
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			local preview_bufnr = vim.api.nvim_win_get_buf(winid)
			if preview_bufnr ~= picker_buf and vim.bo[preview_bufnr].buftype == "nofile" and vim.bo[preview_bufnr].filetype == "acp" then
				local preview = table.concat(vim.api.nvim_buf_get_lines(preview_bufnr, 0, -1, false), "\n")
				if preview:find("hello output", 1, true) then
					search_preview = true
					break
				end
			end
		end
		ok(search_preview, "output search should show context preview")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_win(), output_win)
		eq(vim.api.nvim_buf_get_lines(output_buf, vim.api.nvim_win_get_cursor(output_win)[1] - 1, vim.api.nvim_win_get_cursor(output_win)[1], false)[1], "hello output")

		vim.cmd("AcpOutput")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-output")
		local outline = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
		ok(outline:find("ACP Output Outline", 1, true))
		ok(outline:find("USER", 1, true))
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_win(), output_win)
		eq(vim.api.nvim_win_get_cursor(output_win)[1], 1)

		vim.bo[output_buf].modifiable = true
		vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, {
			"",
			"Agent",
			"```lua",
			"print('from acp')",
			"```",
		})
		vim.bo[output_buf].modifiable = false
		vim.api.nvim_set_current_win(output_win)
		local code_line
		for index, output_line in ipairs(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)) do
			if output_line:find("print('from acp')", 1, true) then
				code_line = index
				break
			end
		end
		ok(code_line, "output should contain a code block")
		vim.api.nvim_win_set_cursor(output_win, { code_line, 0 })
		vim.cmd("AcpOutputInspect")
		local code_preview_win, code_preview = output_inspector_text("lua")
		ok(code_preview and code_preview:find("print('from acp')", 1, true), "output inspector should preview code blocks")
		pcall(vim.api.nvim_win_close, code_preview_win, true)
		unnamed_register = vim.fn.getreg('"')
		unnamed_register_type = vim.fn.getregtype('"')
		vim.cmd("AcpCodeBlockYank")
		eq(vim.fn.getreg('"'), "print('from acp')\n")
		eq(vim.fn.getregtype('"'), "V")
		local code_pulse_ns = vim.api.nvim_create_namespace("acp.nvim.output.pulse")
		local code_pulse_marks = vim.api.nvim_buf_get_extmarks(output_buf, code_pulse_ns, 0, -1, { details = true })
		ok(#code_pulse_marks > 0, "yanking code should pulse the output code block")
		vim.fn.setreg('"', unnamed_register, unnamed_register_type)
		unnamed_register = nil
		unnamed_register_type = nil

		vim.cmd("AcpOutputOpen")
		local direct_code_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[direct_code_buf].filetype, "lua")
		eq(table.concat(vim.api.nvim_buf_get_lines(direct_code_buf, 0, -1, false), "\n"), "print('from acp')")
		pcall(vim.cmd, "tabclose!")
		vim.api.nvim_set_current_win(output_win)
		vim.cmd("AcpCodeBlocks")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-code-blocks")
		local block_picker = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
		ok(block_picker:find("ACP Output Code Blocks", 1, true))
		ok(block_picker:find("lua", 1, true))
		local preview_found = false
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			local preview_bufnr = vim.api.nvim_win_get_buf(winid)
			if preview_bufnr ~= picker_buf and vim.bo[preview_bufnr].buftype == "nofile" and vim.bo[preview_bufnr].filetype == "lua" then
				local preview = table.concat(vim.api.nvim_buf_get_lines(preview_bufnr, 0, -1, false), "\n")
				if preview:find("print('from acp')", 1, true) then
					preview_found = true
					break
				end
			end
		end
		ok(preview_found, "code block picker should show language preview")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local code_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[code_buf].filetype, "lua")
		eq(table.concat(vim.api.nvim_buf_get_lines(code_buf, 0, -1, false), "\n"), "print('from acp')")
		pcall(vim.cmd, "tabclose!")

		vim.bo[output_buf].modifiable = true
		vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, {
			"",
			"See lua/acp/output.lua:1:1 for the output helpers.",
		})
		vim.bo[output_buf].modifiable = false
		vim.api.nvim_set_current_win(output_win)
		local ref_line
		local ref_col
		for index, output_line in ipairs(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)) do
			local first = output_line:find("lua/acp/output.lua", 1, true)
			if first then
				ref_line = index
				ref_col = first - 1
				break
			end
		end
		ok(ref_line, "output should contain a file reference")
		vim.api.nvim_win_set_cursor(output_win, { ref_line, ref_col })
		vim.cmd("AcpOutputInspect")
		local ref_preview_win, ref_preview = output_inspector_text("lua")
		ok(ref_preview and ref_preview:find("local M = {}", 1, true), "output inspector should preview file references")
		pcall(vim.api.nvim_win_close, ref_preview_win, true)
		vim.cmd("AcpOutputOpen")
		location_buf = vim.api.nvim_get_current_buf()
		ok(vim.api.nvim_buf_get_name(location_buf):find("lua/acp/output.lua", 1, true))
		eq(vim.api.nvim_win_get_cursor(0)[1], 1)
		ok(vim.api.nvim_buf_is_valid(output_buf), "output buffer should survive direct reference navigation")
		vim.api.nvim_set_current_win(output_win)
		eq(vim.api.nvim_win_get_buf(output_win), output_buf)
		vim.cmd("AcpOutputQuickfix")
		local qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qflist.title:find("ACP output locations", 1, true))
		eq(#qflist.items, 1)
		eq(qflist.items[1].lnum, 1)
		eq(qflist.items[1].col, 1)
		ok(qflist.items[1].text:find("lua/acp/output.lua:1:1", 1, true))
		vim.cmd("cclose")
		vim.api.nvim_set_current_win(output_win)
		vim.cmd("AcpOutputLocations")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-output-locations")
		local locations = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
		ok(locations:find("ACP Output Locations", 1, true))
		ok(locations:find("lua/acp/output.lua:1:1", 1, true))
		local location_preview = false
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			local preview_bufnr = vim.api.nvim_win_get_buf(winid)
			if preview_bufnr ~= picker_buf and vim.bo[preview_bufnr].buftype == "nofile" and vim.bo[preview_bufnr].filetype == "lua" then
				local preview = table.concat(vim.api.nvim_buf_get_lines(preview_bufnr, 0, -1, false), "\n")
				if preview:find("local M = {}", 1, true) then
					location_preview = true
					break
				end
			end
		end
		ok(location_preview, "output location picker should show source preview")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		location_buf = vim.api.nvim_get_current_buf()
		ok(vim.api.nvim_buf_get_name(location_buf):find("lua/acp/output.lua", 1, true))
		eq(vim.api.nvim_win_get_cursor(0)[1], 1)
	end)

	if unnamed_register ~= nil then
		vim.fn.setreg('"', unnamed_register, unnamed_register_type)
	end
	vim.notify = original_notify
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if location_buf and vim.api.nvim_buf_is_valid(location_buf) then
		pcall(vim.api.nvim_buf_delete, location_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
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
	local session_name = vim.api.nvim_buf_get_name(input_buf):gsub("/input$", "/sessions")
	local session_buf
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(bufnr) == session_name then
			session_buf = bufnr
			break
		end
	end
	ok(session_buf, "session panel buffer should exist")
	local ns = vim.api.nvim_create_namespace("acp.nvim.sessions")
	local marks = vim.api.nvim_buf_get_extmarks(session_buf, ns, 0, -1, { details = true })
	local current_line = false
	local idle_badge = false
	for _, mark in ipairs(marks) do
		if mark[4] and mark[4].line_hl_group == "AcpSessionCurrent" then
			current_line = true
		end
		for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
			if chunk[1] and chunk[1]:find("IDLE", 1, true) then
				idle_badge = true
			end
		end
	end
	ok(current_line, "session panel should highlight the current session")
	ok(idle_badge, "session panel should render a status badge")

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

test("actions command opens a session action palette", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_set_current_buf(source_buf)

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpActions")
		local action_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[action_buf].filetype, "acp-actions")
		local action_lines = vim.api.nvim_buf_get_lines(action_buf, 0, -1, false)
		local output_outline_row
		local inspect_output = false
		local yank_code_block = false
		for index, line in ipairs(action_lines) do
			if line:find("Output outline", 1, true) then
				output_outline_row = index
			end
			if line:find("Inspect output item", 1, true) then
				inspect_output = true
			end
			if line:find("Yank code block", 1, true) then
				yank_code_block = true
			end
		end
		ok(output_outline_row, "action palette should include output outline")
		ok(inspect_output, "action palette should include output inspect")
		ok(yank_code_block, "action palette should include code block yank")

		vim.api.nvim_win_set_cursor(0, { output_outline_row, 0 })
		local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.bo[vim.api.nvim_get_current_buf()].filetype, "acp-output")
		local outline = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
		ok(outline:find("ACP Output Outline", 1, true))
		pcall(vim.api.nvim_buf_delete, vim.api.nvim_get_current_buf(), { force = true })
	end)

	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("chat marks captured source ranges and clears them on close", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local value = 1",
		"local other = 2",
		"print(value + other)",
	})
	vim.api.nvim_set_current_buf(source_buf)

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("1,2AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()

		local ns = vim.api.nvim_create_namespace("acp.nvim.source")
		local marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		eq(#marks, 2)
		local label_found = false
		for _, mark in ipairs(marks) do
			eq(mark[4].line_hl_group, "AcpSourceContext")
			for _, chunk in ipairs(mark[4].virt_text or {}) do
				if chunk[1] and chunk[1]:find("ACP #", 1, true) then
					label_found = true
				end
			end
		end
		ok(label_found, "source range should include an ACP context label")

		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
		input_buf = nil
		marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		eq(#marks, 0)
	end)

	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("diagnostics command drafts selected diagnostic context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local value = missing",
		"print(value)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)

	local ns = vim.api.nvim_create_namespace("acp.nvim.test.diagnostic-picker")
	vim.diagnostic.set(ns, source_buf, {
		{
			lnum = 0,
			col = 14,
			end_lnum = 0,
			end_col = 21,
			severity = vim.diagnostic.severity.ERROR,
			message = "undefined global missing",
			source = "lua_ls",
			code = "undefined-global",
		},
	})

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpDiagnostics")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-diagnostics")
		local preview_found = false
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			local bufnr = vim.api.nvim_win_get_buf(winid)
			if bufnr ~= picker_buf and vim.bo[bufnr].buftype == "nofile" and vim.bo[bufnr].filetype == "lua" then
				local preview = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
				if preview:find("local value = missing", 1, true) then
					preview_found = true
					break
				end
			end
		end
		ok(preview_found, "diagnostics picker should show a source preview")

		local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Fix this diagnostic. Keep the change focused", 1, true))
		ok(prompt:find("Selection: lines 1-1", 1, true))
		ok(prompt:find("ERROR [lua_ls] (undefined-global): undefined global missing", 1, true))
		ok(prompt:find("local value = missing", 1, true))
	end)

	vim.diagnostic.reset(ns, source_buf)
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("symbols command drafts selected LSP symbol context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local function add(a, b)",
		"  return a + b",
		"end",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)

	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/documentSymbol")
		ok(params.textDocument.uri:find("file://", 1, true), "symbol request should include buffer uri")
		callback({
			[1] = {
				result = {
					{
						name = "add",
						kind = 12,
						range = {
							start = { line = 0, character = 0 },
							["end"] = { line = 2, character = 3 },
						},
					},
				},
			},
		})
		return {
			[1] = 1,
		}
	end

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpSymbols")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-symbols")

		local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP symbol as context: add (Function).", 1, true))
		ok(prompt:find("Selection: lines 1-3", 1, true))
		ok(prompt:find("local function add", 1, true))
	end)

	vim.lsp.buf_request_all = original_buf_request_all
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("code actions command drafts selected LSP action context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local value = missing",
		"print(value)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)

	local ns = vim.api.nvim_create_namespace("acp.nvim.test.code-actions")
	vim.diagnostic.set(ns, source_buf, {
		{
			lnum = 0,
			col = 14,
			end_lnum = 0,
			end_col = 21,
			severity = vim.diagnostic.severity.ERROR,
			message = "undefined global missing",
			source = "lua_ls",
		},
	})

	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/codeAction")
		eq(params.range.start.line, 0)
		eq(params.range["end"].line, 0)
		eq(#params.context.diagnostics, 1)
		eq(params.context.diagnostics[1].message, "undefined global missing")
		callback({
			[1] = {
				result = {
					{
						title = "Declare local missing",
						kind = "quickfix",
						isPreferred = true,
						edit = {},
						diagnostics = {
							{ message = "undefined global missing" },
						},
					},
				},
			},
		})
		return {
			[1] = 1,
		}
	end

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpCodeActions")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-code-actions")

		local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP code action as guidance: Declare local missing.", 1, true))
		ok(prompt:find("Kind: quickfix", 1, true))
		ok(prompt:find("Preferred: yes", 1, true))
		ok(prompt:find("Workspace edit: provided by LSP", 1, true))
		ok(prompt:find("ERROR: undefined global missing", 1, true))
	end)

	vim.lsp.buf_request_all = original_buf_request_all
	vim.diagnostic.reset(ns, source_buf)
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("hover command drafts LSP hover context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local value = missing",
		"print(value)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 6 })

	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/hover")
		eq(params.position.line, 0)
		eq(params.position.character, 6)
		callback({
			[1] = {
				result = {
					contents = {
						kind = "markdown",
						value = "`value`: any",
					},
				},
			},
		})
		return {
			[1] = 1,
		}
	end

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpHover")
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP hover documentation as context.", 1, true))
		ok(prompt:find("Hover:", 1, true))
		ok(prompt:find("`value`: any", 1, true))
		ok(prompt:find("Context", 1, true))
		ok(prompt:find("Line: local value = missing", 1, true))
	end)

	vim.lsp.buf_request_all = original_buf_request_all
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("references command drafts selected LSP reference context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	local path = vim.fn.tempname() .. ".lua"
	vim.api.nvim_buf_set_name(source_buf, path)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local value = 1",
		"print(value)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 6 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/references")
		eq(params.position.line, 0)
		eq(params.position.character, 6)
		eq(params.context.includeDeclaration, true)
		callback({
			[1] = {
				result = {
					{
						uri = uri,
						range = {
							start = { line = 1, character = 6 },
							["end"] = { line = 1, character = 11 },
						},
					},
				},
			},
		})
		return {
			[1] = 1,
		}
	end

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpReferences")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-references")

		local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP reference as context.", 1, true))
		ok(prompt:find("Reference:", 1, true))
		ok(prompt:find("Selection: lines 2-2", 1, true))
		ok(prompt:find("print%(value%)"))
	end)

	vim.lsp.buf_request_all = original_buf_request_all
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("tree-sitter command drafts selected node context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local function add(a, b)",
		"  return a + b",
		"end",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })

	local node = {}
	function node:type()
		return "function_declaration"
	end
	function node:range()
		return 0, 0, 2, 3
	end
	local original_treesitter = vim.treesitter
	local original_get_node = original_treesitter and original_treesitter.get_node
	local original_get_node_text = original_treesitter and original_treesitter.get_node_text
	vim.treesitter = vim.treesitter or {}
	vim.treesitter.get_node = function()
		return node
	end
	vim.treesitter.get_node_text = function()
		return "local function add(a, b)\n  return a + b\nend"
	end

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpTreeSitter")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-treesitter")

		local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this Tree-sitter node as context: function_declaration.", 1, true))
		ok(prompt:find("Selection: lines 1-3", 1, true))
		ok(prompt:find("Tree-sitter text:", 1, true))
		ok(prompt:find("local function add", 1, true))
	end)

	if original_treesitter then
		vim.treesitter.get_node = original_get_node
		vim.treesitter.get_node_text = original_get_node_text
	else
		vim.treesitter = nil
	end
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
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

	local preview_found = false
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		local preview_bufnr = vim.api.nvim_win_get_buf(winid)
		if preview_bufnr ~= bufnr and vim.bo[preview_bufnr].buftype == "nofile" and vim.bo[preview_bufnr].filetype == "acp" then
			local preview = table.concat(vim.api.nvim_buf_get_lines(preview_bufnr, 0, -1, false), "\n")
			if preview:find("History Browser Test", 1, true) then
				preview_found = true
				break
			end
		end
	end
	ok(preview_found, "history browser should show transcript preview")

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
	local config_options
	ok(connection:prompt_async("hello", {
		started = function()
			started = true
		end,
		config_options = function(options)
			config_options = options
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
	eq(writes[1].params.clientCapabilities.terminal, true)
	eq(started, false)

	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = writes[2].id,
		result = {
			sessionId = "session-1",
			configOptions = {
				{
					id = "mode",
					name = "Session Mode",
					type = "select",
					currentValue = "ask",
					options = {
						{ value = "ask", name = "Ask" },
					},
				},
			},
		},
	}))

	eq(#writes, 3)
	eq(writes[3].method, "session/prompt")
	eq(writes[3].params.sessionId, "session-1")
	eq(config_options[1].id, "mode")
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

test("set config option sends request and applies returned options", function()
	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 1000 },
		cwd = vim.fn.getcwd(),
	})
	connection.session_id = "session-1"

	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	local received
	connection.active_handlers = {
		config_options = function(options)
			received = options
		end,
	}
	local callback_ok
	local callback_result
	ok(connection:set_config_option_async("mode", "code", function(success, result)
		callback_ok = success
		callback_result = result
	end))

	eq(writes[1].method, "session/set_config_option")
	eq(writes[1].params.sessionId, "session-1")
	eq(writes[1].params.configId, "mode")
	eq(writes[1].params.value, "code")

	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = writes[1].id,
		result = {
			configOptions = {
				{
					id = "mode",
					name = "Session Mode",
					type = "select",
					currentValue = "code",
					options = {
						{ value = "ask", name = "Ask" },
						{ value = "code", name = "Code" },
					},
				},
			},
		},
	}))

	eq(callback_ok, true)
	eq(callback_result.configOptions[1].currentValue, "code")
	eq(connection.config_options[1].currentValue, "code")
	eq(received[1].currentValue, "code")
end)

test("adapter session list paginates when supported", function()
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

	local listed
	local list_err
	ok(connection:list_sessions_async(function(sessions, err)
		listed = sessions
		list_err = err
	end))

	eq(writes[1].method, "initialize")
	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = writes[1].id,
		result = {
			agentCapabilities = {
				sessionCapabilities = {
					list = {},
				},
			},
			authMethods = {},
		},
	}))

	eq(writes[2].method, "session/list")
	eq(writes[2].params.cwd, vim.fn.getcwd())
	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = writes[2].id,
		result = {
			sessions = {
				{ sessionId = "session-1", cwd = vim.fn.getcwd(), title = "One" },
			},
			nextCursor = "cursor-2",
		},
	}))

	eq(writes[3].method, "session/list")
	eq(writes[3].params.cursor, "cursor-2")
	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = writes[3].id,
		result = {
			sessions = {
				{ sessionId = "session-2", cwd = vim.fn.getcwd(), title = "Two" },
			},
		},
	}))

	eq(list_err, nil)
	eq(#listed, 2)
	eq(listed[1].sessionId, "session-1")
	eq(listed[2].sessionId, "session-2")
end)

test("adapter session load replays user and agent chunks", function()
	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 1000 },
		cwd = vim.fn.getcwd(),
	})
	connection.initialized = true
	connection.authenticated = true
	connection.agent_info = {
		agentCapabilities = {
			loadSession = true,
			sessionCapabilities = {
				additionalDirectories = {},
			},
		},
	}

	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	local replay = {}
	local restored
	local restore_mode
	ok(connection:restore_session_async({
		sessionId = "session-load",
		additionalDirectories = { "/tmp/acp-extra" },
	}, {
		user_message_chunk = function(text)
			table.insert(replay, "user:" .. text)
		end,
		message_chunk = function(text)
			table.insert(replay, "agent:" .. text)
		end,
	}, function(success, mode)
		restored = success
		restore_mode = mode
	end))

	eq(writes[1].method, "session/load")
	eq(writes[1].params.sessionId, "session-load")
	eq(writes[1].params.additionalDirectories[1], "/tmp/acp-extra")

	connection:handle_request({
		method = "session/update",
		params = {
			sessionId = "session-load",
			update = {
				sessionUpdate = "user_message_chunk",
				content = {
					type = "text",
					text = "restore question",
				},
			},
		},
	})
	connection:handle_request({
		method = "session/update",
		params = {
			sessionId = "session-load",
			update = {
				sessionUpdate = "agent_message_chunk",
				content = {
					type = "text",
					text = "restore answer",
				},
			},
		},
	})
	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = writes[1].id,
		result = vim.NIL,
	}))

	eq(restored, true)
	eq(restore_mode, "load")
	eq(connection.session_id, "session-load")
	eq(replay, {
		"user:restore question",
		"agent:restore answer",
	})
end)

test("adapter session restore falls back to resume", function()
	local connection = Connection.new({
		adapter = { command = { "missing-acp-test-command" }, timeout_ms = 1000 },
		cwd = vim.fn.getcwd(),
	})
	connection.initialized = true
	connection.authenticated = true
	connection.agent_info = {
		agentCapabilities = {
			sessionCapabilities = {
				resume = {},
			},
		},
	}

	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	local restored
	local restore_mode
	ok(connection:restore_session_async({
		sessionId = "session-resume",
	}, {}, function(success, mode)
		restored = success
		restore_mode = mode
	end))

	eq(writes[1].method, "session/resume")
	eq(writes[1].params.sessionId, "session-resume")
	connection:handle_line(vim.json.encode({
		jsonrpc = "2.0",
		id = writes[1].id,
		result = {},
	}))

	eq(restored, true)
	eq(restore_mode, "resume")
	eq(connection.session_id, "session-resume")
end)

test("terminal requests capture bounded output and wait for exit", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")

	local connection = Connection.new({
		adapter = {
			command = { "missing-acp-test-command" },
			timeout_ms = 10,
			terminal_auto_approve = true,
		},
		cwd = root,
	})
	connection.session_id = "session-1"

	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	connection:handle_request({
		id = 51,
		method = "terminal/create",
		params = {
			sessionId = "session-1",
			command = "sh",
			args = { "-c", "printf 1234567890" },
			cwd = root,
			outputByteLimit = 4,
		},
	})

	local terminal_id = writes[1].result.terminalId
	ok(terminal_id, "terminal create should return an id")

	connection:handle_request({
		id = 52,
		method = "terminal/wait_for_exit",
		params = {
			sessionId = "session-1",
			terminalId = terminal_id,
		},
	})

	ok(vim.wait(500, function()
		return #writes >= 2
	end, 5), "terminal wait should respond after command exits")
	eq(writes[2].id, 52)
	eq(writes[2].result.exitCode, 0)

	ok(vim.wait(500, function()
		local output = connection.terminals:output(terminal_id)
		return output and output.output == "7890"
	end, 5), "terminal output should be captured and bounded")

	connection:handle_request({
		id = 53,
		method = "terminal/output",
		params = {
			sessionId = "session-1",
			terminalId = terminal_id,
		},
	})
	eq(writes[3].result.output, "7890")
	eq(writes[3].result.truncated, true)
	eq(writes[3].result.exitStatus.exitCode, 0)

	connection:handle_request({
		id = 54,
		method = "terminal/release",
		params = {
			sessionId = "session-1",
			terminalId = terminal_id,
		},
	})
	eq(writes[4].id, 54)
	eq(writes[4].result, vim.NIL)

	connection:handle_request({
		id = 55,
		method = "terminal/output",
		params = {
			sessionId = "session-1",
			terminalId = terminal_id,
		},
	})
	eq(writes[5].error.code, jsonrpc.errors.invalid_params)

	vim.fn.delete(root, "rf")
end)

test("embedded terminals stream output to active handlers", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")

	local connection = Connection.new({
		adapter = {
			command = { "missing-acp-test-command" },
			timeout_ms = 10,
			terminal_auto_approve = true,
		},
		cwd = root,
	})
	connection.session_id = "session-1"

	local writes = {}
	function connection:write(message)
		table.insert(writes, message)
		return true
	end

	local chunks = {}
	local attached
	connection.active_handlers = {
		terminal_attach = function(event)
			attached = event.terminal_id
		end,
		terminal_output = function(event)
			table.insert(chunks, event.text)
		end,
	}

	connection:handle_request({
		id = 61,
		method = "terminal/create",
		params = {
			sessionId = "session-1",
			command = "sh",
			args = { "-c", "sleep 0.05; printf hello" },
			cwd = root,
		},
	})

	local terminal_id = writes[1].result.terminalId
	connection:handle_session_update({
		sessionUpdate = "tool_call",
		toolCallId = "tool-1",
		title = "Run command",
		content = {
			{
				type = "terminal",
				terminalId = terminal_id,
			},
		},
	})

	eq(attached, terminal_id)
	ok(vim.wait(500, function()
		return table.concat(chunks):find("hello", 1, true) ~= nil
	end, 5), "embedded terminal output should stream to handlers")

	connection.terminals:release_all()
	vim.fn.delete(root, "rf")
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
