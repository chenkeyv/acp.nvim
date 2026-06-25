local jsonrpc = require("acp.jsonrpc")
local actions = require("acp.actions")
local call_hierarchy = require("acp.call_hierarchy")
local acp_changes = require("acp.changes")
local code_actions = require("acp.code_actions")
local code_lens = require("acp.code_lens")
local document_colors = require("acp.document_colors")
local document_links = require("acp.document_links")
local folding_ranges = require("acp.folding_ranges")
local acp_blink = require("acp.blink")
local acp_commands = require("acp.commands")
local acp_config = require("acp.config")
local acp_context = require("acp.context")
local acp_diagnostics = require("acp.diagnostics")
local acp_health = require("acp.health")
local inlay_hints = require("acp.inlay_hints")
local lsp_highlights = require("acp.highlights")
local file_review = require("acp.file_review")
local hover = require("acp.hover")
local history = require("acp.history")
local icons = require("acp.icons")
local acp_output = require("acp.output")
local permission = require("acp.permission")
local picker = require("acp.picker")
local prompt_completion = require("acp.prompt_completion")
local prompt_view = require("acp.prompt_view")
local references = require("acp.references")
local selection_ranges = require("acp.selection_ranges")
local session_view = require("acp.session_view")
local signature = require("acp.signature")
local smart_context = require("acp.smart_context")
local source_view = require("acp.source_view")
local symbols = require("acp.symbols")
local treesitter = require("acp.treesitter")
local type_hierarchy = require("acp.type_hierarchy")
local workspace_symbols = require("acp.workspace_symbols")
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
		"AcpClose",
		"AcpCloseAll",
		"AcpSessions",
		"AcpActions",
		"AcpPromptActions",
		"AcpSourceActions",
		"AcpRefreshSource",
		"AcpChanges",
		"AcpChangesQuickfix",
		"AcpOutput",
		"AcpOutputMap",
		"AcpOutputSearch",
		"AcpOutputItems",
		"AcpOutputItemsQuickfix",
		"AcpOutputYank",
		"AcpOutputDraft",
		"AcpOutputOpen",
		"AcpOutputInspect",
		"AcpOutputActions",
		"AcpOutputNextItem",
		"AcpOutputPrevItem",
		"AcpCodeBlocks",
		"AcpCodeBlocksQuickfix",
		"AcpCodeBlockYank",
		"AcpOutputLocations",
		"AcpOutputQuickfix",
		"AcpOutputProblems",
		"AcpDiagnostics",
		"AcpDiagnosticsQuickfix",
		"AcpWorkspaceDiagnostics",
		"AcpWorkspaceDiagnosticsQuickfix",
		"AcpCommands",
		"AcpConfig",
		"AcpCodeActions",
		"AcpCodeLens",
		"AcpCodeLensQuickfix",
		"AcpDocumentColors",
		"AcpDocumentColorsQuickfix",
		"AcpClearDocumentColors",
		"AcpDocumentLinks",
		"AcpDocumentLinksQuickfix",
		"AcpClearDocumentLinks",
		"AcpFoldingRanges",
		"AcpFoldingRangesQuickfix",
		"AcpClearFoldingRanges",
		"AcpRename",
		"AcpSmartContext",
		"AcpHover",
		"AcpSignature",
		"AcpInlayHints",
		"AcpSelectionRanges",
		"AcpCallers",
		"AcpCallersQuickfix",
		"AcpCallees",
		"AcpCalleesQuickfix",
		"AcpSupertypes",
		"AcpSupertypesQuickfix",
		"AcpSubtypes",
		"AcpSubtypesQuickfix",
		"AcpHighlights",
		"AcpClearHighlights",
		"AcpReferences",
		"AcpReferencesQuickfix",
		"AcpDeclarations",
		"AcpDeclarationsQuickfix",
		"AcpDefinitions",
		"AcpDefinitionsQuickfix",
		"AcpImplementations",
		"AcpImplementationsQuickfix",
		"AcpTypeDefinitions",
		"AcpTypeDefinitionsQuickfix",
		"AcpWorkspaceSymbols",
		"AcpWorkspaceSymbolsQuickfix",
		"AcpSymbols",
		"AcpSymbolsQuickfix",
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
	ok(text:find(icons.action, 1, true))
	ok(text:find("Output outline", 1, true))
	ok(text:find(icons.map, 1, true))
	ok(text:find("<leader>av", 1, true))
	ok(text:find(icons.key, 1, true))
	ok(text:find(icons.note, 1, true))
	ok(text:find("[session]", 1, true))
	ok(text:find(icons.session, 1, true))
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
	ok(empty.ghost:find(icons.prompt, 1, true))
	ok(empty.ghost:find("<C%-s> send"))
	ok(empty.ghost:find("? actions", 1, true))
	ok(empty.ghost:find("@context", 1, true))

	local busy = prompt_view.info({ "" }, { busy = true })
	ok(busy.ghost:find(icons.busy, 1, true))
	ok(busy.ghost:find("responding", 1, true))

	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(source_buf, vim.fs.joinpath(vim.fn.getcwd(), "prompt_source.lua"))
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local value = 1",
		"value = value + 1",
		"print(value)",
	})
	vim.bo[source_buf].filetype = "lua"
	local prompt_diag_ns = vim.api.nvim_create_namespace("acp.nvim.prompt-view-test")
	vim.diagnostic.set(prompt_diag_ns, source_buf, {
		{
			lnum = 0,
			col = 0,
			message = "warn in prompt source",
			severity = vim.diagnostic.severity.WARN,
		},
		{
			lnum = 2,
			col = 0,
			message = "error in prompt source",
			severity = vim.diagnostic.severity.ERROR,
		},
		{
			lnum = 4,
			col = 0,
			message = "outside selected source",
			severity = vim.diagnostic.severity.HINT,
		},
	})
	local draft = prompt_view.info({ "hello ACP", "with context" }, {
		adapter = "test",
		blink = true,
		context_window = 1000,
		model = "test-model",
		run_status = "streaming",
		source = {
			bufnr = source_buf,
			range = {
				line1 = 1,
				line2 = 3,
			},
		},
	})
	local ribbon = {}
	for _, chunk in ipairs(draft.ribbon or {}) do
		table.insert(ribbon, chunk[1])
	end
	local ribbon_text = table.concat(ribbon)
	ok(not draft.empty)
	ok(ribbon_text:find("ACP", 1, true))
	ok(ribbon_text:find(icons.acp, 1, true))
	ok(ribbon_text:find("test", 1, true))
	ok(ribbon_text:find(icons.session, 1, true))
	ok(ribbon_text:find("model test-model", 1, true))
	ok(ribbon_text:find(icons.model, 1, true))
	ok(ribbon_text:find("ctx 1k", 1, true))
	ok(ribbon_text:find(icons.context, 1, true))
	ok(ribbon_text:find("status streaming", 1, true))
	ok(ribbon_text:find(icons.status, 1, true))
	ok(ribbon_text:find("diagnostics E1 W1", 1, true))
	ok(ribbon_text:find(icons.diagnostics, 1, true))
	ok(not ribbon_text:find("H1", 1, true))
	ok(ribbon_text:find("[lua]", 1, true))
	ok(ribbon_text:find("blink", 1, true))
	ok(draft.stats:find("2 lines", 1, true))
	ok(draft.stats:find("22 chars", 1, true))
	ok(draft.stats:find("4 words", 1, true))
	vim.diagnostic.reset(prompt_diag_ns, source_buf)
	pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
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
	ok(text:find(icons.session, 1, true))
	ok(text:find("streaming  2 change(s)", 1, true))
	ok(text:find("error: failed", 1, true))
	eq(line_ids[3], 1)
	eq(line_ids[4], 1)
	eq(styles[1].line_hl_group, "AcpSessionHeader")
	ok(styles[1].virt_text[1][1]:find(icons.action, 1, true))
	eq(styles[3].line_hl_group, "AcpSessionCurrent")
	ok(styles[3].virt_text[1][1]:find(icons.busy, 1, true))
	eq(styles[4].line_hl_group, "AcpSessionBusy")
	ok(styles[4].virt_text[1][1]:find(icons.changes, 1, true))
	eq(styles[6].line_hl_group, "AcpSessionError")
	ok(styles[5].virt_text[1][1]:find(icons.error, 1, true))
end)

test("session panel view renders transcript and source details", function()
	local lines, line_ids, styles = session_view.panel({
		{
			id = 1,
			adapter = "test",
			run_status = "idle",
			source_label = "src lua/acp/ui.lua:42",
			transcript_stats = {
				sections = 3,
				code_blocks = 2,
				locations = 1,
			},
		},
	}, 1)
	local text = table.concat(lines, "\n")

	ok(text:find("3 sec  2 code  1 loc", 1, true))
	ok(text:find("src lua/acp/ui.lua:42", 1, true))
	eq(line_ids[5], 1)
	eq(styles[5].line_hl_group, "AcpSessionMeta")
end)

test("restore session view renders metadata and preview", function()
	local sessions = {
		{
			sessionId = "session-1234567890abcdef",
			title = "Restore Work",
			updatedAt = "2026-06-25T10:00:00Z",
			createdAt = "2026-06-24T09:00:00Z",
			cwd = "/tmp/acp.nvim/project",
			model = "test-model",
		},
	}
	local lines, line_sessions = session_view.restore_lines(sessions)
	local text = table.concat(lines, "\n")

	ok(text:find("ACP Adapter Sessions", 1, true))
	ok(text:find(icons.restore, 1, true))
	ok(text:find("Restore Work", 1, true))
	ok(text:find("id session-1234567890abcdef", 1, true))
	ok(text:find("updated 2026-06-25T10:00:00Z", 1, true))
	ok(text:find("model test-model", 1, true))
	ok(text:find("cwd /tmp/acp.nvim/project", 1, true))
	eq(line_sessions[3], sessions[1])
	eq(line_sessions[4], sessions[1])
	eq(line_sessions[5], sessions[1])

	local preview = session_view.restore_preview(sessions[1])
	local preview_text = table.concat(preview.lines, "\n")
	eq(preview.filetype, "acp-sessions")
	ok(preview.title:find("ACP restore Restore Work", 1, true))
	ok(preview_text:find(icons.restore, 1, true))
	ok(preview_text:find("Session ID: session-1234567890abcdef", 1, true))
	ok(preview_text:find("Created: 2026-06-24T09:00:00Z", 1, true))
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
	ok(marks[1].opts.virt_text[1][1]:find("ACP #9 ready", 1, true))
	ok(marks[1].opts.virt_text[1][1]:find(icons.source, 1, true))
	eq(marks[1].opts.sign_text, icons.source)
	ok(marks[1].opts.virt_lines[1][1][1]:find(":AcpSourceActions", 1, true))
	eq(marks[2].opts.virt_text, nil)
end)

test("source view summarizes diagnostics in linked context range", function()
	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local value = 1",
		"value = value + 1",
		"print(value)",
		"return value",
	})
	local ns = vim.api.nvim_create_namespace("acp.nvim.test.source_view")
	vim.diagnostic.set(ns, bufnr, {
		{
			lnum = 1,
			col = 0,
			message = "error in range",
			severity = vim.diagnostic.severity.ERROR,
		},
		{
			lnum = 2,
			col = 0,
			message = "warning in range",
			severity = vim.diagnostic.severity.WARN,
		},
		{
			lnum = 3,
			col = 0,
			message = "hint outside range",
			severity = vim.diagnostic.severity.HINT,
		},
	})

	local marks = source_view.marks({
		id = 9,
		source = {
			bufnr = bufnr,
			cursor = { 2, 0 },
			range = {
				line1 = 2,
				line2 = 3,
			},
		},
	})
	local label = ""
	for _, chunk in ipairs(marks[1].opts.virt_text) do
		label = label .. chunk[1]
	end

	ok(label:find("E1", 1, true))
	ok(label:find("W1", 1, true))
	ok(not label:find("H1", 1, true))
	ok(marks[1].opts.virt_lines[1][1][1]:find("diagnostics E1 W1", 1, true))

	vim.diagnostic.reset(ns, bufnr)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("source view renders LSP document highlights", function()
	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local value = 1",
		"local color = '#FF8000'",
		"local link = 'https://example.com/docs'",
		"value = value + 1",
	})

	local marks = source_view.marks({
		id = 7,
		source = {
			bufnr = bufnr,
			cursor = { 2, 0 },
		},
		source_highlights = {
			{
				kind = 3,
				range = {
					line1 = 3,
					line2 = 3,
					col1 = 7,
					col2 = 12,
				},
			},
		},
		source_colors = {
			{
				color = { red = 1, green = 0.5, blue = 0, alpha = 1 },
				range = {
					line1 = 2,
					line2 = 2,
					col1 = 16,
					col2 = 23,
				},
			},
		},
		source_document_links = {
			{
				target = "https://example.com/docs",
				tooltip = "Example docs",
				range = {
					line1 = 3,
					line2 = 3,
					col1 = 15,
					col2 = 39,
				},
			},
		},
		source_folding_ranges = {
			{
				kind = "region",
				collapsedText = "local setup",
				range = {
					line1 = 1,
					line2 = 3,
					col1 = 1,
				},
			},
		},
	})

	local lens = marks[1].opts.virt_lines[1][1][1]
	ok(lens:find("highlights 1", 1, true))
	ok(lens:find("colors 1", 1, true))
	ok(lens:find("links 1", 1, true))
	ok(lens:find("folds 1", 1, true))
	local highlight_mark
	local color_range_mark
	local color_badge_mark
	local link_range_mark
	local link_badge_mark
	local fold_range_marks = 0
	local fold_badge_mark
	for _, mark in ipairs(marks) do
		if mark.opts.hl_group == "AcpSourceHighlightWrite" then
			highlight_mark = mark
		end
		if mark.opts.hl_group == "AcpSourceColorRange" then
			color_range_mark = mark
		end
		if mark.opts.hl_group == "AcpSourceLinkRange" then
			link_range_mark = mark
		end
		if mark.opts.line_hl_group == "AcpSourceFoldRange" then
			fold_range_marks = fold_range_marks + 1
		end
		for _, chunk in ipairs(mark.opts.virt_text or {}) do
			if chunk[1] and chunk[1]:find("COLOR #FF8000", 1, true) then
				color_badge_mark = mark
			end
			if chunk[1] and chunk[1]:find("LINK https://example.com/docs", 1, true) then
				link_badge_mark = mark
			end
			if chunk[1] and chunk[1]:find("FOLD region lines 1%-3: local setup") then
				fold_badge_mark = mark
			end
		end
	end
	ok(highlight_mark, "source highlights should render a write mark")
	eq(highlight_mark.line, 3)
	eq(highlight_mark.col, 6)
	eq(highlight_mark.opts.end_col, 11)
	ok(color_range_mark, "source document colors should render a range mark")
	eq(color_range_mark.line, 2)
	eq(color_range_mark.opts.end_col, 22)
	ok(color_badge_mark, "source document colors should render a swatch badge")
	eq(color_badge_mark.opts.sign_text, icons.color)
	ok(link_range_mark, "source document links should render a range mark")
	eq(link_range_mark.line, 3)
	eq(link_range_mark.opts.end_col, 38)
	ok(link_badge_mark, "source document links should render a link badge")
	eq(link_badge_mark.opts.sign_text, icons.reference)
	eq(fold_range_marks, 3)
	ok(fold_badge_mark, "source folding ranges should render a fold badge")
	eq(fold_badge_mark.opts.sign_text, icons.fold)

	vim.api.nvim_buf_delete(bufnr, { force = true })
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
	ok(text:find("? actions", 1, true))
	ok(text:find("K inspect", 1, true))
	ok(text:find("]o/[o items", 1, true))
	ok(text:find("[[/]] sections", 1, true))
	ok(text:find("<leader>ax search", 1, true))

	eq(acp_output.line_style("You").line_hl_group, "AcpUserHeader")
	eq(acp_output.line_style("You").sign_text, icons.user)
	eq(acp_output.line_style("You").separator, "---- USER: Prompt ----")
	eq(acp_output.line_style("Agent").sign_text, icons.agent)
	eq(acp_output.line_style("Agent").separator, "---- AGENT: Response ----")
	ok(acp_output.line_style("ACP: test").badge:find(icons.session, 1, true))
	eq(acp_output.line_style("Transcript: 1 section | 0 code | 0 locs | 0 changes").line_hl_group, "AcpOutputMeta")
	eq(acp_output.line_style("Status: error: failed").line_hl_group, "AcpStatusError")
	eq(acp_output.line_style("Status: error: failed").sign_text, icons.error)
	eq(acp_output.line_style("Status: error: failed").separator, "---- STATUS: Error ----")
	eq(acp_output.line_style("Tool: build").sign_text, icons.tool)
	ok(acp_output.line_style("Tool: build").separator:find("TOOL: build", 1, true))
	ok(acp_output.line_style("Tool update: running").separator:find("TOOL UPDATE: running", 1, true))
	eq(acp_output.line_style("Terminal: term-1").sign_text, icons.terminal)
	ok(acp_output.line_style("Terminal: term-1").separator:find("TERMINAL: term-1", 1, true))
	local warning_style = acp_output.line_style("Terminal output truncated to the configured byte limit.")
	eq(warning_style.line_hl_group, "AcpWarning")
	eq(warning_style.sign_text, icons.warning)
	ok(warning_style.separator:find("TERMINAL WARNING", 1, true))
	eq(acp_output.line_style("Wrote lua/acp/init.lua").sign_text, icons.file)
	eq(acp_output.next_section({ "ACP: test", "", "You", "hello", "Agent" }, 1, 1), 3)
	eq(acp_output.next_section({ "ACP: test", "", "You", "hello", "Agent" }, 5, -1), 3)

	local sections = acp_output.sections({ "ACP: test", "", "You", "hello", "Agent", "world" })
	eq(#sections, 3)
	eq(sections[2].kind, "USER")
	eq(sections[2].preview, "hello")
	local terminal_sections = acp_output.sections({ "Terminal output truncated to the configured byte limit." })
	eq(terminal_sections[1].kind, "TERM")
	eq(terminal_sections[1].title, "Output truncated")
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
	local timeline = acp_output.section_timeline({ "ACP: test", "", "You", "hello", "Agent", "world" })
	eq(timeline[3].index, 2)
	eq(timeline[3].total, 3)
	eq(timeline[3].progress, " 50%")
	ok(timeline[3].label:find("2/3", 1, true))
	local rail_lines = { "ACP: test", "Session: #7", "You", "hello", "Agent" }
	eq(acp_output.statuscolumn_marker(rail_lines, 1), "01")
	eq(acp_output.statuscolumn_marker(rail_lines, 3), "02")
	eq(acp_output.statuscolumn_marker(rail_lines, 4), " |")
	eq(acp_output.statuscolumn_marker({ "Status: error: failed" }, 1), icons.error)
	eq(acp_output.statuscolumn_marker({ "Agent", "```lua", "print(1)", "```" }, 2), icons.code)
	eq(acp_output.statuscolumn_marker({ "Agent", "```lua", "print(1)", "```" }, 3), icons.code)
	eq(acp_output.statuscolumn_marker({ "Agent", "```lua", "print(1)", "```" }, 4), icons.code)
	eq(acp_output.statuscolumn_marker({}, 1), "  ")
	local outline, line_sections = acp_output.outline_lines(sections)
	local outline_text = table.concat(outline, "\n")
	ok(outline_text:find("ACP Output Outline", 1, true))
	ok(outline_text:find("USER", 1, true))
	ok(outline_text:find("50%%", 1, false))
	eq(line_sections[3].kind, "SESSION")
	local transcript_entries = acp_output.transcript_entries({ "ACP: test", "", "You", "hello", "Status: running" })
	eq(#transcript_entries, 4)
	eq(transcript_entries[2].kind, "USER")
	eq(transcript_entries[3].line, 4)
	eq(transcript_entries[3].total_lines, 5)
	local transcript_picker, line_entries = acp_output.transcript_entry_lines(transcript_entries)
	local transcript_text = table.concat(transcript_picker, "\n")
	ok(transcript_text:find("ACP Output Search", 1, true))
	ok(transcript_text:find("hello", 1, true))
	ok(transcript_text:find("80%%", 1, false))
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
	eq(acp_output.motion_frame(1), "[>   ]")
	eq(acp_output.motion_frame(9), "[>   ]")
	local skyline_lines = { "ACP: test", "You", "hello", "Agent", "```lua", "print(1)", "```" }
	local skyline = acp_output.skyline(skyline_lines, { width = 12, current_line = 6 })
	ok(skyline:find("S", 1, true))
	ok(skyline:find("C", 1, true))
	ok(skyline:find(">", 1, true))
	local skyline_text = acp_output.skyline_text(skyline_lines, {
		width = 12,
		frame = 2,
		language_injection = true,
		run_status = "streaming",
		busy = true,
	})
	ok(skyline_text:find("FLOW", 1, true))
	ok(skyline_text:find("inject Tree%-sitter:lua", 1, false))
	ok(skyline_text:find("streaming", 1, true))
	local activity_badge, activity_hl = acp_output.activity_badge({
		busy = true,
		run_status = "streaming",
	}, {
		sections = 2,
		code_blocks = 1,
		locations = 1,
		changes = 1,
	}, 2)
	ok(activity_badge:find("/ streaming", 1, true))
	ok(activity_badge:find("2 sections", 1, true))
	ok(activity_badge:find("1 code", 1, true))
	ok(activity_badge:find("1 loc", 1, true))
	ok(activity_badge:find("1 change", 1, true))
	ok(activity_badge:find("[=>  ]", 1, true))
	eq(activity_hl, "AcpOutputActivity")
	local error_badge, error_hl = acp_output.activity_badge({ run_status = "error: failed" }, {}, 1)
	ok(error_badge:find("error: failed", 1, true))
	eq(error_hl, "AcpBadgeError")
	local tool_lens = acp_output.activity_lens_chunks("Tool: shell", 2)
	eq(tool_lens[1][2], "AcpOutputMotion")
	eq(tool_lens[2][1], (" %s TOOL CALL "):format(icons.tool))
	eq(tool_lens[2][2], "AcpOutputActivityTool")
	ok(tool_lens[3][1]:find("shell", 1, true))
	ok(tool_lens[4][1]:find("K inspect", 1, true))
	local terminal_lens = acp_output.activity_lens_chunks("Terminal: term-1", 2)
	eq(terminal_lens[2][1], (" %s TERMINAL "):format(icons.terminal))
	eq(terminal_lens[2][2], "AcpOutputActivityTerminal")
	local file_lens = acp_output.activity_lens_chunks("Wrote lua/acp/init.lua", 2)
	eq(file_lens[2][1], (" %s FILE WRITE "):format(icons.file))
	eq(file_lens[2][2], "AcpOutputActivityFile")
	local stderr_lens = acp_output.activity_lens_chunks("stderr: failed", 2)
	eq(stderr_lens[2][2], "AcpOutputActivityProblem")
	local live_status, live_status_hl = acp_output.live_status_label({ run_status = "streaming" }, 2)
	ok(live_status:find("/ live: streaming", 1, true))
	ok(live_status:find("[=>  ]", 1, true))
	eq(live_status_hl, "AcpOutputLive")
	local busy_ghost = acp_output.ghost_text({ busy = true, run_status = "streaming" }, {}, 2)
	ok(busy_ghost:find("streaming", 1, true))
	ok(busy_ghost:find("[=>  ]", 1, true))
	ok(busy_ghost:find("0 sections", 1, true))
	ok(busy_ghost:find("FLOW", 1, true))
	local ghost_chunks = acp_output.ghost_text_chunks({ busy = false }, { "ACP: test", "You", "hello", "Agent", "done" }, 1)
	eq(ghost_chunks[2][2], "AcpOutputRail")
	ok(acp_output.ghost_text({ busy = false }, { "ACP: test", "" }):find("Ready", 1, true))
	ok(acp_output.cursor_hint({ "You", "hello" }, 1, 0):find("? menu", 1, true))
	ok(acp_output.cursor_hint({ "You", "hello" }, 1, 0):find("<leader>ay yank", 1, true))
	local ribbon = acp_output.cursor_ribbon({
		"ACP: test",
		"You",
		"hello",
		"Agent",
		"```lua",
		"print(1)",
		"```",
	}, 6, 0, { width = 10 })
	ok(ribbon:find("CTX", 1, true))
	ok(ribbon:find("86%%", 1, false))
	ok(ribbon:find("AGENT", 1, true))
	ok(ribbon:find("L4%-7", 1, false))
	ok(ribbon:find("ITEM CODE", 1, true))
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
	local block_header = acp_output.code_block_header(block_at, true, 2)
	ok(block_header:find("CODE lua", 1, true))
	ok(block_header:find("lua -> lua", 1, true))
	ok(block_header:find("1 line", 1, true))
	ok(block_header:find("L3-3", 1, true))
	ok(block_header:find("Tree-sitter injection", 1, true))
	ok(block_header:find("ready", 1, true))
	ok(block_header:find("<Enter> open", 1, true))
	ok(block_header:find("<leader>aY yank", 1, true))
	local block_lens = acp_output.code_block_lens(block_at, true, 2)
	local block_lens_text = {}
	for _, chunk in ipairs(block_lens) do
		table.insert(block_lens_text, chunk[1])
	end
	ok(table.concat(block_lens_text):find("Tree-sitter injection", 1, true))
	local injection_badge = acp_output.injection_badge(block_at, true, 2)
	ok(injection_badge:find("INJECT", 1, true))
	ok(injection_badge:find("lua", 1, true))
	ok(injection_badge:find("TS L3-3", 1, true))
	eq(acp_output.injected_languages({ "Agent", "```lua", "print(1)", "```" })[1], "lua")
	local injection_ranges = acp_output.injection_ranges({ "Agent", "```lua", "print(1)", "```" })
	eq(injection_ranges[1].line1, 3)
	eq(injection_ranges[1].line2, 3)
	eq(injection_ranges[1].filetype, "lua")
	local code_hint = acp_output.cursor_hint({ "Agent", "```lua", "print(1)", "```" }, 3, 0, {
		language_injection = true,
	})
	ok(code_hint:find("code lua", 1, true))
	ok(code_hint:find("Tree-sitter injection", 1, true))
	ok(code_hint:find("]o/[o items", 1, true))
	local code_hint_chunks = acp_output.cursor_hint_chunks({ "Agent", "```lua", "print(1)", "```" }, 3, 0, {
		language_injection = true,
	})
	eq(code_hint_chunks[1][2], "AcpCodeBlockHeader")
	eq(code_hint_chunks[3][2], "AcpInjectedLanguageActive")
	local block_picker, line_blocks = acp_output.code_block_lines(blocks)
	local block_text = table.concat(block_picker, "\n")
	ok(block_text:find("ACP Output Code Blocks", 1, true))
	ok(block_text:find("lua", 1, true))
	ok(block_text:find("Q for quickfix", 1, true))
	eq(line_blocks[3].language, "lua")
	local block_qf = acp_output.code_block_quickfix_items(blocks, 42)
	eq(#block_qf, 2)
	eq(block_qf[1].bufnr, 42)
	eq(block_qf[1].lnum, 2)
	ok(block_qf[1].text:find("CODE lua lines 2%-4", 1, false))

	local ref_file = vim.fn.tempname() .. ".lua"
	vim.fn.writefile({ "local one = 1", "local two = 2" }, ref_file)
	local ref_line = ("Check %s:2:7 for details."):format(ref_file)
	eq(acp_output.statuscolumn_marker({ ref_line }, 1), icons.reference)
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
	local ref_hint = acp_output.cursor_hint({ ref_line }, 1, ref_line:find(ref_file, 1, true), {})
	ok(ref_hint:find("open ref", 1, true))
	ok(ref_hint:find("]o/[o items", 1, true))
	local ref_picker, line_refs = acp_output.file_reference_lines(refs)
	local ref_text = table.concat(ref_picker, "\n")
	ok(ref_text:find("ACP Output Locations", 1, true))
	ok(ref_text:find(icons.reference, 1, true))
	ok(ref_text:find(":2:7", 1, true))
	ok(ref_text:find("Q for quickfix", 1, true))
	eq(line_refs[3].line, 2)
	local qf_items = acp_output.file_reference_quickfix_items(refs)
	eq(#qf_items, 1)
	eq(qf_items[1].filename, refs[1].path)
	eq(qf_items[1].lnum, 2)
	eq(qf_items[1].col, 7)
	eq(acp_output.reference_badge(1), (" %s REF "):format(icons.reference))
	eq(acp_output.reference_badge(3), (" %s REF x3 "):format(icons.reference))
	local output_items = acp_output.output_items({
		"Status: error: failed",
		"Agent",
		"```lua",
		"print(1)",
		"```",
		ref_line,
	})
	eq(#output_items, 3)
	eq(output_items[1].kind, "problem")
	eq(output_items[1].line, 1)
	eq(output_items[2].kind, "code")
	eq(output_items[2].line, 3)
	eq(output_items[3].kind, "reference")
	eq(output_items[3].line, 6)
	local item_picker, line_items = acp_output.output_item_lines(output_items, { total_lines = 6 })
	local item_text = table.concat(item_picker, "\n")
	ok(item_text:find("ACP Output Items", 1, true))
	ok(item_text:find("PROBLEM", 1, true))
	ok(item_text:find("CODE", 1, true))
	ok(item_text:find("REFERENCE", 1, true))
	ok(item_text:find("Q for quickfix", 1, true))
	eq(line_items[3].kind, "problem")
	local item_qf = acp_output.output_item_quickfix_items(output_items, 99)
	eq(#item_qf, 3)
	eq(item_qf[1].bufnr, 99)
	eq(item_qf[1].lnum, 1)
	ok(item_qf[1].text:find("PROBLEM", 1, true))
	local map_entries = acp_output.output_map_entries({
		"Status: error: failed",
		"Agent",
		"```lua",
		"print(1)",
		"```",
		ref_line,
	}, {})
	eq(map_entries[1].kind, "section")
	eq(map_entries[2].kind, "problem")
	eq(map_entries[4].kind, "code")
	local map_lines, line_entries = acp_output.output_map_lines(map_entries, {
		current_line = 4,
		total_lines = 6,
	})
	local map_text = table.concat(map_lines, "\n")
	ok(map_text:find("ACP Output Map", 1, true))
	ok(map_text:find("Entries: 5 | sections 2 | problems 1 | code 1 | refs 1", 1, true))
	eq(acp_output.progress_bar(3, 6, 10), "[=====-----]")
	ok(map_text:find("PROBLEM", 1, true))
	ok(map_text:find("CODE", 1, true))
	ok(map_text:find("REFERENCE", 1, true))
	ok(map_text:find("> [=====-----]", 1, true))
	ok(map_text:find("<Enter> to jump", 1, true))
	ok(map_text:find("K to preview", 1, true))
	ok(map_text:find("Q for quickfix", 1, true))
	eq(line_entries[7].kind, "code")
	local map_preview = acp_output.output_map_preview({
		"Status: error: failed",
		"Agent",
		"```lua",
		"print(1)",
		"```",
		ref_line,
	}, map_entries[4])
	eq(map_preview.filetype, "lua")
	ok(table.concat(map_preview.lines, "\n"):find("print(1)", 1, true))
	local map_qf = acp_output.output_map_quickfix_items(map_entries, 99)
	eq(#map_qf, 5)
	eq(map_qf[1].bufnr, 99)
	ok(map_qf[1].text:find("SECTION", 1, true))
	ok(map_qf[4].text:find("CODE", 1, true))
	eq(acp_output.next_output_item({ "Status: error: failed", "Agent", "```lua", "print(1)", "```", ref_line }, 1).kind, "code")
	eq(acp_output.next_output_item({ "Status: error: failed", "Agent", "```lua", "print(1)", "```", ref_line }, 6, -1).kind, "code")
	local current_problem = acp_output.current_output_item({
		"Status: error: failed",
		"Agent",
		"```lua",
		"print(1)",
		"```",
		ref_line,
	}, 1, 0, {})
	eq(current_problem.kind, "problem")
	eq(current_problem.index, 1)
	eq(current_problem.total, 3)
	local current_code = acp_output.current_output_item({
		"Status: error: failed",
		"Agent",
		"```lua",
		"print(1)",
		"```",
		ref_line,
	}, 4, 0, {})
	eq(current_code.kind, "code")
	eq(current_code.index, 2)
	eq(current_code.line2, 5)
	local current_reference = acp_output.current_output_item({
		"Status: error: failed",
		"Agent",
		"```lua",
		"print(1)",
		"```",
		ref_line,
	}, 6, ref_line:find(ref_file, 1, true) - 1, {})
	eq(current_reference.kind, "reference")
	eq(current_reference.index, 3)
	ok(acp_output.window_title({ id = 7, adapter = "test" }, { current_item = current_code }):find("item 2/3 CODE", 1, true))
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
	eq(range.col1, 1)
	eq(range.col2, 2)

	local lines, line_references = references.picker_lines(flattened)
	local text = table.concat(lines, "\n")
	ok(text:find("acp%-reference%.lua:2"))
	ok(text:find("acp%-reference%.lua:4"))
	ok(text:find("Q for quickfix", 1, true))
	eq(line_references[3].uri, uri)

	local qf_items = references.quickfix_items(flattened)
	eq(#qf_items, 2)
	eq(qf_items[1].lnum, 2)
	eq(qf_items[1].col, 1)
	ok(qf_items[1].text:find("REFERENCE", 1, true))

	local single = references.flatten({
		uri = uri,
		range = {
			start = { line = 5, character = 2 },
			["end"] = { line = 5, character = 7 },
		},
	})
	eq(#single, 1)

	local definition_lines = references.picker_lines(flattened, { title = "ACP Definitions" })
	ok(table.concat(definition_lines, "\n"):find("ACP Definitions", 1, true))
	local definition_qf = references.quickfix_items(flattened, { label = "DEFINITION" })
	ok(definition_qf[1].text:find("DEFINITION", 1, true))
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
	ok(text:find("Q for quickfix", 1, true))
	eq(line_items[3].message, "undefined global missing")
	eq(line_items[4].message, "undefined global missing")
	local qf_items = acp_diagnostics.quickfix_items(42, {
		{
			lnum = 1,
			col = 4,
			end_lnum = 1,
			end_col = 11,
			severity = vim.diagnostic.severity.ERROR,
			source = "lua_ls",
			code = "undefined-global",
			message = "undefined global missing",
		},
	})
	eq(qf_items[1].bufnr, 42)
	eq(qf_items[1].lnum, 2)
	eq(qf_items[1].col, 5)
	ok(qf_items[1].text:find("ERROR [lua_ls] (undefined-global): undefined global missing", 1, true))

	local range = acp_diagnostics.range({
		lnum = 2,
		end_lnum = 4,
	})
	eq(range.line1, 3)
	eq(range.line2, 5)

	local first_buf = vim.api.nvim_create_buf(true, false)
	local second_buf = vim.api.nvim_create_buf(true, false)
	local nofile_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[first_buf].swapfile = false
	vim.bo[second_buf].swapfile = false
	vim.api.nvim_buf_set_name(first_buf, vim.fn.tempname() .. "-workspace-a.lua")
	vim.api.nvim_buf_set_name(second_buf, vim.fn.tempname() .. "-workspace-b.lua")
	vim.bo[nofile_buf].buftype = "nofile"
	local ns = vim.api.nvim_create_namespace("acp.nvim.test.workspace-diagnostics")
	vim.diagnostic.set(ns, first_buf, {
		{
			lnum = 0,
			col = 6,
			severity = vim.diagnostic.severity.WARN,
			message = "workspace warn item",
		},
	})
	vim.diagnostic.set(ns, second_buf, {
		{
			lnum = 2,
			col = 3,
			severity = vim.diagnostic.severity.ERROR,
			message = "workspace error item",
		},
	})
	vim.diagnostic.set(ns, nofile_buf, {
		{
			lnum = 0,
			col = 0,
			severity = vim.diagnostic.severity.ERROR,
			message = "ignored nofile workspace item",
		},
	})

	local workspace_items = {}
	for _, item in ipairs(acp_diagnostics.workspace_items()) do
		if item.message:find("workspace ", 1, true) then
			table.insert(workspace_items, item)
		end
	end
	eq(#workspace_items, 2)
	eq(workspace_items[1].bufnr, second_buf)
	ok(workspace_items[1].path:find("workspace%-b%.lua", 1, false))
	local workspace_lines = table.concat(acp_diagnostics.picker_lines(workspace_items), "\n")
	ok(workspace_lines:find("workspace%-b%.lua:3:4 ERROR", 1, false))
	ok(workspace_lines:find("workspace warn item", 1, true))
	local workspace_qf = acp_diagnostics.quickfix_items(workspace_items)
	eq(workspace_qf[1].bufnr, second_buf)
	eq(workspace_qf[1].lnum, 3)
	vim.diagnostic.reset(ns, first_buf)
	vim.diagnostic.reset(ns, second_buf)
	vim.diagnostic.reset(ns, nofile_buf)
	pcall(vim.api.nvim_buf_delete, first_buf, { force = true })
	pcall(vim.api.nvim_buf_delete, second_buf, { force = true })
	pcall(vim.api.nvim_buf_delete, nofile_buf, { force = true })
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

test("LSP signature help is normalized", function()
	local text = signature.text({
		activeSignature = 0,
		activeParameter = 1,
		signatures = {
			{
				label = "join(left: string, right: string): string",
				documentation = {
					value = "Join two strings.",
				},
				parameters = {
					{
						label = "left",
						documentation = "First value.",
					},
					{
						label = "right",
						documentation = {
							value = "Second value.",
						},
					},
				},
			},
		},
	})

	ok(text:find("Signature: join%(left: string, right: string%): string"))
	ok(text:find("Documentation:\nJoin two strings.", 1, true))
	ok(text:find("- left\n  First value.", 1, true))
	ok(text:find("* right\n  Second value.", 1, true))
	eq(signature.text({ signatures = {} }), nil)
end)

test("LSP inlay hints are flattened for picker rows", function()
	local items = inlay_hints.flatten({
		[1] = {
			result = {
				{
					position = { line = 0, character = 19 },
					kind = 2,
					label = "left:",
				},
				{
					position = { line = 0, character = 26 },
					kind = 1,
					label = {
						{ value = ": number" },
					},
				},
			},
		},
	})

	eq(#items, 2)
	eq(items[1].kind, "PARAM")
	eq(items[1].label, "left:")
	eq(items[1].line, 1)
	eq(items[1].col, 20)
	eq(items[2].kind, "TYPE")
	eq(items[2].label, ": number")

	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local result = add(a, b)",
	})
	local lines, line_items = inlay_hints.picker_lines(items, {
		bufnr = source_buf,
		range = { line1 = 1, line2 = 1 },
	})
	local text = table.concat(lines, "\n")
	ok(text:find("ACP Inlay Hints", 1, true))
	ok(text:find("All inlay hints %(2%) lines 1%-1"))
	ok(text:find("PARAM", 1, true))
	ok(text:find("left:", 1, true))
	ok(text:find(": number", 1, true))
	eq(line_items[3].all, true)
	eq(line_items[4], items[1])
	pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
end)

test("LSP selection ranges are flattened for picker rows", function()
	local items = selection_ranges.flatten({
		[1] = {
			result = {
				{
					range = {
						start = { line = 2, character = 14 },
						["end"] = { line = 2, character = 19 },
					},
					parent = {
						range = {
							start = { line = 1, character = 0 },
							["end"] = { line = 4, character = 0 },
						},
					},
				},
			},
		},
	})

	eq(#items, 2)
	eq(items[1].label, "cursor expression")
	eq(items[1].range.line1, 3)
	eq(items[1].range.col1, 15)
	eq(items[2].label, "semantic block")
	eq(items[2].range.line1, 2)
	eq(items[2].range.line2, 4)

	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local function add(a, b)",
		"  if a then",
		"    return a + b",
		"  end",
		"end",
	})
	local lines, line_items = selection_ranges.picker_lines(items, { bufnr = source_buf })
	local text = table.concat(lines, "\n")
	ok(text:find("ACP Selection Ranges", 1, true))
	ok(text:find("cursor expression", 1, true))
	ok(text:find("semantic block", 1, true))
	ok(text:find("return a %+ b"))
	eq(line_items[3], items[1])
	pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
end)

test("smart context prompt combines editor and LSP signals", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local result = add(a, b)",
	})
	vim.bo[source_buf].filetype = "lua"
	local source = acp_context.capture(source_buf, nil, { line1 = 1, line2 = 1 })
	local prompt = smart_context.prompt(source, {
		hover_text = "`add`: function",
		signature_text = "Signature: add(left: number, right: number): number",
		inlay_hints = {
			{ line = 1, col = 20, kind = "PARAM", label = "left:" },
			{ line = 1, col = 23, kind = "TYPE", label = ": number" },
		},
		selection_ranges = {
			{ label = "cursor expression", range = { line1 = 1, line2 = 1 } },
		},
	})

	ok(prompt:find("Use this smart editor context", 1, true))
	ok(prompt:find("Context", 1, true))
	ok(prompt:find("Selected text:", 1, true))
	ok(prompt:find("Hover:\n`add`: function", 1, true))
	ok(prompt:find("Signature help:\nSignature: add%(left: number, right: number%): number"))
	ok(prompt:find("Inlay hints:\n- 1:20 PARAM left:", 1, true))
	ok(prompt:find("- 1:23 TYPE : number", 1, true))
	ok(prompt:find("Selection ranges:\n- cursor expression lines 1-1", 1, true))
	pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
end)

test("LSP document highlights are normalized for source marks", function()
	local items = lsp_highlights.normalize({
		{
			kind = 3,
			range = {
				start = { line = 2, character = 4 },
				["end"] = { line = 2, character = 9 },
			},
		},
		{
			range = {
				start = { line = 4, character = 0 },
				["end"] = { line = 4, character = 5 },
			},
		},
		{
			kind = 2,
		},
	})

	eq(#items, 2)
	eq(items[1].kind, 3)
	eq(items[1].range.line1, 3)
	eq(items[1].range.col1, 5)
	eq(lsp_highlights.kind_name(items[1].kind), "write")
	eq(lsp_highlights.kind_name(items[2].kind), "text")
end)

test("LSP document colors are normalized and rendered", function()
	local items = document_colors.normalize({
		{
			range = {
				start = { line = 2, character = 10 },
				["end"] = { line = 2, character = 17 },
			},
			color = {
				red = 0.2,
				green = 0.4,
				blue = 0.6,
				alpha = 1,
			},
		},
		{
			range = {
				start = { line = 0, character = 1 },
				["end"] = { line = 0, character = 8 },
			},
			color = {
				red = 1,
				green = 0.5,
				blue = 0,
				alpha = 0.5,
			},
		},
	})

	eq(#items, 2)
	eq(document_colors.label(items[1]), "#FF8000 alpha 0.50")
	eq(document_colors.hex(items[2].color), "#336699")
	eq(document_colors.range(items[2]).line1, 3)

	local lines, line_items = document_colors.picker_lines(items)
	local text = table.concat(lines, "\n")
	ok(text:find("ACP Document Colors", 1, true))
	ok(text:find("#FF8000 alpha 0.50", 1, true))
	ok(text:find("Q for quickfix", 1, true))
	eq(line_items[3], items[1])

	local qf_items = document_colors.quickfix_items(42, items)
	eq(qf_items[1].bufnr, 42)
	eq(qf_items[1].lnum, 1)
	ok(qf_items[2].text:find("DOCUMENT COLOR: #336699", 1, true))

	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local color = '#FF8000'",
		"local other = '#336699'",
		"return color .. other",
	})
	vim.bo[bufnr].filetype = "lua"
	local prompt = document_colors.prompt({ bufnr = bufnr }, items[1])
	ok(prompt:find("Use this LSP document color as context: #FF8000 alpha 0.50.", 1, true))
	ok(prompt:find("Document color:", 1, true))
	ok(prompt:find("Selection: lines 1-1", 1, true))
	ok(prompt:find("local color = '#FF8000'", 1, true))
	pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end)

test("LSP document links are normalized and rendered", function()
	local items = document_links.normalize({
		{
			range = {
				start = { line = 2, character = 10 },
				["end"] = { line = 2, character = 28 },
			},
			target = "https://example.com/docs",
			tooltip = "Example documentation",
		},
		{
			range = {
				start = { line = 0, character = 1 },
				["end"] = { line = 0, character = 8 },
			},
			tooltip = "Unresolved docs",
		},
	})

	eq(#items, 2)
	eq(document_links.label(items[1]), "Unresolved docs")
	eq(document_links.label(items[2]), "https://example.com/docs")
	eq(document_links.range(items[2]).line1, 3)

	local lines, line_items = document_links.picker_lines(items)
	local text = table.concat(lines, "\n")
	ok(text:find("ACP Document Links", 1, true))
	ok(text:find("https://example.com/docs", 1, true))
	ok(text:find("Example documentation", 1, true))
	ok(text:find("Q for quickfix", 1, true))
	eq(line_items[3], items[1])

	local qf_items = document_links.quickfix_items(42, items)
	eq(qf_items[1].bufnr, 42)
	eq(qf_items[1].lnum, 1)
	ok(qf_items[2].text:find("DOCUMENT LINK: https://example.com/docs", 1, true))

	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".md")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"[Docs](https://example.com/docs)",
		"plain text",
		"See docs for more detail",
	})
	vim.bo[bufnr].filetype = "markdown"
	local prompt = document_links.prompt({ bufnr = bufnr }, items[2])
	ok(prompt:find("Use this LSP document link as context: https://example.com/docs.", 1, true))
	ok(prompt:find("Document link:", 1, true))
	ok(prompt:find("Target: https://example.com/docs", 1, true))
	ok(prompt:find("Tooltip: Example documentation", 1, true))
	ok(prompt:find("Selection: lines 3-3", 1, true))
	ok(prompt:find("See docs for more detail", 1, true))
	pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end)

test("LSP folding ranges are normalized and rendered", function()
	local items = folding_ranges.normalize({
		{
			startLine = 4,
			endLine = 8,
			startCharacter = 2,
			endCharacter = 12,
			kind = "region",
			collapsedText = "setup block",
		},
		{
			startLine = 0,
			endLine = 2,
			kind = "comment",
		},
	})

	eq(#items, 2)
	eq(folding_ranges.kind(items[1]), "comment")
	eq(folding_ranges.label(items[2]), "region lines 5-9: setup block")
	eq(folding_ranges.range(items[2]).line1, 5)
	eq(folding_ranges.range(items[2]).col1, 3)

	local lines, line_items = folding_ranges.picker_lines(items)
	local text = table.concat(lines, "\n")
	ok(text:find("ACP Folding Ranges", 1, true))
	ok(text:find("comment", 1, true))
	ok(text:find("setup block", 1, true))
	ok(text:find("Q for quickfix", 1, true))
	eq(line_items[3], items[1])

	local qf_items = folding_ranges.quickfix_items(42, items)
	eq(qf_items[1].bufnr, 42)
	eq(qf_items[1].lnum, 1)
	ok(qf_items[2].text:find("FOLDING RANGE: region lines 5%-9: setup block"))

	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local function setup()",
		"  local value = 1",
		"  return value",
		"end",
		"local function run()",
		"  setup()",
		"end",
		"return run",
		"",
	})
	vim.bo[bufnr].filetype = "lua"
	local prompt = folding_ranges.prompt({ bufnr = bufnr }, items[2])
	ok(prompt:find("Use this LSP folding range as context: region lines 5%-9: setup block."))
	ok(prompt:find("Folding range:", 1, true))
	ok(prompt:find("Kind: region", 1, true))
	ok(prompt:find("Collapsed text: setup block", 1, true))
	ok(prompt:find("Selection: lines 5-9", 1, true))
	ok(prompt:find("local function run", 1, true))
	pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
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

test("LSP code lenses are flattened and rendered for picker", function()
	local items = code_lens.normalize({
		{
			range = {
				start = { line = 1, character = 2 },
				["end"] = { line = 1, character = 12 },
			},
			command = {
				title = "Run test",
				command = "test.run",
				arguments = { "nearest" },
			},
		},
		{
			range = {
				start = { line = 0, character = 0 },
				["end"] = { line = 0, character = 8 },
			},
		},
	})

	eq(#items, 2)
	eq(code_lens.title(items[1]), "Unresolved code lens")
	eq(code_lens.range(items[2]).line1, 2)
	local lines, line_items = code_lens.picker_lines(items)
	local text = table.concat(lines, "\n")
	ok(text:find("ACP Code Lens", 1, true))
	ok(text:find("Run test  test.run", 1, true))
	ok(text:find("Q for quickfix", 1, true))
	eq(line_items[3], items[1])

	local qf_items = code_lens.quickfix_items(42, items)
	eq(qf_items[1].bufnr, 42)
	eq(qf_items[1].lnum, 1)
	ok(qf_items[2].text:find("CODE LENS: Run test", 1, true))

	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local function test_value()",
		"  return 1",
		"end",
	})
	vim.bo[bufnr].filetype = "lua"
	local prompt = code_lens.prompt({ bufnr = bufnr }, items[2])
	ok(prompt:find("Use this LSP code lens as context: Run test.", 1, true))
	ok(prompt:find("Command: test.run", 1, true))
	ok(prompt:find("Arguments: 1 item", 1, true))
	ok(prompt:find("Selection: lines 2-2", 1, true))
	pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end)

test("LSP prepare rename result is normalized and rendered", function()
	local rename = require("acp.rename")
	local bufnr = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"local old_name = 1",
		"print(old_name)",
	})
	vim.bo[bufnr].filetype = "lua"
	local source = {
		bufnr = bufnr,
		cursor = { 1, 8 },
	}

	local item = rename.normalize({
		range = {
			start = { line = 0, character = 6 },
			["end"] = { line = 0, character = 14 },
		},
		placeholder = "old_name",
	}, source)
	eq(item.placeholder, "old_name")
	eq(item.range.line1, 1)
	eq(item.range.col1, 7)
	eq(item.range.col2, 15)

	local default_item = rename.normalize({
		defaultBehavior = true,
	}, source)
	eq(default_item.placeholder, "old_name")
	eq(default_item.range.line1, 1)

	local prompt = rename.prompt(source, item, "new_name")
	ok(prompt:find("Rename this symbol to `new_name`", 1, true))
	ok(prompt:find("Current name: old_name", 1, true))
	ok(prompt:find("New name: new_name", 1, true))
	ok(prompt:find("Selection: lines 1-1", 1, true))
	ok(prompt:find("local old_name = 1", 1, true))

	pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
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
	local range = symbols.range(flattened[2])
	eq(range.line1, 2)
	eq(range.line2, 4)
	eq(range.col1, 2)
	eq(range.col2, 3)

	local lines, line_symbols = symbols.picker_lines(flattened)
	local text = table.concat(lines, "\n")
	ok(text:find("Example  Class lines 1-5", 1, true))
	ok(text:find("class detail", 1, true))
	ok(text:find("  run  Function lines 2-4", 1, true))
	ok(text:find("from-location  Variable lines 8-8", 1, true))
	ok(text:find("Q for quickfix", 1, true))
	eq(line_symbols[3].name, "Example")
	eq(line_symbols[5].name, "run")

	local qf_items = symbols.quickfix_items(42, flattened)
	eq(#qf_items, 3)
	eq(qf_items[1].bufnr, 42)
	eq(qf_items[2].lnum, 2)
	eq(qf_items[2].col, 2)
	ok(qf_items[2].text:find("SYMBOL: run %(Function%)"))
end)

test("LSP workspace symbols are rendered for picker and quickfix", function()
	local uri = vim.uri_from_fname("/tmp/acp-workspace-symbol.lua")
	local normalized = workspace_symbols.normalize({
		{
			name = "WorkspaceValue",
			kind = 13,
			containerName = "Example",
			location = {
				uri = uri,
				range = {
					start = { line = 2, character = 4 },
					["end"] = { line = 2, character = 18 },
				},
			},
		},
		{
			name = "",
			location = {
				uri = uri,
				range = {
					start = { line = 0, character = 0 },
					["end"] = { line = 0, character = 1 },
				},
			},
		},
	})

	eq(#normalized, 1)
	ok(workspace_symbols.display_path(normalized[1]):find("acp%-workspace%-symbol%.lua"))
	local range = workspace_symbols.range(normalized[1])
	eq(range.line1, 3)
	eq(range.col1, 5)

	local lines, line_symbols = workspace_symbols.picker_lines(normalized, { title = "ACP Workspace Symbols: Value" })
	local text = table.concat(lines, "\n")
	ok(text:find("ACP Workspace Symbols: Value", 1, true))
	ok(text:find("WorkspaceValue  Variable", 1, true))
	ok(text:find("Example", 1, true))
	ok(text:find("Q for quickfix", 1, true))
	eq(line_symbols[3].name, "WorkspaceValue")

	local qf_items = workspace_symbols.quickfix_items(normalized)
	eq(#qf_items, 1)
	eq(qf_items[1].lnum, 3)
	eq(qf_items[1].col, 5)
	ok(qf_items[1].text:find("WORKSPACE SYMBOL", 1, true))
end)

test("LSP call hierarchy entries are rendered for picker and quickfix", function()
	local path = vim.fn.tempname() .. ".lua"
	vim.fn.writefile({
		"local function caller()",
		"\ttarget()",
		"end",
	}, path)
	local uri = vim.uri_from_fname(path)
	local incoming = call_hierarchy.normalize({
		{
			from = {
				name = "caller",
				kind = 12,
				detail = "local function",
				uri = uri,
				range = {
					start = { line = 0, character = 0 },
					["end"] = { line = 2, character = 3 },
				},
				selectionRange = {
					start = { line = 0, character = 15 },
					["end"] = { line = 0, character = 21 },
				},
			},
			fromRanges = {
				{
					start = { line = 1, character = 1 },
					["end"] = { line = 1, character = 9 },
				},
			},
		},
	}, "incoming")
	local outgoing = call_hierarchy.normalize({
		{
			to = {
				name = "callee",
				kind = 12,
				uri = uri,
				range = {
					start = { line = 1, character = 1 },
					["end"] = { line = 1, character = 9 },
				},
			},
		},
	}, "outgoing")

	eq(#incoming, 1)
	eq(incoming[1].name, "caller")
	eq(call_hierarchy.range(incoming[1]).line1, 1)
	eq(call_hierarchy.range(incoming[1]).col1, 16)
	eq(outgoing[1].name, "callee")
	eq(call_hierarchy.range(outgoing[1]).line1, 2)

	local lines, line_calls = call_hierarchy.picker_lines(incoming, { direction = "incoming" })
	local text = table.concat(lines, "\n")
	ok(text:find("ACP Incoming Calls", 1, true))
	ok(text:find("caller  Function", 1, true))
	ok(text:find("local function", 1, true))
	ok(text:find("Q for quickfix", 1, true))
	eq(line_calls[3].name, "caller")

	local qf_items = call_hierarchy.quickfix_items(incoming, { direction = "incoming" })
	eq(#qf_items, 1)
	eq(qf_items[1].lnum, 1)
	eq(qf_items[1].col, 16)
	ok(qf_items[1].text:find("INCOMING CALL", 1, true))

	local prompt = call_hierarchy.prompt(incoming[1], "incoming")
	ok(prompt:find("Use this LSP incoming call as context: caller %(Function%)."))
	ok(prompt:find("Call caller:", 1, true))
	ok(prompt:find("local function caller", 1, true))
end)

test("LSP type hierarchy entries are rendered for picker and quickfix", function()
	local path = vim.fn.tempname() .. ".lua"
	vim.fn.writefile({
		"local Base = {}",
		"local Child = setmetatable({}, Base)",
	}, path)
	local uri = vim.uri_from_fname(path)
	local supertypes = type_hierarchy.normalize({
		{
			name = "Base",
			kind = 5,
			detail = "base type",
			uri = uri,
			range = {
				start = { line = 0, character = 0 },
				["end"] = { line = 0, character = 15 },
			},
			selectionRange = {
				start = { line = 0, character = 6 },
				["end"] = { line = 0, character = 10 },
			},
		},
	}, "supertypes")
	local subtypes = type_hierarchy.normalize({
		{
			name = "Child",
			kind = 5,
			uri = uri,
			range = {
				start = { line = 1, character = 0 },
				["end"] = { line = 1, character = 35 },
			},
		},
	}, "subtypes")

	eq(#supertypes, 1)
	eq(supertypes[1].name, "Base")
	eq(type_hierarchy.range(supertypes[1]).line1, 1)
	eq(type_hierarchy.range(supertypes[1]).col1, 7)
	eq(subtypes[1].name, "Child")
	eq(type_hierarchy.range(subtypes[1]).line1, 2)

	local lines, line_items = type_hierarchy.picker_lines(supertypes, { direction = "supertypes" })
	local text = table.concat(lines, "\n")
	ok(text:find("ACP Supertypes", 1, true))
	ok(text:find("Base  Class", 1, true))
	ok(text:find("base type", 1, true))
	ok(text:find("Q for quickfix", 1, true))
	eq(line_items[3].name, "Base")

	local qf_items = type_hierarchy.quickfix_items(supertypes, { direction = "supertypes" })
	eq(#qf_items, 1)
	eq(qf_items[1].lnum, 1)
	eq(qf_items[1].col, 7)
	ok(qf_items[1].text:find("SUPERTYPE", 1, true))

	local prompt = type_hierarchy.prompt(supertypes[1], "supertypes")
	ok(prompt:find("Use this LSP supertype as context: Base %(Class%)."))
	ok(prompt:find("Supertype:", 1, true))
	ok(prompt:find("local Base", 1, true))
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
	eq(plan_items[1].abbr, ("%s /plan"):format(icons.terminal))
	eq(plan_items[1].icon, icons.terminal)
	eq(plan_items[1].menu, "task")
	eq(plan_items[1].info, "Create a plan")

	local all_items = acp_commands.completion_items(commands, "/")
	eq(#all_items, 2)
	eq(all_items[2].word, "/test")
	eq(all_items[2].menu, "ACP")

	eq(prompt_completion.start("/pl", 3), 0)
	eq(prompt_completion.start("ask /pl", 7), -3)
	eq(prompt_completion.start("@con", 4), 0)
	eq(prompt_completion.start("ask @co", 7), 4)

	local workflow_items = prompt_completion.items(commands, "@co")
	eq(workflow_items[1].word, "@context")
	eq(workflow_items[1].abbr, ("%s @context"):format(icons.source))
	eq(workflow_items[1].icon, icons.source)
	eq(workflow_items[1].kind, "Snippet")
	eq(workflow_items[1].user_data, "acp.nvim:context")
	eq(prompt_completion.action_id(workflow_items[1]), "context")
	local smart_item = prompt_completion.items(commands, "@smart")[1]
	eq(smart_item.word, "@smart-context")
	eq(prompt_completion.action_id(smart_item), "smart_context")
	local code_action_item = prompt_completion.items(commands, "@code")[1]
	eq(code_action_item.word, "@code-actions")
	eq(code_action_item.menu, "LSP")
	local code_lens_item = prompt_completion.items(commands, "@code-l")[1]
	eq(code_lens_item.word, "@code-lens")
	eq(prompt_completion.action_id(code_lens_item), "code_lens")
	local colors_item = prompt_completion.items(commands, "@col")[1]
	eq(colors_item.word, "@colors")
	eq(prompt_completion.action_id(colors_item), "document_colors")
	local links_item = prompt_completion.items(commands, "@lin")[1]
	eq(links_item.word, "@links")
	eq(prompt_completion.action_id(links_item), "document_links")
	local folds_item = prompt_completion.items(commands, "@fold")[1]
	eq(folds_item.word, "@folds")
	eq(prompt_completion.action_id(folds_item), "folding_ranges")
	local rename_item = prompt_completion.items(commands, "@ren")[1]
	eq(rename_item.word, "@rename")
	eq(prompt_completion.action_id(rename_item), "rename")
	local signature_item = prompt_completion.items(commands, "@sig")[1]
	eq(signature_item.word, "@signature")
	eq(prompt_completion.action_id(signature_item), "signature")
	local inlay_item = prompt_completion.items(commands, "@inlay")[1]
	eq(inlay_item.word, "@inlay-hints")
	eq(prompt_completion.action_id(inlay_item), "inlay_hints")
	local selection_item = prompt_completion.items(commands, "@sel")[1]
	eq(selection_item.word, "@selection")
	eq(prompt_completion.action_id(selection_item), "selection")
	local caller_item = prompt_completion.items(commands, "@caller")[1]
	eq(caller_item.word, "@callers")
	eq(prompt_completion.action_id(caller_item), "callers")
	local callee_item = prompt_completion.items(commands, "@callee")[1]
	eq(callee_item.word, "@callees")
	eq(prompt_completion.action_id(callee_item), "callees")
	local supertype_item = prompt_completion.items(commands, "@super")[1]
	eq(supertype_item.word, "@supertypes")
	eq(prompt_completion.action_id(supertype_item), "supertypes")
	local subtype_item = prompt_completion.items(commands, "@sub")[1]
	eq(subtype_item.word, "@subtypes")
	eq(prompt_completion.action_id(subtype_item), "subtypes")
	local workspace_diagnostic_item = prompt_completion.items(commands, "@workspace-d")[1]
	eq(workspace_diagnostic_item.word, "@workspace-diagnostics")
	eq(prompt_completion.action_id(workspace_diagnostic_item), "workspace_diagnostics")

	local completion_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_set_current_buf(completion_buf)
	vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, { "ask @context now" })
	vim.api.nvim_win_set_cursor(0, { 1, 12 })
	ok(prompt_completion.remove_completed_word(completion_buf, vim.api.nvim_get_current_win(), "@context"))
	eq(vim.api.nvim_buf_get_lines(completion_buf, 0, -1, false)[1], "ask  now")
	pcall(vim.api.nvim_buf_delete, completion_buf, { force = true })
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
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(source_buf, vim.fn.tempname() .. ".lua")
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local prompt_context_value = 1",
	})
	vim.bo[source_buf].filetype = "lua"
	local prompt_history_diag_ns = vim.api.nvim_create_namespace("acp.nvim.prompt-history-test")
	vim.diagnostic.set(prompt_history_diag_ns, source_buf, {
		{
			lnum = 0,
			col = 6,
			message = "prompt source error",
			severity = vim.diagnostic.severity.ERROR,
		},
	})
	vim.api.nvim_set_current_buf(source_buf)

	local input_buf
	local original_notify = vim.notify
	vim.notify = function() end

	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		local state_id = tonumber(vim.api.nvim_buf_get_name(input_buf):match("ACP://[^/]+/(%d+)/input$"))
		ok(state_id, "input buffer name should include the ACP session id")
		eq(vim.bo[input_buf].completefunc, "v:lua.acp_nvim_completefunc")
		eq(vim.b[input_buf].acp_blink_source, true)
		eq(vim.b[input_buf].acp_state_id, state_id)
		local prompt_ns = vim.api.nvim_create_namespace("acp.nvim.prompt")
		local marks = vim.api.nvim_buf_get_extmarks(input_buf, prompt_ns, 0, -1, { details = true })
		local ghost = false
		local ribbon = false
		for _, mark in ipairs(marks) do
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("Ask ACP", 1, true) then
					ghost = true
				end
			end
			for _, line in ipairs((mark[4] and mark[4].virt_lines) or {}) do
				local text = {}
				for _, chunk in ipairs(line) do
					table.insert(text, chunk[1] or "")
				end
				text = table.concat(text)
				if
					text:find("ACP", 1, true)
					and text:find("test", 1, true)
					and text:find("diagnostics E1", 1, true)
					and text:find("blink", 1, true)
				then
					ribbon = true
				end
			end
		end
		ok(ghost, "empty prompt should show ghost text")
		ok(ribbon, "empty prompt should show a session ribbon")

		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "@con" })
		vim.api.nvim_win_set_cursor(0, { 1, 4 })
		eq(require("acp.ui").completefunc(1, ""), 0)
		local completion_items = require("acp.ui").completefunc(0, "@con")
		eq(completion_items[1].word, "@context")
		eq(completion_items[1].user_data, "acp.nvim:context")

		local blink_source = acp_blink.new()
		ok(blink_source:enabled(), "ACP blink source should be enabled in the prompt buffer")
		local blink_result
		blink_source:get_completions({
			bufnr = input_buf,
			line = "@con",
			cursor = { 1, 4 },
			trigger = { kind = "manual" },
		}, function(result)
			blink_result = result
		end)
		ok(blink_result and blink_result.items and blink_result.items[1], "blink source should return prompt completions")
		eq(blink_result.items[1].label, ("%s @context"):format(icons.source))
		eq(blink_result.items[1].detail, "ACP workflow")
		eq(blink_result.items[1].labelDetails.detail, ("  %s ACP workflow"):format(icons.source))
		eq(blink_result.items[1].labelDetails.description, "source")
		ok(blink_result.items[1].documentation.value:find("context: source", 1, true))
		ok(blink_result.items[1].documentation.value:find(icons.source, 1, true))
		ok(blink_result.items[1].documentation.value:find("Insert the captured source context", 1, true))
		eq(blink_result.items[1].textEdit.newText, "@context")
		eq(blink_result.items[1].textEdit.range.start.character, 0)
		eq(blink_result.items[1].textEdit.range["end"].character, 4)
		eq(blink_result.items[1].data.acp_completion_scope, "ACP workflow")
		eq(blink_result.items[1].data.acp_complete_item.user_data, "acp.nvim:context")
		local blink_done = false
		blink_source:execute({
			bufnr = input_buf,
		}, blink_result.items[1], function()
			blink_done = true
		end)
		ok(blink_done, "blink execute should complete")
		local context_text = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(not context_text:find("@context", 1, true), "completion action should remove the trigger word")
		ok(context_text:find("Context", 1, true), "completion action should insert rendered context")
		ok(context_text:find("prompt_context_value", 1, true), "completion action should use the captured source")
		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

		local keys = vim.api.nvim_replace_termcodes("?", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local prompt_actions_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[prompt_actions_buf].filetype, "acp-prompt-actions")
		local prompt_actions_text = table.concat(vim.api.nvim_buf_get_lines(prompt_actions_buf, 0, -1, false), "\n")
		ok(prompt_actions_text:find("Add context", 1, true))
		ok(prompt_actions_text:find("Source diagnostics", 1, true))
		ok(prompt_actions_text:find("Code lens", 1, true))
		ok(prompt_actions_text:find("Rename symbol", 1, true))
		ok(prompt_actions_text:find("LSP highlights", 1, true))
		ok(prompt_actions_text:find("Tree-sitter nodes", 1, true))
		ok(prompt_actions_text:find("References quickfix", 1, true))
		ok(prompt_actions_text:find("Declarations quickfix", 1, true))
		ok(prompt_actions_text:find("Definitions quickfix", 1, true))
		ok(prompt_actions_text:find("Implementations quickfix", 1, true))
		ok(prompt_actions_text:find("Type definitions quickfix", 1, true))
		ok(prompt_actions_text:find("Workspace symbols quickfix", 1, true))
		ok(prompt_actions_text:find("Symbols quickfix", 1, true))
		ok(prompt_actions_text:find("Search output", 1, true))
		ok(prompt_actions_text:find("Output map", 1, true))

		local prompt_preview = false
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			local bufnr = vim.api.nvim_win_get_buf(winid)
			if bufnr ~= prompt_actions_buf and vim.bo[bufnr].buftype == "nofile" then
				local preview_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
				if preview_text:find("Prompt Actions", 1, true) and preview_text:find("Context Sources", 1, true) then
					prompt_preview = true
				end
			end
		end
		ok(prompt_preview, "prompt actions should show a context preview")
		keys = vim.api.nvim_replace_termcodes("q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local input_win = vim.fn.bufwinid(input_buf)
		if input_win ~= -1 then
			vim.api.nvim_set_current_win(input_win)
		end

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
	if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
		vim.diagnostic.reset(prompt_history_diag_ns, source_buf)
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
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
		ok(vim.wo[output_win].statuscolumn:find("acp_nvim_output_statuscolumn", 1, true))
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

		local function has_sign(mark, icon)
			return mark[4] and mark[4].sign_text and mark[4].sign_text:find(icon, 1, true) ~= nil
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
		local keys

		local ns = vim.api.nvim_create_namespace("acp.nvim.output")
		local marks = vim.api.nvim_buf_get_extmarks(output_buf, ns, 0, -1, { details = true })
		local highlighted_header = false
		local ghost_text = false
		local session_sign = false
		local activity_badge = false
		local skyline_hud = false
		for _, mark in ipairs(marks) do
			if mark[4] and mark[4].line_hl_group == "AcpOutputHeader" then
				highlighted_header = true
			end
			if has_sign(mark, icons.session) then
				session_sign = true
			end
			skyline_hud = skyline_hud or has_virt_line(mark, "FLOW")
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("Ready", 1, true) then
					ghost_text = true
				end
				if chunk[1] and chunk[1]:find("idle | 0 sections", 1, true) then
					activity_badge = true
				end
			end
		end
		ok(highlighted_header, "output header should be highlighted")
		ok(session_sign, "output session sign should be rendered")
		ok(ghost_text, "output ghost text should be rendered")
		ok(activity_badge, "output header should render activity badge")
		ok(skyline_hud, "output should render the skyline ghost HUD")

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
		local user_timeline = false
		for _, mark in ipairs(marks) do
			user_sign = user_sign or has_sign(mark, icons.user)
			agent_sign = agent_sign or has_sign(mark, icons.agent)
			error_sign = error_sign or has_sign(mark, icons.error)
			user_separator = user_separator or has_virt_line(mark, "---- USER: Prompt ----")
			agent_separator = agent_separator or has_virt_line(mark, "---- AGENT: Response ----")
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("1L | 2w", 1, true) then
					user_summary = true
				end
				if has_sign(mark, icons.user) and chunk[1] and chunk[1]:find("2/4", 1, true) then
					user_timeline = true
				end
			end
		end
		ok(user_sign, "output user sign should be rendered")
		ok(agent_sign, "output agent sign should be rendered")
		ok(error_sign, "output error sign should be rendered")
		ok(user_separator, "output user separator should be rendered")
		ok(agent_separator, "output agent separator should be rendered")
		ok(user_summary, "output section summary should be rendered")
		ok(user_timeline, "output section timeline should be rendered")
		local original_output_line_count = vim.api.nvim_buf_line_count(output_buf)
		vim.bo[output_buf].modifiable = true
		vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, {
			"",
			"Tool: shell",
			"",
			"Terminal: term-1",
			"",
			"Wrote lua/acp/init.lua",
			"",
		})
		vim.bo[output_buf].modifiable = false
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = output_buf })
		marks = vim.api.nvim_buf_get_extmarks(output_buf, ns, 0, -1, { details = true })
		local tool_activity_card = false
		local terminal_activity_card = false
		local file_activity_card = false
		for _, mark in ipairs(marks) do
			tool_activity_card = tool_activity_card or has_virt_line(mark, (" %s TOOL CALL "):format(icons.tool))
			terminal_activity_card = terminal_activity_card
				or has_virt_line(mark, (" %s TERMINAL "):format(icons.terminal))
			file_activity_card = file_activity_card or has_virt_line(mark, (" %s FILE WRITE "):format(icons.file))
		end
		ok(tool_activity_card, "tool output should render an activity card")
		ok(terminal_activity_card, "terminal output should render an activity card")
		ok(file_activity_card, "file writes should render an activity card")
		vim.bo[output_buf].modifiable = true
		vim.api.nvim_buf_set_lines(output_buf, original_output_line_count, -1, false, {})
		vim.bo[output_buf].modifiable = false
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = output_buf })
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
		ok(vim.wo[problem_preview_win].winbar:find("ACP output problem", 1, true))
		ok(vim.wo[problem_preview_win].winbar:find("q close", 1, true))
		eq(vim.b[vim.api.nvim_win_get_buf(problem_preview_win)].acp_output_inspector_syntax, "filetype")
		local problem_keymaps = vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(problem_preview_win), "n")
		local problem_has_close = false
		for _, keymap in ipairs(problem_keymaps) do
			if keymap.lhs == "q" then
				problem_has_close = true
				break
			end
		end
		ok(problem_has_close, "output inspector should map q to close")
		pcall(vim.api.nvim_win_close, problem_preview_win, true)
		vim.api.nvim_set_current_win(output_win)
		vim.cmd("AcpOutputActions")
		local output_actions_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[output_actions_buf].filetype, "acp-output-actions")
		local output_actions_text = table.concat(vim.api.nvim_buf_get_lines(output_actions_buf, 0, -1, false), "\n")
		ok(output_actions_text:find("Inspect item", 1, true))
		ok(output_actions_text:find("Output problems", 1, true))
		keys = vim.api.nvim_replace_termcodes("q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		vim.api.nvim_set_current_win(output_win)
		vim.cmd("AcpOutputProblems")
		local loclist = vim.fn.getloclist(output_win, { title = 1, items = 1 })
		ok(loclist.title:find("ACP output problems", 1, true))
		eq(#loclist.items, 1)
		ok(loclist.items[1].text:find("failed to start session", 1, true))
		vim.cmd("lclose")

		vim.api.nvim_set_current_win(output_win)
		vim.api.nvim_win_set_cursor(output_win, { 1, 0 })
		keys = vim.api.nvim_replace_termcodes("]]", true, false, true)
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
		local section_ribbon = false
		for _, mark in ipairs(hint_marks) do
			section_ribbon = section_ribbon or (has_virt_line(mark, "CTX") and has_virt_line(mark, "USER"))
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("<leader>ai draft", 1, true) then
					section_hint = true
					break
				end
			end
		end
		ok(section_hint, "output cursor should show section action hints")
		ok(section_ribbon, "output cursor should show a context ribbon")

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
		ok(search_lines[search_row]:find("%%", 1, false), "output search rows should include transcript progress")
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
		ok(outline:find("%%", 1, false))
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
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = output_buf })
		marks = vim.api.nvim_buf_get_extmarks(output_buf, ns, 0, -1, { details = true })
		local code_header = false
		local code_sign = false
		local code_badge = false
		local code_body_highlight = false
		local code_body_motion = false
		local code_injection_badge = false
		for _, mark in ipairs(marks) do
			if has_sign(mark, icons.code) then
				code_sign = true
			end
			if mark[2] == code_line - 1 and mark[4] and mark[4].line_hl_group == "AcpInjectedCode" then
				code_body_highlight = true
			end
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("lua->lua", 1, true) then
					code_badge = true
				end
				if mark[2] == code_line - 1 and chunk[1] and chunk[1]:find("[>   ]", 1, true) then
					code_body_motion = true
				end
				if mark[2] == code_line - 1 and chunk[1] and chunk[1]:find("INJECT", 1, true) then
					code_injection_badge = true
				end
			end
			for _, virt_line in ipairs((mark[4] and mark[4].virt_lines) or {}) do
				local rendered = {}
				for _, chunk in ipairs(virt_line) do
					table.insert(rendered, chunk[1] or "")
				end
				rendered = table.concat(rendered)
				if
					rendered:find("CODE lua", 1, true)
					and rendered:find("lua -> lua", 1, true)
					and (rendered:find("Tree-sitter injection", 1, true) or rendered:find("fence detection", 1, true))
				then
					code_header = true
				end
			end
		end
		ok(code_header, "output code blocks should render a virtual header")
		ok(code_sign, "output code blocks should render a sign marker")
		ok(code_badge, "output code blocks should render a language injection badge")
		ok(code_body_highlight, "output code bodies should render injected-language highlighting")
		ok(code_body_motion, "output code bodies should render an animated injection badge")
		ok(code_injection_badge, "output code bodies should render an injection-state badge")
		eq(vim.b[output_buf].acp_injected_languages[1], "lua")
		eq(vim.b[output_buf].acp_language_injections[1].filetype, "lua")
		eq(vim.b[output_buf].acp_language_injections[1].line1, code_line)
		vim.api.nvim_win_set_cursor(output_win, { code_line, 0 })
		vim.cmd("doautocmd CursorMoved")
		local code_hint_marks = vim.api.nvim_buf_get_extmarks(output_buf, hint_ns, 0, -1, { details = true })
		local code_hint = false
		for _, mark in ipairs(code_hint_marks) do
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if chunk[1] and chunk[1]:find("code lua", 1, true) then
					code_hint = true
					break
				end
			end
		end
		ok(code_hint, "output code blocks should show language-aware ghost hints")
		vim.cmd("AcpOutputInspect")
		local code_preview_win, code_preview = output_inspector_text("lua")
		ok(code_preview and code_preview:find("print('from acp')", 1, true), "output inspector should preview code blocks")
		ok(vim.wo[code_preview_win].winbar:find("lua lines", 1, true))
		ok(
			vim.b[vim.api.nvim_win_get_buf(code_preview_win)].acp_output_inspector_syntax == "treesitter"
				or vim.b[vim.api.nvim_win_get_buf(code_preview_win)].acp_output_inspector_syntax == "filetype"
		)
		pcall(vim.api.nvim_win_close, code_preview_win, true)
		unnamed_register = vim.fn.getreg('"')
		unnamed_register_type = vim.fn.getregtype('"')
		vim.cmd("AcpOutputActions")
		output_actions_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[output_actions_buf].filetype, "acp-output-actions")
		local action_lines = vim.api.nvim_buf_get_lines(output_actions_buf, 0, -1, false)
		local yank_code_row
		local code_quickfix_action = false
		for index, action_line in ipairs(action_lines) do
			if action_line:find("Code blocks quickfix", 1, true) then
				code_quickfix_action = true
			end
			if action_line:find("Yank code block", 1, true) then
				yank_code_row = index
			end
		end
		ok(yank_code_row, "output actions should include code-block actions")
		ok(code_quickfix_action, "output actions should include code-block quickfix")
		vim.api.nvim_win_set_cursor(0, { yank_code_row, 0 })
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.fn.getreg('"'), "print('from acp')\n")
		vim.fn.setreg('"', unnamed_register, unnamed_register_type)
		unnamed_register = nil
		unnamed_register_type = nil
		vim.api.nvim_set_current_win(output_win)
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
		ok(vim.wo[0].winbar:find("ACP lua code", 1, true))
		ok(vim.wo[0].winbar:find("<leader>at scope", 1, true))
		ok(vim.wo[0].winbar:find("<leader>ai draft", 1, true))
		ok(vim.wo[0].winbar:find("gO output", 1, true))
		ok(vim.wo[0].winbar:find("<leader>aY yank", 1, true))
		ok(
			vim.b[direct_code_buf].acp_code_block_syntax == "treesitter"
				or vim.b[direct_code_buf].acp_code_block_syntax == "filetype"
		)
		eq(vim.b[direct_code_buf].acp_output_source, output_buf)
		eq(vim.b[direct_code_buf].acp_output_source_line, code_line - 1)
		eq(vim.b[direct_code_buf].acp_output_source_end_line, code_line + 1)
		eq(vim.wo[0].number, true)
		eq(vim.wo[0].wrap, false)
		ok(vim.fn.maparg("<leader>aY", "n", false, true).buffer == 1)
		ok(vim.fn.maparg("<leader>at", "n", false, true).buffer == 1)
		ok(vim.fn.maparg("<leader>ai", "n", false, true).buffer == 1)
		ok(vim.fn.maparg("gO", "n", false, true).buffer == 1)
		ok(vim.fn.maparg("q", "n", false, true).buffer == 1)

		local scratch_tab = vim.api.nvim_get_current_tabpage()
		local return_map = vim.fn.maparg("gO", "n", false, true)
		ok(type(return_map.callback) == "function", "code scratch should expose output return callback")
		return_map.callback()
		eq(vim.api.nvim_get_current_win(), output_win)
		eq(
			vim.api.nvim_buf_get_lines(
				output_buf,
				vim.api.nvim_win_get_cursor(output_win)[1] - 1,
				vim.api.nvim_win_get_cursor(output_win)[1],
				false
			)[1],
			"```lua"
		)
		vim.api.nvim_set_current_tabpage(scratch_tab)
		local scratch_win = vim.fn.bufwinid(direct_code_buf)
		ok(scratch_win ~= -1, "code scratch window should remain open after returning to output")
		vim.api.nvim_set_current_win(scratch_win)

		local root = {}
		function root:type()
			return "chunk"
		end
		function root:range()
			return 0, 0, 0, 17
		end
		local child = {}
		function child:type()
			return "function_call"
		end
		function child:range()
			return 0, 0, 0, 17
		end
		function child:parent()
			return root
		end

		local original_treesitter = vim.treesitter
		local original_get_node = original_treesitter and original_treesitter.get_node
		local original_get_node_text = original_treesitter and original_treesitter.get_node_text
		vim.treesitter = vim.treesitter or {}
		vim.treesitter.get_node = function()
			return child
		end
		vim.treesitter.get_node_text = function()
			return "print('from acp')"
		end
		local scope_passed, scope_err = pcall(function()
			local scope_map = vim.fn.maparg("<leader>at", "n", false, true)
			ok(type(scope_map.callback) == "function", "code scratch should expose Tree-sitter scope callback")
			scope_map.callback()
			local scope_buf = vim.api.nvim_get_current_buf()
			eq(vim.bo[scope_buf].filetype, "acp-code-treesitter")
			local scope_text = table.concat(vim.api.nvim_buf_get_lines(scope_buf, 0, -1, false), "\n")
			ok(scope_text:find("ACP Code Tree%-sitter Scope"))
			ok(scope_text:find("function_call lines 1%-1"))
			keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
			vim.api.nvim_feedkeys(keys, "xt", false)
			eq(vim.api.nvim_get_current_buf(), direct_code_buf)
			eq(vim.api.nvim_win_get_cursor(0)[1], 1)

			vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
			local draft_map = vim.fn.maparg("<leader>ai", "n", false, true)
			ok(type(draft_map.callback) == "function", "code scratch should expose prompt draft callback")
			draft_map.callback()
			eq(vim.api.nvim_get_current_buf(), input_buf)
			local code_prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
			ok(code_prompt:find("Use this Tree%-sitter scope from an ACP output code block", 1, false))
			ok(code_prompt:find("Origin: output lines", 1, true))
			ok(code_prompt:find("Scope: function_call lines 1%-1", 1, false))
			ok(code_prompt:find("Tree%-sitter text:", 1, false))
			ok(code_prompt:find("print%('from acp'%)", 1, false))
			ok(code_prompt:find("Request:", 1, true))
			vim.api.nvim_set_current_tabpage(scratch_tab)
			vim.api.nvim_set_current_win(scratch_win)
		end)
		if original_treesitter then
			vim.treesitter.get_node = original_get_node
			vim.treesitter.get_node_text = original_get_node_text
		else
			vim.treesitter = nil
		end
		if not scope_passed then
			error(scope_err, 2)
		end
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
		keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local code_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(code_qflist.title:find("ACP output code blocks", 1, true))
		eq(#code_qflist.items, 1)
		eq(code_qflist.items[1].bufnr, output_buf)
		ok(code_qflist.items[1].text:find("CODE lua lines", 1, true))
		vim.cmd("cclose")

		vim.api.nvim_set_current_win(output_win)
		vim.cmd("AcpCodeBlocksQuickfix")
		code_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(code_qflist.title:find("ACP output code blocks", 1, true))
		eq(#code_qflist.items, 1)
		vim.cmd("cclose")

		vim.api.nvim_set_current_win(output_win)
		vim.cmd("AcpCodeBlocks")
		picker_buf = vim.api.nvim_get_current_buf()
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
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = output_buf })
		marks = vim.api.nvim_buf_get_extmarks(output_buf, ns, 0, -1, { details = true })
		local ref_highlight = false
		local ref_badge = false
		local ref_sign = false
		for _, mark in ipairs(marks) do
			if mark[2] == ref_line - 1 and mark[3] == ref_col and mark[4] and mark[4].hl_group == "AcpOutputReference" then
				ref_highlight = true
			end
			if mark[2] == ref_line - 1 and has_sign(mark, icons.reference) then
				ref_sign = true
			end
			for _, chunk in ipairs((mark[4] and mark[4].virt_text) or {}) do
				if mark[2] == ref_line - 1 and chunk[1] and chunk[1]:find("REF", 1, true) then
					ref_badge = true
				end
			end
		end
		ok(ref_highlight, "output references should be highlighted inline")
		ok(ref_sign, "output references should render a sign marker")
		ok(ref_badge, "output references should render a badge")
		vim.cmd("AcpOutputMap")
		local map_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[map_buf].filetype, "acp-output-map")
		local output_map = vim.api.nvim_buf_get_lines(map_buf, 0, -1, false)
		local output_map_text = table.concat(output_map, "\n")
		ok(output_map_text:find("ACP Output Map", 1, true))
		ok(output_map_text:find("Entries:", 1, true))
		ok(output_map_text:find("[", 1, true))
		ok(output_map_text:find("PROBLEM", 1, true))
		ok(output_map_text:find("CODE", 1, true))
		ok(output_map_text:find("REFERENCE", 1, true))
		eq(vim.fn.maparg("K", "n", false, true).desc, "Preview ACP output map entry")
		eq(vim.fn.maparg("Q", "n", false, true).desc, "Open ACP output map quickfix")
		local map_code_row
		for index, map_line in ipairs(output_map) do
			if map_line:find("CODE", 1, true) then
				map_code_row = index
				break
			end
		end
		ok(map_code_row, "output map should include code rows")
		vim.api.nvim_win_set_cursor(0, { map_code_row, 0 })
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_win(), output_win)
		eq(vim.api.nvim_buf_get_lines(output_buf, vim.api.nvim_win_get_cursor(output_win)[1] - 1, vim.api.nvim_win_get_cursor(output_win)[1], false)[1], "```lua")
		vim.cmd("AcpOutputMap")
		eq(vim.api.nvim_get_current_buf(), map_buf)
		keys = vim.api.nvim_replace_termcodes("q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		ok(not vim.api.nvim_buf_is_valid(map_buf), "output map should close with q")
		vim.api.nvim_set_current_win(output_win)
		vim.cmd("AcpOutputItems")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-output-items")
		local item_picker_lines = vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false)
		local output_items_text = table.concat(item_picker_lines, "\n")
		ok(output_items_text:find("ACP Output Items", 1, true))
		ok(output_items_text:find("PROBLEM", 1, true))
		ok(output_items_text:find("CODE", 1, true))
		ok(output_items_text:find("REFERENCE", 1, true))
		local code_item_row
		for index, item_line in ipairs(item_picker_lines) do
			if item_line:find("CODE", 1, true) then
				code_item_row = index
				break
			end
		end
		ok(code_item_row, "output item picker should include code rows")
		vim.api.nvim_win_set_cursor(0, { code_item_row, 0 })
		vim.cmd("doautocmd CursorMoved")
		local item_preview = false
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			local preview_bufnr = vim.api.nvim_win_get_buf(winid)
			if preview_bufnr ~= picker_buf and vim.bo[preview_bufnr].buftype == "nofile" and vim.bo[preview_bufnr].filetype == "lua" then
				local preview = table.concat(vim.api.nvim_buf_get_lines(preview_bufnr, 0, -1, false), "\n")
				if preview:find("print('from acp')", 1, true) then
					item_preview = true
					break
				end
			end
		end
		ok(item_preview, "output item picker should preview code blocks")
		keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local item_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(item_qflist.title:find("ACP output items", 1, true))
		ok(#item_qflist.items >= 3)
		eq(item_qflist.items[1].bufnr, output_buf)
		ok(item_qflist.items[1].text:find("PROBLEM", 1, true))
		vim.cmd("cclose")
		vim.api.nvim_set_current_win(output_win)
		vim.cmd("AcpOutputItems")
		picker_buf = vim.api.nvim_get_current_buf()
		item_picker_lines = vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false)
		code_item_row = nil
		for index, item_line in ipairs(item_picker_lines) do
			if item_line:find("CODE", 1, true) then
				code_item_row = index
				break
			end
		end
		ok(code_item_row, "output item picker should include code rows after quickfix export")
		vim.api.nvim_win_set_cursor(0, { code_item_row, 0 })
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_win(), output_win)
		eq(vim.api.nvim_buf_get_lines(output_buf, vim.api.nvim_win_get_cursor(output_win)[1] - 1, vim.api.nvim_win_get_cursor(output_win)[1], false)[1], "```lua")
		vim.api.nvim_win_set_cursor(output_win, { problem_line, 0 })
		vim.cmd("AcpOutputNextItem")
		local item_line = vim.api.nvim_win_get_cursor(output_win)[1]
		eq(vim.api.nvim_buf_get_lines(output_buf, item_line - 1, item_line, false)[1], "```lua")
		ok(vim.wo[output_win].winbar:find("item 2/", 1, true))
		ok(vim.wo[output_win].winbar:find("CODE", 1, true))
		local current_item_ns = vim.api.nvim_create_namespace("acp.nvim.output.current_item")
		local item_marks = vim.api.nvim_buf_get_extmarks(output_buf, current_item_ns, 0, -1, { details = true })
		local highlighted_code_lines = 0
		for _, mark in ipairs(item_marks) do
			if mark[4] and mark[4].line_hl_group == "AcpCurrentItem" then
				highlighted_code_lines = highlighted_code_lines + 1
			end
		end
		eq(highlighted_code_lines, 3)
		vim.cmd("AcpOutputNextItem")
		eq(vim.api.nvim_win_get_cursor(output_win)[1], ref_line)
		ok(vim.wo[output_win].winbar:find("REFERENCE", 1, true))
		item_marks = vim.api.nvim_buf_get_extmarks(output_buf, current_item_ns, 0, -1, { details = true })
		eq(#item_marks, 1)
		vim.cmd("AcpOutputPrevItem")
		item_line = vim.api.nvim_win_get_cursor(output_win)[1]
		eq(vim.api.nvim_buf_get_lines(output_buf, item_line - 1, item_line, false)[1], "```lua")
		vim.api.nvim_win_set_cursor(output_win, { ref_line, ref_col })
		vim.cmd("AcpOutputInspect")
		local ref_preview_win, ref_preview = output_inspector_text("lua")
		ok(ref_preview and ref_preview:find("local M = {}", 1, true), "output inspector should preview file references")
		ok(vim.wo[ref_preview_win].winbar:find("lua/acp/output.lua:1", 1, true))
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
	vim.api.nvim_buf_call(session_buf, function()
		local close_map = vim.fn.maparg("x", "n", false, true)
		eq(close_map.desc, "Close ACP session")
	end)

	vim.api.nvim_set_current_win(source_win)
	vim.cmd("AcpSessions")
	local picker_buf = vim.api.nvim_get_current_buf()
	eq(vim.bo[picker_buf].filetype, "acp-sessions")
	local text = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
	ok(text:find("ACP Sessions", 1, true))
	ok(text:find("test", 1, true))
	local preview_found = false
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		local bufnr = vim.api.nvim_win_get_buf(winid)
		if bufnr ~= picker_buf and vim.bo[bufnr].buftype == "nofile" then
			local preview = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
			if preview:find("ACP Session Preview", 1, true) and preview:find("No transcript output yet", 1, true) then
				preview_found = true
			end
		end
	end
	ok(preview_found, "session picker should show a transcript preview")

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
		local output_map = false
		local output_items = false
		local output_items_quickfix = false
		local inspect_output = false
		local output_actions = false
		local code_blocks_quickfix = false
		local yank_code_block = false
		local diagnostics_quickfix = false
		local smart_context_action = false
		local signature_help = false
		local inlay_hints_action = false
		local selection_ranges_action = false
		local lsp_highlight_action = false
		local callers_quickfix = false
		local callees_quickfix = false
		local supertypes_quickfix = false
		local subtypes_quickfix = false
		local references_quickfix = false
		local declarations_quickfix = false
		local definitions_quickfix = false
		local implementations_quickfix = false
		local type_definitions_quickfix = false
		local workspace_symbols_quickfix = false
		local symbols_quickfix = false
		local workspace_diagnostics = false
		local workspace_diagnostics_quickfix = false
		local code_lens_action = false
		local code_lens_quickfix = false
		local document_colors_action = false
		local document_colors_quickfix = false
		local clear_document_colors = false
		local document_links_action = false
		local document_links_quickfix = false
		local clear_document_links = false
		local folding_ranges_action = false
		local folding_ranges_quickfix = false
		local clear_folding_ranges = false
		local rename_action = false
		local close_session = false
		for index, line in ipairs(action_lines) do
			if line:find("Output outline", 1, true) then
				output_outline_row = index
			end
			if line:find("Output map", 1, true) then
				output_map = true
			end
			if line:find("Output items", 1, true) then
				output_items = true
			end
			if line:find("Output items quickfix", 1, true) then
				output_items_quickfix = true
			end
			if line:find("Inspect output item", 1, true) then
				inspect_output = true
			end
			if line:find("Output actions", 1, true) then
				output_actions = true
			end
			if line:find("Code blocks quickfix", 1, true) then
				code_blocks_quickfix = true
			end
			if line:find("Yank code block", 1, true) then
				yank_code_block = true
			end
			if line:find("Diagnostics quickfix", 1, true) then
				diagnostics_quickfix = true
			end
			if line:find("Workspace diagnostics", 1, true) then
				workspace_diagnostics = true
			end
			if line:find("Workspace diagnostics quickfix", 1, true) then
				workspace_diagnostics_quickfix = true
			end
			if line:find("Smart context", 1, true) then
				smart_context_action = true
			end
			if line:find("Code lens", 1, true) then
				code_lens_action = true
			end
			if line:find("Code lens quickfix", 1, true) then
				code_lens_quickfix = true
			end
			if line:find("Document colors", 1, true) then
				document_colors_action = true
			end
			if line:find("Document colors quickfix", 1, true) then
				document_colors_quickfix = true
			end
			if line:find("Clear document colors", 1, true) then
				clear_document_colors = true
			end
			if line:find("Document links", 1, true) then
				document_links_action = true
			end
			if line:find("Document links quickfix", 1, true) then
				document_links_quickfix = true
			end
			if line:find("Clear document links", 1, true) then
				clear_document_links = true
			end
			if line:find("Folding ranges", 1, true) then
				folding_ranges_action = true
			end
			if line:find("Folding ranges quickfix", 1, true) then
				folding_ranges_quickfix = true
			end
			if line:find("Clear folding ranges", 1, true) then
				clear_folding_ranges = true
			end
			if line:find("Rename symbol", 1, true) then
				rename_action = true
			end
			if line:find("Signature help", 1, true) then
				signature_help = true
			end
			if line:find("Inlay hints", 1, true) then
				inlay_hints_action = true
			end
			if line:find("Selection ranges", 1, true) then
				selection_ranges_action = true
			end
			if line:find("LSP highlights", 1, true) then
				lsp_highlight_action = true
			end
			if line:find("Callers quickfix", 1, true) then
				callers_quickfix = true
			end
			if line:find("Callees quickfix", 1, true) then
				callees_quickfix = true
			end
			if line:find("Supertypes quickfix", 1, true) then
				supertypes_quickfix = true
			end
			if line:find("Subtypes quickfix", 1, true) then
				subtypes_quickfix = true
			end
			if line:find("References quickfix", 1, true) then
				references_quickfix = true
			end
			if line:find("Declarations quickfix", 1, true) then
				declarations_quickfix = true
			end
			if line:find("Definitions quickfix", 1, true) then
				definitions_quickfix = true
			end
			if line:find("Implementations quickfix", 1, true) then
				implementations_quickfix = true
			end
			if line:find("Type definitions quickfix", 1, true) then
				type_definitions_quickfix = true
			end
			if line:find("Workspace symbols quickfix", 1, true) then
				workspace_symbols_quickfix = true
			end
			if line:find("Symbols quickfix", 1, true) then
				symbols_quickfix = true
			end
			if line:find("Close session", 1, true) then
				close_session = true
			end
		end
		ok(output_outline_row, "action palette should include output outline")
		ok(output_map, "action palette should include output map")
		ok(output_items, "action palette should include output items")
		ok(output_items_quickfix, "action palette should include output item quickfix")
		ok(inspect_output, "action palette should include output inspect")
		ok(output_actions, "action palette should include output actions")
		ok(code_blocks_quickfix, "action palette should include code blocks quickfix")
		ok(yank_code_block, "action palette should include code block yank")
		ok(diagnostics_quickfix, "action palette should include diagnostics quickfix")
		ok(workspace_diagnostics, "action palette should include workspace diagnostics")
		ok(workspace_diagnostics_quickfix, "action palette should include workspace diagnostics quickfix")
		ok(smart_context_action, "action palette should include smart context")
		ok(code_lens_action, "action palette should include code lens")
		ok(code_lens_quickfix, "action palette should include code lens quickfix")
		ok(document_colors_action, "action palette should include document colors")
		ok(document_colors_quickfix, "action palette should include document colors quickfix")
		ok(clear_document_colors, "action palette should include clear document colors")
		ok(document_links_action, "action palette should include document links")
		ok(document_links_quickfix, "action palette should include document links quickfix")
		ok(clear_document_links, "action palette should include clear document links")
		ok(folding_ranges_action, "action palette should include folding ranges")
		ok(folding_ranges_quickfix, "action palette should include folding ranges quickfix")
		ok(clear_folding_ranges, "action palette should include clear folding ranges")
		ok(rename_action, "action palette should include rename")
		ok(signature_help, "action palette should include signature help")
		ok(inlay_hints_action, "action palette should include inlay hints")
		ok(selection_ranges_action, "action palette should include selection ranges")
		ok(lsp_highlight_action, "action palette should include LSP highlights")
		ok(callers_quickfix, "action palette should include callers quickfix")
		ok(callees_quickfix, "action palette should include callees quickfix")
		ok(supertypes_quickfix, "action palette should include supertypes quickfix")
		ok(subtypes_quickfix, "action palette should include subtypes quickfix")
		ok(references_quickfix, "action palette should include references quickfix")
		ok(declarations_quickfix, "action palette should include declarations quickfix")
		ok(definitions_quickfix, "action palette should include definitions quickfix")
		ok(implementations_quickfix, "action palette should include implementations quickfix")
		ok(type_definitions_quickfix, "action palette should include type definitions quickfix")
		ok(workspace_symbols_quickfix, "action palette should include workspace symbols quickfix")
		ok(symbols_quickfix, "action palette should include symbols quickfix")
		ok(close_session, "action palette should include close session")

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

		local source_win = vim.fn.bufwinid(source_buf)
		ok(source_win ~= -1, "source buffer should remain visible")
		vim.api.nvim_set_current_win(source_win)
		vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
		vim.cmd("AcpRefreshSource")
		marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		eq(#marks, 1)
		eq(marks[1][2] + 1, 3)

		vim.cmd("AcpSourceActions")
		local source_actions_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[source_actions_buf].filetype, "acp-source-actions")
		local action_lines = vim.api.nvim_buf_get_lines(source_actions_buf, 0, -1, false)
		local actions_text = table.concat(action_lines, "\n")
		ok(actions_text:find("Focus chat", 1, true))
		ok(actions_text:find("Add marked context", 1, true))
		ok(actions_text:find("Refresh source", 1, true))
		ok(actions_text:find("LSP highlights", 1, true))
		ok(actions_text:find("Tree-sitter nodes", 1, true))
		ok(actions_text:find("References quickfix", 1, true))
		ok(actions_text:find("Declarations quickfix", 1, true))
		ok(actions_text:find("Definitions quickfix", 1, true))
		ok(actions_text:find("Implementations quickfix", 1, true))
		ok(actions_text:find("Type definitions quickfix", 1, true))
		ok(actions_text:find("Workspace symbols quickfix", 1, true))
		ok(actions_text:find("Symbols quickfix", 1, true))
		ok(actions_text:find("Search output", 1, true))
		ok(actions_text:find("Output map", 1, true))

		local preview_found = false
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			local bufnr = vim.api.nvim_win_get_buf(winid)
			if bufnr ~= source_actions_buf and vim.bo[bufnr].buftype == "nofile" then
				local preview = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
				if preview:find("print(value + other)", 1, true) then
					preview_found = true
				end
			end
		end
		ok(preview_found, "source actions should show source preview")

		local add_context_row
		for index, line in ipairs(action_lines) do
			if line:find("Add marked context", 1, true) then
				add_context_row = index
				break
			end
		end
		ok(add_context_row, "source action picker should include add context row")
		vim.api.nvim_win_set_cursor(0, { add_context_row, 0 })
		local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)
		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Context", 1, true))
		ok(prompt:find("print(value + other)", 1, true))

		vim.cmd("AcpClose")
		marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		eq(#marks, 0)
		input_buf = nil
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

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qflist.title:find("ACP diagnostics", 1, true))
		eq(#qflist.items, 1)
		eq(qflist.items[1].bufnr, source_buf)
		ok(qflist.items[1].text:find("undefined global missing", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after diagnostics quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpDiagnosticsQuickfix")
		qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qflist.title:find("ACP diagnostics", 1, true))
		eq(#qflist.items, 1)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpDiagnostics")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
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

test("workspace diagnostics command drafts selected loaded-buffer diagnostic context", function()
	local source_buf = vim.api.nvim_create_buf(true, false)
	local other_buf = vim.api.nvim_create_buf(true, false)
	vim.bo[source_buf].swapfile = false
	vim.bo[other_buf].swapfile = false
	vim.api.nvim_buf_set_name(source_buf, vim.fn.tempname() .. "-workspace-source.lua")
	vim.api.nvim_buf_set_name(other_buf, vim.fn.tempname() .. "-workspace-other.lua")
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local source_value = missing_source",
		"print(source_value)",
	})
	vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, {
		"local other = missing_other",
		"return other",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.bo[other_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)

	local ns = vim.api.nvim_create_namespace("acp.nvim.test.workspace-diagnostic-picker")
	vim.diagnostic.set(ns, source_buf, {
		{
			lnum = 0,
			col = 21,
			end_lnum = 0,
			end_col = 35,
			severity = vim.diagnostic.severity.WARN,
			message = "workspace source warning",
			source = "lua_ls",
		},
	})
	vim.diagnostic.set(ns, other_buf, {
		{
			lnum = 0,
			col = 14,
			end_lnum = 0,
			end_col = 27,
			severity = vim.diagnostic.severity.ERROR,
			message = "workspace other error",
			source = "lua_ls",
			code = "undefined-global",
		},
	})

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpWorkspaceDiagnostics")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-workspace-diagnostics")
		local picker_text = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
		ok(picker_text:find("workspace%-other%.lua:1:15 ERROR", 1, false))
		ok(picker_text:find("workspace source warning", 1, true))

		local preview_found = false
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			local bufnr = vim.api.nvim_win_get_buf(winid)
			if bufnr ~= picker_buf and vim.bo[bufnr].buftype == "nofile" and vim.bo[bufnr].filetype == "lua" then
				local preview = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
				if preview:find("local other = missing_other", 1, true) then
					preview_found = true
					break
				end
			end
		end
		ok(preview_found, "workspace diagnostics picker should preview the selected buffer")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qflist.title:find("ACP workspace diagnostics", 1, true))
		eq(#qflist.items, 2)
		eq(qflist.items[1].bufnr, other_buf)
		ok(qflist.items[1].text:find("workspace other error", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after workspace diagnostics quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpWorkspaceDiagnosticsQuickfix")
		qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qflist.title:find("ACP workspace diagnostics", 1, true))
		eq(#qflist.items, 2)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpWorkspaceDiagnostics")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Fix this diagnostic. Keep the change focused", 1, true))
		ok(prompt:find("workspace other error", 1, true))
		ok(prompt:find("local other = missing_other", 1, true))
		ok(prompt:find("ERROR [lua_ls] (undefined-global): workspace other error", 1, true))
	end)

	vim.diagnostic.reset(ns, source_buf)
	vim.diagnostic.reset(ns, other_buf)
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(other_buf) then
		pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
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

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local symbol_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(symbol_qflist.title:find("ACP symbols", 1, true))
		eq(#symbol_qflist.items, 1)
		eq(symbol_qflist.items[1].bufnr, source_buf)
		eq(symbol_qflist.items[1].lnum, 1)
		eq(symbol_qflist.items[1].col, 1)
		ok(symbol_qflist.items[1].text:find("SYMBOL: add %(Function%)"))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after symbols quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpSymbolsQuickfix")
		symbol_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(symbol_qflist.title:find("ACP symbols", 1, true))
		eq(#symbol_qflist.items, 1)
		eq(symbol_qflist.items[1].lnum, 1)
		eq(symbol_qflist.items[1].col, 1)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible before symbol draft")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpSymbols")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-symbols")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
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

test("code lens command drafts selected LSP code-lens context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local function test_value()",
		"  return 1",
		"end",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })

	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/codeLens")
		eq(params.textDocument.uri, vim.uri_from_bufnr(source_buf))
		callback({
			[1] = {
				result = {
					{
						range = {
							start = { line = 0, character = 0 },
							["end"] = { line = 0, character = 25 },
						},
						command = {
							title = "Run file tests",
							command = "test.runFile",
						},
					},
					{
						range = {
							start = { line = 1, character = 2 },
							["end"] = { line = 1, character = 10 },
						},
						command = {
							title = "Debug nearest test",
							command = "test.debugNearest",
							arguments = { "nearest" },
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
		vim.cmd("AcpCodeLens")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-code-lens")
		local picker_text = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
		ok(picker_text:find("Run file tests", 1, true))
		ok(picker_text:find("Debug nearest test", 1, true))

		local preview_found = false
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			local bufnr = vim.api.nvim_win_get_buf(winid)
			if bufnr ~= picker_buf and vim.bo[bufnr].buftype == "nofile" and vim.bo[bufnr].filetype == "lua" then
				local preview = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
				if preview:find("local function test_value", 1, true) then
					preview_found = true
					break
				end
			end
		end
		ok(preview_found, "code lens picker should show a source preview")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qflist.title:find("ACP code lens", 1, true))
		eq(#qflist.items, 2)
		ok(qflist.items[1].text:find("Run file tests", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after code lens quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpCodeLensQuickfix")
		qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qflist.title:find("ACP code lens", 1, true))
		eq(#qflist.items, 2)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpCodeLens")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP code lens as context: Run file tests.", 1, true))
		ok(prompt:find("Command: test.runFile", 1, true))
		ok(prompt:find("Selection: lines 1-1", 1, true))
		ok(prompt:find("local function test_value", 1, true))
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

test("rename command drafts selected LSP prepare-rename context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local old_name = 1",
		"print(old_name)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 8 })

	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/prepareRename")
		eq(params.position.line, 0)
		eq(params.position.character, 8)
		callback({
			[1] = {
				result = {
					range = {
						start = { line = 0, character = 6 },
						["end"] = { line = 0, character = 14 },
					},
					placeholder = "old_name",
				},
			},
		})
		return {
			[1] = 1,
		}
	end

	local original_ui_input = vim.ui.input
	local input_opts
	vim.ui.input = function(opts, callback)
		input_opts = opts
		callback("new_name")
	end

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpRename")
		ok(input_opts.prompt:find("old_name", 1, true))
		eq(input_opts.default, "old_name")
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Rename this symbol to `new_name`", 1, true))
		ok(prompt:find("Current name: old_name", 1, true))
		ok(prompt:find("New name: new_name", 1, true))
		ok(prompt:find("Range: lines 1%-1"))
		ok(prompt:find("Selection: lines 1-1", 1, true))
		ok(prompt:find("local old_name = 1", 1, true))
	end)

	vim.ui.input = original_ui_input
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

test("smart context command drafts combined editor and LSP context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	local source_line = "local result = add(a, b)"
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		source_line,
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 19 })

	local seen = {}
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		seen[method] = true
		if method == "textDocument/hover" then
			eq(params.position.line, 0)
			eq(params.position.character, 19)
			callback({
				[1] = {
					result = {
						contents = {
							kind = "markdown",
							value = "`add`: function",
						},
					},
				},
			})
		elseif method == "textDocument/signatureHelp" then
			eq(params.position.line, 0)
			eq(params.position.character, 19)
			callback({
				[1] = {
					result = {
						activeSignature = 0,
						signatures = {
							{
								label = "add(left: number, right: number): number",
								parameters = {
									{ label = "left" },
									{ label = "right" },
								},
							},
						},
					},
				},
			})
		elseif method == "textDocument/inlayHint" then
			eq(params.range.start.line, 0)
			eq(params.range.start.character, 0)
			eq(params.range["end"].line, 0)
			eq(params.range["end"].character, #source_line)
			callback({
				[1] = {
					result = {
						{ position = { line = 0, character = 19 }, kind = 2, label = "left:" },
						{ position = { line = 0, character = 22 }, kind = 1, label = ": number" },
					},
				},
			})
		elseif method == "textDocument/selectionRange" then
			eq(params.positions[1].line, 0)
			eq(params.positions[1].character, 19)
			callback({
				[1] = {
					result = {
						{
							range = {
								start = { line = 0, character = 15 },
								["end"] = { line = 0, character = 21 },
							},
						},
					},
				},
			})
		else
			error("unexpected LSP method: " .. tostring(method))
		end
		return {
			[1] = 1,
		}
	end

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpSmartContext")
		eq(vim.api.nvim_get_current_buf(), input_buf)
		ok(seen["textDocument/hover"], "smart context should request hover")
		ok(seen["textDocument/signatureHelp"], "smart context should request signature help")
		ok(seen["textDocument/inlayHint"], "smart context should request inlay hints")
		ok(seen["textDocument/selectionRange"], "smart context should request selection ranges")

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this smart editor context", 1, true))
		ok(prompt:find("Line: local result = add%(a, b%)"))
		ok(prompt:find("Hover:\n`add`: function", 1, true))
		ok(prompt:find("Signature help:\nSignature: add%(left: number, right: number%): number"))
		ok(prompt:find("Inlay hints:\n- 1:20 PARAM left:", 1, true))
		ok(prompt:find("- 1:23 TYPE : number", 1, true))
		ok(prompt:find("Selection ranges:\n- cursor expression lines 1-1", 1, true))
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

test("signature command drafts LSP signature help context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local result = join(left, right)",
		"print(result)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 20 })

	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/signatureHelp")
		eq(params.position.line, 0)
		eq(params.position.character, 20)
		callback({
			[1] = {
				result = {
					activeSignature = 0,
					activeParameter = 1,
					signatures = {
						{
							label = "join(left: string, right: string): string",
							documentation = "Join two strings.",
							parameters = {
								{ label = "left" },
								{ label = "right", documentation = "Right value." },
							},
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
		vim.cmd("AcpSignature")
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP signature help as context.", 1, true))
		ok(prompt:find("Signature help:", 1, true))
		ok(prompt:find("Signature: join%(left: string, right: string%): string"))
		ok(prompt:find("* right", 1, true))
		ok(prompt:find("Right value.", 1, true))
		ok(prompt:find("Line: local result = join%(left, right%)"))
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

test("inlay hints command drafts selected LSP inlay-hint context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	local source_line = "local result = add(a, b)"
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		source_line,
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 19 })

	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/inlayHint")
		eq(params.range.start.line, 0)
		eq(params.range.start.character, 0)
		eq(params.range["end"].line, 0)
		eq(params.range["end"].character, #source_line)
		callback({
			[1] = {
				result = {
					{
						position = { line = 0, character = 19 },
						kind = 2,
						label = "left:",
					},
					{
						position = { line = 0, character = 22 },
						kind = 1,
						label = {
							{ value = ": number" },
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
		vim.cmd("AcpInlayHints")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-inlay-hints")
		local picker_text = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
		ok(picker_text:find("All inlay hints", 1, true))
		ok(picker_text:find("left:", 1, true))
		ok(picker_text:find(": number", 1, true))

		local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use these LSP inlay hints as context.", 1, true))
		ok(prompt:find("Inlay hints:", 1, true))
		ok(prompt:find("- 1:20 PARAM left:", 1, true))
		ok(prompt:find("- 1:23 TYPE : number", 1, true))
		ok(prompt:find("Selection: lines 1%-1", 1, false))
		ok(prompt:find("Line: local result = add%(a, b%)"))
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

test("selection ranges command drafts selected LSP semantic range context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local function add(a, b)",
		"  if a then",
		"    return a + b",
		"  end",
		"end",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 3, 13 })

	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/selectionRange")
		eq(params.positions[1].line, 2)
		eq(params.positions[1].character, 13)
		callback({
			[1] = {
				result = {
					{
						range = {
							start = { line = 2, character = 11 },
							["end"] = { line = 2, character = 16 },
						},
						parent = {
							range = {
								start = { line = 1, character = 2 },
								["end"] = { line = 3, character = 5 },
							},
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
		vim.cmd("AcpSelectionRanges")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-selection-ranges")
		local picker_text = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
		ok(picker_text:find("cursor expression", 1, true))
		ok(picker_text:find("semantic block", 1, true))

		local keys = vim.api.nvim_replace_termcodes("j<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP selection range as context: semantic block.", 1, true))
		ok(prompt:find("Selection: lines 2%-4 %(3 line%(s%)%)"))
		ok(prompt:find("Selected text:", 1, true))
		ok(prompt:find("  if a then", 1, true))
		ok(prompt:find("    return a %+ b"))
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

test("highlights command renders and clears LSP document highlights", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local value = 1",
		"value = value + 1",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 2, 0 })

	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/documentHighlight")
		eq(params.position.line, 1)
		eq(params.position.character, 0)
		callback({
			[1] = {
				result = {
					{
						kind = 3,
						range = {
							start = { line = 1, character = 0 },
							["end"] = { line = 1, character = 5 },
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
		vim.cmd("AcpHighlights")

		local ns = vim.api.nvim_create_namespace("acp.nvim.source")
		local marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		local highlight_found = false
		local lens_found = false
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			if details.hl_group == "AcpSourceHighlightWrite" then
				highlight_found = true
				eq(mark[2] + 1, 2)
				eq(mark[3], 0)
				eq(details.end_col, 5)
			end
			for _, line in ipairs(details.virt_lines or {}) do
				for _, chunk in ipairs(line) do
					if chunk[1] and chunk[1]:find("highlights 1", 1, true) then
						lens_found = true
					end
				end
			end
		end
		ok(highlight_found, "AcpHighlights should render LSP write range")
		ok(lens_found, "source lens should include highlight count")

		vim.cmd("AcpClearHighlights")
		marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			ok(details.hl_group ~= "AcpSourceHighlightWrite", "AcpClearHighlights should clear LSP highlight marks")
		end
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

test("document colors command renders swatches, quickfix, and prompt context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local color = '#336699'",
		"return color",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 15 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/documentColor")
		eq(params.textDocument.uri, uri)
		callback({
			[1] = {
				result = {
					{
						range = {
							start = { line = 0, character = 15 },
							["end"] = { line = 0, character = 22 },
						},
						color = {
							red = 0.2,
							green = 0.4,
							blue = 0.6,
							alpha = 1,
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
	local input_win
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		input_win = vim.api.nvim_get_current_win()
		vim.cmd("AcpDocumentColors")

		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-document-colors")
		local picker_text = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
		ok(picker_text:find("ACP Document Colors", 1, true))
		ok(picker_text:find("#336699", 1, true))

		local ns = vim.api.nvim_create_namespace("acp.nvim.source")
		local marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		local color_range_found = false
		local color_badge_found = false
		local lens_found = false
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			if details.hl_group == "AcpSourceColorRange" then
				color_range_found = true
				eq(mark[2] + 1, 1)
				eq(mark[3], 15)
				eq(details.end_col, 22)
			end
			for _, chunk in ipairs(details.virt_text or {}) do
				if chunk[1] and chunk[1]:find("COLOR #336699", 1, true) then
					color_badge_found = true
					ok(details.sign_text and details.sign_text:find(icons.color, 1, true))
				end
			end
			for _, line in ipairs(details.virt_lines or {}) do
				for _, chunk in ipairs(line) do
					if chunk[1] and chunk[1]:find("colors 1", 1, true) then
						lens_found = true
					end
				end
			end
		end
		ok(color_range_found, "AcpDocumentColors should render the color range")
		ok(color_badge_found, "AcpDocumentColors should render a color swatch badge")
		ok(lens_found, "source lens should include document color count")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local qf = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qf.title:find("ACP document colors", 1, true))
		eq(#qf.items, 1)
		ok(qf.items[1].text:find("DOCUMENT COLOR: #336699", 1, true))
		vim.cmd("cclose")

		if input_win and vim.api.nvim_win_is_valid(input_win) then
			vim.api.nvim_set_current_win(input_win)
		end
		vim.cmd("AcpDocumentColorsQuickfix")
		qf = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qf.title:find("ACP document colors", 1, true))
		eq(#qf.items, 1)
		vim.cmd("cclose")

		if input_win and vim.api.nvim_win_is_valid(input_win) then
			vim.api.nvim_set_current_win(input_win)
		end
		vim.cmd("AcpDocumentColors")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)
		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP document color as context: #336699.", 1, true))
		ok(prompt:find("Document color:", 1, true))
		ok(prompt:find("Selection: lines 1-1", 1, true))
		ok(prompt:find("local color = '#336699'", 1, true))

		vim.cmd("AcpClearDocumentColors")
		marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			ok(details.hl_group ~= "AcpSourceColorRange", "AcpClearDocumentColors should clear color marks")
		end
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

test("document links command renders badges, quickfix, and prompt context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"[Docs](https://example.com/docs)",
		"plain text",
	})
	vim.bo[source_buf].filetype = "markdown"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 2 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/documentLink")
		eq(params.textDocument.uri, uri)
		callback({
			[1] = {
				result = {
					{
						range = {
							start = { line = 0, character = 1 },
							["end"] = { line = 0, character = 5 },
						},
						target = "https://example.com/docs",
						tooltip = "Example documentation",
					},
				},
			},
		})
		return {
			[1] = 1,
		}
	end

	local input_buf
	local input_win
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		input_win = vim.api.nvim_get_current_win()
		vim.cmd("AcpDocumentLinks")

		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-document-links")
		local picker_text = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
		ok(picker_text:find("ACP Document Links", 1, true))
		ok(picker_text:find("https://example.com/docs", 1, true))
		ok(picker_text:find("Example documentation", 1, true))

		local ns = vim.api.nvim_create_namespace("acp.nvim.source")
		local marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		local link_range_found = false
		local link_badge_found = false
		local lens_found = false
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			if details.hl_group == "AcpSourceLinkRange" then
				link_range_found = true
				eq(mark[2] + 1, 1)
				eq(mark[3], 1)
				eq(details.end_col, 5)
			end
			for _, chunk in ipairs(details.virt_text or {}) do
				if chunk[1] and chunk[1]:find("LINK https://example.com/docs", 1, true) then
					link_badge_found = true
					ok(details.sign_text and details.sign_text:find(icons.reference, 1, true))
				end
			end
			for _, line in ipairs(details.virt_lines or {}) do
				for _, chunk in ipairs(line) do
					if chunk[1] and chunk[1]:find("links 1", 1, true) then
						lens_found = true
					end
				end
			end
		end
		ok(link_range_found, "AcpDocumentLinks should render the link range")
		ok(link_badge_found, "AcpDocumentLinks should render a link badge")
		ok(lens_found, "source lens should include document link count")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local qf = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qf.title:find("ACP document links", 1, true))
		eq(#qf.items, 1)
		ok(qf.items[1].text:find("DOCUMENT LINK: https://example.com/docs", 1, true))
		vim.cmd("cclose")

		if input_win and vim.api.nvim_win_is_valid(input_win) then
			vim.api.nvim_set_current_win(input_win)
		end
		vim.cmd("AcpDocumentLinksQuickfix")
		qf = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qf.title:find("ACP document links", 1, true))
		eq(#qf.items, 1)
		vim.cmd("cclose")

		if input_win and vim.api.nvim_win_is_valid(input_win) then
			vim.api.nvim_set_current_win(input_win)
		end
		vim.cmd("AcpDocumentLinks")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)
		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP document link as context: https://example.com/docs.", 1, true))
		ok(prompt:find("Document link:", 1, true))
		ok(prompt:find("Target: https://example.com/docs", 1, true))
		ok(prompt:find("Tooltip: Example documentation", 1, true))
		ok(prompt:find("Selection: lines 1-1", 1, true))
		ok(prompt:find("%[Docs%]%(https://example.com/docs%)"))

		vim.cmd("AcpClearDocumentLinks")
		marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			ok(details.hl_group ~= "AcpSourceLinkRange", "AcpClearDocumentLinks should clear link marks")
		end
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

test("folding ranges command renders overlays, quickfix, and prompt context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local function setup()",
		"  local value = 1",
		"  return value",
		"end",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/foldingRange")
		eq(params.textDocument.uri, uri)
		callback({
			[1] = {
				result = {
					{
						startLine = 0,
						endLine = 3,
						startCharacter = 0,
						endCharacter = 3,
						kind = "region",
						collapsedText = "setup()",
					},
				},
			},
		})
		return {
			[1] = 1,
		}
	end

	local input_buf
	local input_win
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		input_win = vim.api.nvim_get_current_win()
		vim.cmd("AcpFoldingRanges")

		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-folding-ranges")
		local picker_text = table.concat(vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false), "\n")
		ok(picker_text:find("ACP Folding Ranges", 1, true))
		ok(picker_text:find("region", 1, true))
		ok(picker_text:find("setup()", 1, true))

		local ns = vim.api.nvim_create_namespace("acp.nvim.source")
		local marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		local fold_line_marks = 0
		local fold_badge_found = false
		local lens_found = false
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			if details.line_hl_group == "AcpSourceFoldRange" then
				fold_line_marks = fold_line_marks + 1
			end
			for _, chunk in ipairs(details.virt_text or {}) do
				if chunk[1] and chunk[1]:find("FOLD region lines 1%-4: setup%(%)") then
					fold_badge_found = true
					ok(details.sign_text and details.sign_text:find(icons.fold, 1, true))
				end
			end
			for _, line in ipairs(details.virt_lines or {}) do
				for _, chunk in ipairs(line) do
					if chunk[1] and chunk[1]:find("folds 1", 1, true) then
						lens_found = true
					end
				end
			end
		end
		eq(fold_line_marks, 4)
		ok(fold_badge_found, "AcpFoldingRanges should render a fold badge")
		ok(lens_found, "source lens should include folding range count")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local qf = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qf.title:find("ACP folding ranges", 1, true))
		eq(#qf.items, 1)
		ok(qf.items[1].text:find("FOLDING RANGE: region lines 1%-4: setup%(%)"))
		vim.cmd("cclose")

		if input_win and vim.api.nvim_win_is_valid(input_win) then
			vim.api.nvim_set_current_win(input_win)
		end
		vim.cmd("AcpFoldingRangesQuickfix")
		qf = vim.fn.getqflist({ title = 1, items = 1 })
		ok(qf.title:find("ACP folding ranges", 1, true))
		eq(#qf.items, 1)
		vim.cmd("cclose")

		if input_win and vim.api.nvim_win_is_valid(input_win) then
			vim.api.nvim_set_current_win(input_win)
		end
		vim.cmd("AcpFoldingRanges")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)
		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP folding range as context: region lines 1%-4: setup%(%)%."))
		ok(prompt:find("Folding range:", 1, true))
		ok(prompt:find("Kind: region", 1, true))
		ok(prompt:find("Collapsed text: setup()", 1, true))
		ok(prompt:find("Selection: lines 1-4", 1, true))
		ok(prompt:find("local function setup", 1, true))

		vim.cmd("AcpClearFoldingRanges")
		marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			ok(details.line_hl_group ~= "AcpSourceFoldRange", "AcpClearFoldingRanges should clear fold marks")
		end
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

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local reference_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(reference_qflist.title:find("ACP references", 1, true))
		eq(#reference_qflist.items, 1)
		eq(reference_qflist.items[1].bufnr, source_buf)
		eq(reference_qflist.items[1].lnum, 2)
		eq(reference_qflist.items[1].col, 7)
		ok(reference_qflist.items[1].text:find("REFERENCE", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after references quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpReferencesQuickfix")
		reference_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(reference_qflist.title:find("ACP references", 1, true))
		eq(#reference_qflist.items, 1)
		eq(reference_qflist.items[1].lnum, 2)
		eq(reference_qflist.items[1].col, 7)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible before reference draft")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpReferences")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-references")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
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

test("declarations command drafts selected LSP declaration context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	local path = vim.fn.tempname() .. ".lua"
	vim.api.nvim_buf_set_name(source_buf, path)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local declared_value",
		"declared_value = 1",
		"print(declared_value)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 3, 6 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/declaration")
		eq(params.position.line, 2)
		eq(params.position.character, 6)
		callback({
			[1] = {
				result = {
					{
						targetUri = uri,
						targetSelectionRange = {
							start = { line = 0, character = 6 },
							["end"] = { line = 0, character = 20 },
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
		vim.cmd("AcpDeclarations")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-declarations")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local declaration_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(declaration_qflist.title:find("ACP declarations", 1, true))
		eq(#declaration_qflist.items, 1)
		eq(declaration_qflist.items[1].bufnr, source_buf)
		eq(declaration_qflist.items[1].lnum, 1)
		eq(declaration_qflist.items[1].col, 7)
		ok(declaration_qflist.items[1].text:find("DECLARATION", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after declarations quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpDeclarationsQuickfix")
		declaration_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(declaration_qflist.title:find("ACP declarations", 1, true))
		eq(#declaration_qflist.items, 1)
		eq(declaration_qflist.items[1].lnum, 1)
		eq(declaration_qflist.items[1].col, 7)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible before declaration draft")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpDeclarations")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-declarations")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP declaration as context.", 1, true))
		ok(prompt:find("Declaration:", 1, true))
		ok(prompt:find("Selection: lines 1-1", 1, true))
		ok(prompt:find("local declared_value", 1, true))
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

test("definitions command drafts selected LSP definition context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	local path = vim.fn.tempname() .. ".lua"
	vim.api.nvim_buf_set_name(source_buf, path)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local value = 1",
		"print(value)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 2, 6 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/definition")
		eq(params.position.line, 1)
		eq(params.position.character, 6)
		callback({
			[1] = {
				result = {
					uri = uri,
					range = {
						start = { line = 0, character = 6 },
						["end"] = { line = 0, character = 11 },
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
		vim.cmd("AcpDefinitions")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-definitions")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local definition_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(definition_qflist.title:find("ACP definitions", 1, true))
		eq(#definition_qflist.items, 1)
		eq(definition_qflist.items[1].bufnr, source_buf)
		eq(definition_qflist.items[1].lnum, 1)
		eq(definition_qflist.items[1].col, 7)
		ok(definition_qflist.items[1].text:find("DEFINITION", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after definitions quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpDefinitionsQuickfix")
		definition_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(definition_qflist.title:find("ACP definitions", 1, true))
		eq(#definition_qflist.items, 1)
		eq(definition_qflist.items[1].lnum, 1)
		eq(definition_qflist.items[1].col, 7)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible before definition draft")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpDefinitions")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-definitions")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP definition as context.", 1, true))
		ok(prompt:find("Definition:", 1, true))
		ok(prompt:find("Selection: lines 1-1", 1, true))
		ok(prompt:find("local value = 1", 1, true))
	end)

	vim.lsp.buf_request_all = original_buf_request_all
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.fn.delete(path)
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("implementations command drafts selected LSP implementation context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	local path = vim.fn.tempname() .. ".lua"
	vim.api.nvim_buf_set_name(source_buf, path)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local Interface = {}",
		"function Interface:run() end",
		"function Impl:run()",
		"  return true",
		"end",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 2, 19 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/implementation")
		eq(params.position.line, 1)
		eq(params.position.character, 19)
		callback({
			[1] = {
				result = {
					{
						uri = uri,
						range = {
							start = { line = 2, character = 9 },
							["end"] = { line = 2, character = 17 },
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
		vim.cmd("AcpImplementations")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-implementations")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local implementation_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(implementation_qflist.title:find("ACP implementations", 1, true))
		eq(#implementation_qflist.items, 1)
		eq(implementation_qflist.items[1].bufnr, source_buf)
		eq(implementation_qflist.items[1].lnum, 3)
		eq(implementation_qflist.items[1].col, 10)
		ok(implementation_qflist.items[1].text:find("IMPLEMENTATION", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after implementations quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpImplementationsQuickfix")
		implementation_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(implementation_qflist.title:find("ACP implementations", 1, true))
		eq(#implementation_qflist.items, 1)
		eq(implementation_qflist.items[1].lnum, 3)
		eq(implementation_qflist.items[1].col, 10)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible before implementation draft")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpImplementations")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-implementations")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP implementation as context.", 1, true))
		ok(prompt:find("Implementation:", 1, true))
		ok(prompt:find("Selection: lines 3-3", 1, true))
		ok(prompt:find("function Impl:run()", 1, true))
	end)

	vim.lsp.buf_request_all = original_buf_request_all
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.fn.delete(path)
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("type definitions command drafts selected LSP type definition context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	local path = vim.fn.tempname() .. ".lua"
	vim.api.nvim_buf_set_name(source_buf, path)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"---@class Person",
		"---@field name string",
		"local person = get_person()",
		"print(person.name)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 3, 6 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "textDocument/typeDefinition")
		eq(params.position.line, 2)
		eq(params.position.character, 6)
		callback({
			[1] = {
				result = {
					uri = uri,
					range = {
						start = { line = 0, character = 10 },
						["end"] = { line = 0, character = 16 },
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
		vim.cmd("AcpTypeDefinitions")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-type-definitions")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local type_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(type_qflist.title:find("ACP type definitions", 1, true))
		eq(#type_qflist.items, 1)
		eq(type_qflist.items[1].bufnr, source_buf)
		eq(type_qflist.items[1].lnum, 1)
		eq(type_qflist.items[1].col, 11)
		ok(type_qflist.items[1].text:find("TYPE DEFINITION", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after type definitions quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpTypeDefinitionsQuickfix")
		type_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(type_qflist.title:find("ACP type definitions", 1, true))
		eq(#type_qflist.items, 1)
		eq(type_qflist.items[1].lnum, 1)
		eq(type_qflist.items[1].col, 11)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible before type definition draft")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpTypeDefinitions")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-type-definitions")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP type definition as context.", 1, true))
		ok(prompt:find("Type definition:", 1, true))
		ok(prompt:find("Selection: lines 1-1", 1, true))
		ok(prompt:find("---@class Person", 1, true))
	end)

	vim.lsp.buf_request_all = original_buf_request_all
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.fn.delete(path)
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("workspace symbols command drafts selected LSP workspace symbol context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	local path = vim.fn.tempname() .. ".lua"
	vim.api.nvim_buf_set_name(source_buf, path)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local WorkspaceValue = 1",
		"print(WorkspaceValue)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 6 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		eq(method, "workspace/symbol")
		eq(params.query, "WorkspaceValue")
		callback({
			[1] = {
				result = {
					{
						name = "WorkspaceValue",
						kind = 13,
						containerName = "example",
						location = {
							uri = uri,
							range = {
								start = { line = 0, character = 6 },
								["end"] = { line = 0, character = 20 },
							},
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
		vim.cmd("AcpWorkspaceSymbols")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-workspace-symbols")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local symbol_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(symbol_qflist.title:find("ACP workspace symbols", 1, true))
		eq(#symbol_qflist.items, 1)
		eq(symbol_qflist.items[1].bufnr, source_buf)
		eq(symbol_qflist.items[1].lnum, 1)
		eq(symbol_qflist.items[1].col, 7)
		ok(symbol_qflist.items[1].text:find("WORKSPACE SYMBOL", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after workspace symbols quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpWorkspaceSymbolsQuickfix WorkspaceValue")
		symbol_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(symbol_qflist.title:find("ACP workspace symbols", 1, true))
		eq(#symbol_qflist.items, 1)
		eq(symbol_qflist.items[1].lnum, 1)
		eq(symbol_qflist.items[1].col, 7)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible before workspace symbol draft")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpWorkspaceSymbols WorkspaceValue")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-workspace-symbols")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP workspace symbol as context: WorkspaceValue %(Variable%)."))
		ok(prompt:find("Symbol:", 1, true))
		ok(prompt:find("Selection: lines 1-1", 1, true))
		ok(prompt:find("local WorkspaceValue = 1", 1, true))
	end)

	vim.lsp.buf_request_all = original_buf_request_all
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.fn.delete(path)
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("call hierarchy commands draft selected LSP caller and callee context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	local path = vim.fn.tempname() .. ".lua"
	vim.api.nvim_buf_set_name(source_buf, path)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local function caller()",
		"\ttarget()",
		"end",
		"local function callee()",
		"\treturn target()",
		"end",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 2, 2 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		if method == "textDocument/prepareCallHierarchy" then
			eq(params.position.line, 1)
			eq(params.position.character, 2)
			callback({
				[1] = {
					result = {
						{
							name = "target",
							kind = 12,
							uri = uri,
							range = {
								start = { line = 1, character = 1 },
								["end"] = { line = 1, character = 9 },
							},
							selectionRange = {
								start = { line = 1, character = 1 },
								["end"] = { line = 1, character = 7 },
							},
						},
					},
				},
			})
		elseif method == "callHierarchy/incomingCalls" then
			eq(params.item.name, "target")
			callback({
				[1] = {
					result = {
						{
							from = {
								name = "caller",
								kind = 12,
								uri = uri,
								range = {
									start = { line = 0, character = 0 },
									["end"] = { line = 2, character = 3 },
								},
								selectionRange = {
									start = { line = 0, character = 15 },
									["end"] = { line = 0, character = 21 },
								},
							},
							fromRanges = {
								{
									start = { line = 1, character = 1 },
									["end"] = { line = 1, character = 9 },
								},
							},
						},
					},
				},
			})
		elseif method == "callHierarchy/outgoingCalls" then
			eq(params.item.name, "target")
			callback({
				[1] = {
					result = {
						{
							to = {
								name = "callee",
								kind = 12,
								uri = uri,
								range = {
									start = { line = 3, character = 0 },
									["end"] = { line = 5, character = 3 },
								},
								selectionRange = {
									start = { line = 3, character = 15 },
									["end"] = { line = 3, character = 21 },
								},
							},
						},
					},
				},
			})
		else
			error("unexpected LSP method: " .. method)
		end
		return {
			[1] = 1,
		}
	end

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpCallers")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-callers")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local caller_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(caller_qflist.title:find("ACP incoming calls", 1, true))
		eq(#caller_qflist.items, 1)
		eq(caller_qflist.items[1].bufnr, source_buf)
		eq(caller_qflist.items[1].lnum, 1)
		eq(caller_qflist.items[1].col, 16)
		ok(caller_qflist.items[1].text:find("INCOMING CALL", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after callers quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpCallersQuickfix")
		caller_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(caller_qflist.title:find("ACP incoming calls", 1, true))
		eq(#caller_qflist.items, 1)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible before callee draft")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpCallees")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-callees")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP outgoing call as context: callee %(Function%)."))
		ok(prompt:find("Call callee:", 1, true))
		ok(prompt:find("Selection: lines 4-4", 1, true))
		ok(prompt:find("local function callee", 1, true))
	end)

	vim.lsp.buf_request_all = original_buf_request_all
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.fn.delete(path)
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	if not passed then
		error(err, 2)
	end
end)

test("type hierarchy commands draft selected LSP supertype and subtype context", function()
	local source_buf = vim.api.nvim_create_buf(true, true)
	local path = vim.fn.tempname() .. ".lua"
	vim.api.nvim_buf_set_name(source_buf, path)
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
		"local Base = {}",
		"local Child = setmetatable({}, Base)",
		"local Grandchild = setmetatable({}, Child)",
	})
	vim.bo[source_buf].filetype = "lua"
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_win_set_cursor(0, { 2, 6 })

	local uri = vim.uri_from_bufnr(source_buf)
	local original_buf_request_all = vim.lsp.buf_request_all
	vim.lsp.buf_request_all = function(bufnr, method, params, callback)
		eq(bufnr, source_buf)
		if method == "textDocument/prepareTypeHierarchy" then
			eq(params.position.line, 1)
			eq(params.position.character, 6)
			callback({
				[1] = {
					result = {
						{
							name = "Child",
							kind = 5,
							uri = uri,
							range = {
								start = { line = 1, character = 0 },
								["end"] = { line = 1, character = 35 },
							},
							selectionRange = {
								start = { line = 1, character = 6 },
								["end"] = { line = 1, character = 11 },
							},
						},
					},
				},
			})
		elseif method == "typeHierarchy/supertypes" then
			eq(params.item.name, "Child")
			callback({
				[1] = {
					result = {
						{
							name = "Base",
							kind = 5,
							uri = uri,
							range = {
								start = { line = 0, character = 0 },
								["end"] = { line = 0, character = 15 },
							},
							selectionRange = {
								start = { line = 0, character = 6 },
								["end"] = { line = 0, character = 10 },
							},
						},
					},
				},
			})
		elseif method == "typeHierarchy/subtypes" then
			eq(params.item.name, "Child")
			callback({
				[1] = {
					result = {
						{
							name = "Grandchild",
							kind = 5,
							uri = uri,
							range = {
								start = { line = 2, character = 0 },
								["end"] = { line = 2, character = 43 },
							},
							selectionRange = {
								start = { line = 2, character = 6 },
								["end"] = { line = 2, character = 16 },
							},
						},
					},
				},
			})
		else
			error("unexpected LSP method: " .. method)
		end
		return {
			[1] = 1,
		}
	end

	local input_buf
	local passed, err = pcall(function()
		vim.cmd("AcpChatWindow test")
		input_buf = vim.api.nvim_get_current_buf()
		vim.cmd("AcpSupertypes")
		local picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-supertypes")

		local keys = vim.api.nvim_replace_termcodes("Q", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		local super_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(super_qflist.title:find("ACP supertypes", 1, true))
		eq(#super_qflist.items, 1)
		eq(super_qflist.items[1].bufnr, source_buf)
		eq(super_qflist.items[1].lnum, 1)
		eq(super_qflist.items[1].col, 7)
		ok(super_qflist.items[1].text:find("SUPERTYPE", 1, true))
		vim.cmd("cclose")

		local input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible after supertypes quickfix")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpSupertypesQuickfix")
		super_qflist = vim.fn.getqflist({ title = 1, items = 1 })
		ok(super_qflist.title:find("ACP supertypes", 1, true))
		eq(#super_qflist.items, 1)
		vim.cmd("cclose")

		input_win = vim.fn.bufwinid(input_buf)
		ok(input_win and input_win > 0, "input window should be visible before subtype draft")
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("AcpSubtypes")
		picker_buf = vim.api.nvim_get_current_buf()
		eq(vim.bo[picker_buf].filetype, "acp-subtypes")
		keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		eq(vim.api.nvim_get_current_buf(), input_buf)

		local prompt = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		ok(prompt:find("Use this LSP subtype as context: Grandchild %(Class%)."))
		ok(prompt:find("Subtype:", 1, true))
		ok(prompt:find("Selection: lines 3-3", 1, true))
		ok(prompt:find("local Grandchild", 1, true))
	end)

	vim.lsp.buf_request_all = original_buf_request_all
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
	end
	if vim.api.nvim_buf_is_valid(source_buf) then
		pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
	end
	vim.fn.delete(path)
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

test("changes module records unique written files for picker and quickfix", function()
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

	local lines, line_entries = acp_changes.picker_lines(state)
	local text = table.concat(lines, "\n")
	ok(text:find("ACP Changed Files", 1, true))
	ok(text:find("example.txt  2 writes", 1, true))
	ok(text:find("nested/other.txt", 1, true))
	ok(text:find("Q for quickfix", 1, true))
	eq(line_entries[3].path, vim.fs.normalize(first))

	local preview = acp_changes.preview(line_entries[3])
	eq(preview.filetype, "text")
	ok(preview.title:find("example.txt", 1, true))
	eq(preview.lines[1], "one")

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
		"Agent",
		"```lua",
		"print('history')",
		"```",
		"See lua/acp/history.lua:1",
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
	eq(found.metrics.lines, 8)
	eq(found.metrics.sections, 3)
	eq(found.metrics.code_blocks, 1)
	eq(found.metrics.locations, 1)
	ok(found.summary:find("8 lines  3 sections  1 code  1 loc", 1, true))

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
	local browser_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	ok(browser_text:find("1 line  1 section  0 code  0 locs", 1, true))

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
