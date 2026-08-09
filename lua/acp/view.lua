local icons = require("acp.icons")
local output = require("acp.output")

local M = {}

local transcript_ns = vim.api.nvim_create_namespace("acp.nvim.transcript")

M.transcript_namespace = transcript_ns

local prompt_border = {
	{ "╭", "AcpPromptBorder" },
	{ "─", "AcpPromptBorder" },
	{ "╮", "AcpPromptBorder" },
	{ "│", "AcpPromptBorder" },
	{ "╯", "AcpPromptBorder" },
	{ "─", "AcpPromptBorder" },
	{ "╰", "AcpPromptBorder" },
	{ "│", "AcpPromptBorder" },
}

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function clean(value)
	return (tostring(value or ""):gsub("%%", "%%%%"))
end

local function format_count(value)
	local number = tonumber(value)
	if not number then
		return tostring(value or "")
	end
	if number >= 1000000 then
		return ((("%.1fm"):format(number / 1000000)):gsub("%.0m$", "m"))
	elseif number >= 1000 then
		return ((("%.1fk"):format(number / 1000)):gsub("%.0k$", "k"))
	end
	return tostring(number)
end

local function statusline_chunk(text, highlight)
	return ("%%#%s#%s%%*"):format(highlight, clean(text))
end

local function separator()
	return statusline_chunk(" · ", "AcpChatSeparator")
end

local function add_title_chunk(chunks, text, highlight)
	if #chunks > 0 then
		table.insert(chunks, { "  ", "AcpPromptTitleMeta" })
	end
	table.insert(chunks, { text, highlight })
end

function M.define_highlights()
	output.define_highlights()
	for name, definition in pairs({
		AcpPromptFloat = { link = "NormalFloat" },
		AcpPromptBorder = { fg = "#7aa2f7" },
		AcpPromptTitle = { fg = "#9ece6a", bold = true },
		AcpPromptTitleMeta = { link = "Comment" },
		AcpPromptTitleModel = { fg = "#bb9af7", bold = true },
		AcpPromptTitleContext = { fg = "#2ac3de", bold = true },
		AcpPromptKey = { fg = "#e0af68", bold = true },
		AcpPromptHint = { link = "Comment" },
		AcpInstructionFloat = { link = "NormalFloat" },
		AcpChatTitle = { fg = "#7aa2f7", bold = true },
		AcpChatMeta = { link = "Comment" },
		AcpChatSeparator = { link = "Comment" },
		AcpChatStatusActive = { fg = "#e0af68", bold = true },
		AcpChatStatusOk = { link = "DiagnosticOk" },
		AcpChatStatusError = { link = "DiagnosticError" },
		AcpUserHeader = { fg = "#9ece6a", bold = true },
		AcpAgentHeader = { fg = "#7dcfff", bold = true },
		AcpSectionHeader = { fg = "#bb9af7", bold = true },
		AcpTranscriptMeta = { link = "Comment" },
		AcpTranscriptTool = { fg = "#737aa2" },
		AcpTranscriptError = { link = "DiagnosticError" },
		AcpTranscriptWarning = { link = "DiagnosticWarn" },
		AcpActionTitle = { bold = true },
		AcpActionActive = { fg = "#e0af68", bold = true },
		AcpActionSuccess = { link = "DiagnosticOk" },
		AcpActionFailure = { link = "DiagnosticError" },
		AcpActionCommand = { fg = "#2ac3de" },
		AcpActionTool = { fg = "#bb9af7" },
		AcpActionTree = { link = "Comment" },
		AcpActionOutput = { link = "Comment" },
		AcpCodeFence = { fg = "#e0af68", bold = true },
		AcpInlineCode = { fg = "#7dcfff" },
		["@acp.user.header"] = { link = "AcpUserHeader" },
		["@acp.agent.header"] = { link = "AcpAgentHeader" },
		["@acp.section.header"] = { link = "AcpSectionHeader" },
		["@acp.action.title"] = { link = "AcpActionTitle" },
		["@acp.action.command"] = { link = "AcpActionCommand" },
		["@acp.action.tool"] = { link = "AcpActionTool" },
		["@acp.action.tree"] = { link = "AcpActionTree" },
		["@acp.action.output"] = { link = "AcpActionOutput" },
		["@acp.code.fence"] = { link = "AcpCodeFence" },
		["@acp.code.language"] = { link = "AcpInjectedLanguage" },
	}) do
		definition.default = true
		vim.api.nvim_set_hl(0, name, definition)
	end
end

local function current_section(state)
	if not state or not valid_buf(state.output_buf) or not valid_win(state.output_win) then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(state.output_win)
	if state.chat and state.chat.section_at then
		return state.chat:section_at(cursor[1])
	end
end

local function status_icon(state)
	local status = tostring(state.status or "idle"):lower()
	if status:find("error", 1, true) or status == "disconnected" then
		return icons.get("error")
	elseif state.busy or state.starting or status == "stopping" then
		return icons.spinner(state.instruction_spinner_frame)
	end
	return icons.get("idle")
end

function M.chat_winbar(state)
	state = state or {}
	local chunks = { statusline_chunk((" %s Codex "):format(icons.get("agent")), "AcpChatTitle") }
	table.insert(chunks, "%<")
	local section = current_section(state)
	if section then
		local title = tostring(section.title or section.kind or "output")
		if #title > 32 then
			title = title:sub(1, 29) .. "..."
		end
		table.insert(chunks, separator())
		table.insert(chunks, statusline_chunk(("%s %s"):format(icons.get("section"), title), "AcpChatMeta"))
	end
	if state.tokens then
		local used = format_count(state.tokens.totalTokens or 0)
		local window = state.tokens.modelContextWindow
		local usage = window and (used .. "/" .. format_count(window)) or used
		table.insert(chunks, separator())
		table.insert(chunks, statusline_chunk(usage .. " tokens", "AcpChatMeta"))
	end
	table.insert(chunks, " ")
	return table.concat(chunks)
end

function M.sessions_winbar(count, loading, cwd)
	local chunks = {
		statusline_chunk(" Sessions ", "AcpChatTitle"),
		separator(),
		statusline_chunk(tostring(count or 0), "AcpChatMeta"),
	}
	if loading then
		table.insert(chunks, separator())
		table.insert(chunks, statusline_chunk("loading", "AcpChatStatusActive"))
	end
	local project = cwd and vim.fn.fnamemodify(cwd, ":t") or ""
	if project ~= "" then
		table.insert(chunks, "%<")
		table.insert(chunks, separator())
		table.insert(chunks, statusline_chunk(project, "AcpChatMeta"))
	end
	table.insert(chunks, " ")
	return table.concat(chunks)
end

local function flatten(chunks)
	local values = {}
	for _, chunk in ipairs(chunks or {}) do
		table.insert(values, chunk[1] or "")
	end
	return table.concat(values)
end

local function chunks_width(chunks)
	return vim.fn.strdisplaywidth(flatten(chunks))
end

function M.prompt_title(state)
	state = state or {}
	local chunks = {}
	add_title_chunk(chunks, " Prompt ", "AcpPromptTitle")
	if state.model and state.model ~= "" then
		local model = state.effort and (state.model .. " · " .. state.effort) or state.model
		add_title_chunk(chunks, model, "AcpPromptTitleModel")
	end
	local context_window = state.tokens and state.tokens.modelContextWindow
	if context_window then
		add_title_chunk(chunks, "ctx " .. format_count(context_window), "AcpPromptTitleContext")
	end
	local context_count = #(state.contexts or {})
	if context_count > 0 then
		add_title_chunk(
			chunks,
			("+%d context%s"):format(context_count, context_count == 1 and "" or "s"),
			"AcpPromptTitleContext"
		)
	end
	return chunks
end

local function prompt_hints(compact)
	if compact then
		return { { " <C-CR> send ", "AcpPromptKey" } }
	end
	return {
		{ " <C-s> steer ", "AcpPromptKey" },
		{ "·", "AcpPromptHint" },
		{ " <C-CR> send ", "AcpPromptKey" },
	}
end

function M.prompt_footer(state, width)
	width = math.max(1, math.floor(tonumber(width) or 1))
	local metadata = M.prompt_title(state)
	local hints = prompt_hints(false)
	if chunks_width(metadata) + chunks_width(hints) + 1 > width then
		hints = prompt_hints(true)
	end
	while #metadata > 1 and chunks_width(metadata) + chunks_width(hints) + 1 > width do
		table.remove(metadata)
		table.remove(metadata)
	end
	if chunks_width(metadata) + chunks_width(hints) + 1 > width then
		hints = {}
	end
	if chunks_width(metadata) + 1 > width then
		metadata = {}
	end

	local footer = metadata
	local fill = math.max(1, width - chunks_width(metadata) - chunks_width(hints))
	table.insert(footer, { " " .. string.rep("─", fill - 1), "AcpPromptBorder" })
	for _, chunk in ipairs(hints) do
		table.insert(footer, chunk)
	end
	return footer
end

function M.prompt_key(state, width)
	return flatten(M.prompt_footer(state, width))
end

local function one_line(value)
	return vim.trim(tostring(value or ""):gsub("%s+", " "))
end

local function truncate_display(value, width)
	value = tostring(value or "")
	width = math.max(1, math.floor(tonumber(width) or 1))
	if vim.fn.strdisplaywidth(value) <= width then
		return value
	end
	local suffix = "…"
	local target = math.max(0, width - vim.fn.strdisplaywidth(suffix))
	local low = 0
	local high = vim.fn.strchars(value)
	while low < high do
		local middle = math.ceil((low + high) / 2)
		if vim.fn.strdisplaywidth(vim.fn.strcharpart(value, 0, middle)) <= target then
			low = middle
		else
			high = middle - 1
		end
	end
	return vim.fn.strcharpart(value, 0, low) .. suffix
end

local function fit_display(value, width)
	width = math.max(1, math.floor(tonumber(width) or 1))
	value = truncate_display(value, width)
	return value .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(value)))
end

local function ordered_instructions(instructions)
	local ordered = {}
	for _, kind in ipairs({ "steer", "queued" }) do
		for _, instruction in ipairs(instructions or {}) do
			if instruction.kind == kind then
				table.insert(ordered, instruction)
			end
		end
	end
	return ordered
end

function M.instruction_block(state, width, max_height)
	state = state or {}
	local instructions = type(state.pending_instructions) == "table" and state.pending_instructions or {}
	width = math.max(1, math.floor(tonumber(width) or 1))
	max_height = math.max(1, math.floor(tonumber(max_height) or (#instructions + 2)))
	local status = one_line(state.status)
	if status == "" then
		status = (state.busy or state.starting) and "working" or "ready"
	end
	local status_line = fit_display(("%s %s"):format(status_icon(state), status), width)
	local lines = {}
	local ordered = ordered_instructions(instructions)
	local has_top_spacer = max_height > 1
	local capacity = math.max(0, max_height - 1 - (has_top_spacer and 1 or 0))
	local visible = math.min(#ordered, capacity)
	if #ordered > capacity then
		visible = math.max(0, capacity - 1)
	end
	for index = 1, visible do
		local instruction = ordered[index]
		local steering = instruction.kind == "steer"
		local icon = icons.get(steering and "send" or "history")
		local label = steering and (instruction.accepted and "sent" or "steer") or "queued"
		table.insert(lines, fit_display(("%s %-6s %s"):format(icon, label, one_line(instruction.text)), width))
	end
	if #ordered > visible and capacity > 0 then
		local remaining = #ordered - visible
		table.insert(
			lines,
			fit_display(
				("%s +%d pending instruction%s"):format(icons.get("history"), remaining, remaining == 1 and "" or "s"),
				width
			)
		)
	end
	if has_top_spacer then
		table.insert(lines, 1, string.rep(" ", width))
	end
	table.insert(lines, status_line)
	return {
		lines = lines,
		key = table.concat(lines, "\0"),
	}
end

function M.prompt_geometry(bounds, opts)
	bounds = bounds or {}
	opts = opts or {}
	local row = math.max(0, math.floor(tonumber(bounds.row) or 0))
	local col = math.max(0, math.floor(tonumber(bounds.col) or 0))
	local available_width = math.max(3, math.floor(tonumber(bounds.width) or 3))
	local available_height = math.max(3, math.floor(tonumber(bounds.height) or 3))
	local padding = math.max(0, math.floor(tonumber(opts.input_padding) or 2))
	local desired_outer_height = math.max(3, math.floor(tonumber(opts.input_height) or 6))

	local horizontal_inset = available_width - padding * 2 >= 24 and padding or 0
	local outer_width = math.max(3, available_width - horizontal_inset * 2)
	local content_width = math.max(1, outer_width - 2)

	local bottom_inset = available_height >= desired_outer_height + padding and padding or 0
	local outer_height = math.min(desired_outer_height, available_height - bottom_inset)
	outer_height = math.max(3, outer_height)
	local content_height = math.max(1, outer_height - 2)

	return {
		row = row + math.max(0, available_height - outer_height - bottom_inset),
		col = col + horizontal_inset,
		width = content_width,
		height = content_height,
		outer_width = outer_width,
		outer_height = outer_height,
		reserved_rows = math.min(available_height - 1, outer_height + bottom_inset),
	}
end

local function output_bounds(winid)
	if not valid_win(winid) then
		return nil
	end
	local position = vim.api.nvim_win_get_position(winid)
	local info = vim.fn.getwininfo(winid)[1] or {}
	local textoff = math.max(0, tonumber(info.textoff) or 0)
	return {
		row = position[1] + math.max(0, tonumber(info.winbar) or 0),
		col = position[2] + textoff,
		width = math.max(3, vim.api.nvim_win_get_width(winid) - textoff),
		height = math.max(3, tonumber(info.height) or vim.api.nvim_win_get_height(winid)),
	}
end

function M.prompt_config(output_win, state, opts)
	opts = opts or {}
	local bounds = output_bounds(output_win)
	if not bounds then
		return nil
	end
	local geometry = M.prompt_geometry(bounds, opts)
	local footer = M.prompt_footer(state, geometry.width)
	local footer_key = flatten(footer)
	local prompt = {
		relative = "editor",
		row = geometry.row,
		col = geometry.col,
		width = geometry.width,
		height = geometry.height,
		style = "minimal",
		border = vim.deepcopy(prompt_border),
		footer = footer,
		footer_pos = "left",
		zindex = 50,
	}
	local reserved_rows = geometry.reserved_rows
	local instruction
	local instruction_config
	local available_instruction_height = math.max(0, math.floor(geometry.row - bounds.row))
	local requested_instruction_height = math.max(1, math.floor(tonumber(opts.instruction_height) or 4))
	local instruction_height = math.min(available_instruction_height, requested_instruction_height)
	if instruction_height > 0 then
		instruction = M.instruction_block(state, geometry.width, instruction_height)
	end
	if instruction then
		local attached_rows = #instruction.lines
		instruction_config = {
			relative = "editor",
			row = geometry.row - attached_rows,
			col = geometry.col + 1,
			width = geometry.width,
			height = attached_rows,
			style = "minimal",
			border = "none",
			focusable = false,
			zindex = 51,
		}
		reserved_rows = math.min(bounds.height - 1, reserved_rows + attached_rows)
	end
	return prompt,
		reserved_rows,
		footer_key,
		instruction_config,
		instruction and instruction.lines or nil,
		instruction and instruction.key or nil
end

local function numeric(value)
	if type(value) == "number" then
		return value
	end
	return tonumber(value) or 0
end

function M.same_prompt_geometry(current, desired)
	if type(current) ~= "table" or type(desired) ~= "table" then
		return false
	end
	return current.relative == desired.relative
		and numeric(current.row) == numeric(desired.row)
		and numeric(current.col) == numeric(desired.col)
		and current.width == desired.width
		and current.height == desired.height
end

function M.is_floating(winid)
	if not valid_win(winid) then
		return false
	end
	local ok, current = pcall(vim.api.nvim_win_get_config, winid)
	return ok and current.relative ~= ""
end

function M.configure_prompt_window(winid)
	if not valid_win(winid) then
		return
	end
	vim.wo[winid].number = false
	vim.wo[winid].relativenumber = false
	vim.wo[winid].signcolumn = "no"
	vim.wo[winid].foldcolumn = "0"
	vim.wo[winid].wrap = true
	vim.wo[winid].linebreak = true
	vim.wo[winid].cursorline = false
	vim.wo[winid].winbar = ""
	vim.wo[winid].fillchars = "eob: "
	vim.wo[winid].winhighlight = "NormalFloat:AcpPromptFloat,FloatBorder:AcpPromptBorder,FloatTitle:AcpPromptTitle"
end

function M.configure_instruction_window(winid)
	if not valid_win(winid) then
		return
	end
	vim.wo[winid].number = false
	vim.wo[winid].relativenumber = false
	vim.wo[winid].signcolumn = "no"
	vim.wo[winid].foldcolumn = "0"
	vim.wo[winid].wrap = false
	vim.wo[winid].cursorline = false
	vim.wo[winid].winbar = ""
	vim.wo[winid].fillchars = "eob: "
	vim.wo[winid].winhighlight = "NormalFloat:AcpInstructionFloat"
end

function M.configure_output_window(winid, reserved_rows)
	if not valid_win(winid) then
		return
	end
	vim.wo[winid].signcolumn = "no"
	vim.wo[winid].breakindent = false
	vim.wo[winid].showbreak = ""
	vim.wo[winid].conceallevel = 2
	vim.wo[winid].concealcursor = "nvic"
	vim.wo[winid].foldmethod = "expr"
	vim.wo[winid].foldexpr = "v:lua.acp_nvim_output_foldexpr()"
	vim.wo[winid].foldtext = "v:lua.acp_nvim_output_foldtext()"
	-- Keep the compact Codex-style action previews visible; users can still fold them manually.
	vim.wo[winid].foldlevel = 2
	vim.wo[winid].foldcolumn = "1"
	vim.wo[winid].statuscolumn = "%C "
	vim.wo[winid].scrolloff = math.max(0, tonumber(reserved_rows) or 0)
	vim.wo[winid].fillchars = "eob: "
end

function M.center_output(winid, line, reserved_rows)
	if not valid_win(winid) then
		return nil
	end
	local bufnr = vim.api.nvim_win_get_buf(winid)
	line = math.max(1, math.min(math.floor(tonumber(line) or 1), vim.api.nvim_buf_line_count(bufnr)))
	local ok, saved_view = pcall(vim.api.nvim_win_call, winid, function()
		vim.api.nvim_win_set_cursor(winid, { line, 0 })
		vim.cmd("normal! zz")
		local offset = math.ceil(math.max(0, tonumber(reserved_rows) or 0) / 2)
		if offset > 0 then
			local scroll_down = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
			vim.cmd(("normal! %d%s"):format(offset, scroll_down))
		end
		return vim.fn.winsaveview()
	end)
	return ok and saved_view or nil
end

local function mark(bufnr, row, col, opts)
	pcall(vim.api.nvim_buf_set_extmark, bufnr, transcript_ns, row, col, opts)
end

local function highlight_line(bufnr, row, line, highlight)
	if line == "" then
		return
	end
	local opts = {
		end_col = #line,
		hl_group = highlight,
		priority = 80,
	}
	mark(bufnr, row, 0, opts)
end

local function highlight_inline_code(bufnr, row, line)
	local start = 1
	while true do
		local first, last = line:find("`[^`]+`", start)
		if not first then
			return
		end
		mark(bufnr, row, first - 1, {
			end_col = last,
			hl_group = "AcpInlineCode",
			priority = 70,
		})
		start = last + 1
	end
end

local function highlight_action_row(bufnr, row, line, block, row_info)
	if not row_info or not tostring(row_info.role or ""):match("^action_") then
		return false
	end
	if row_info.role == "action_header" then
		local bullet_highlight = block.status == "failed" and "AcpActionFailure"
			or block.status == "in progress" and "AcpActionActive"
			or "AcpActionSuccess"
		mark(bufnr, row, 0, { end_col = #"•", hl_group = bullet_highlight, priority = 200 })
		local title_col = tonumber(row_info.title_col) or #"• "
		local title = tostring(row_info.title or "")
		if title ~= "" then
			mark(bufnr, row, title_col, {
				end_col = title_col + #title,
				hl_group = "AcpActionTitle",
				priority = 190,
			})
		end
		local detail_col = tonumber(row_info.detail_col)
		if detail_col and #line > detail_col then
			mark(bufnr, row, detail_col, {
				end_col = #line,
				hl_group = row_info.detail_kind == "tool" and "AcpActionTool" or "AcpActionCommand",
				priority = 180,
			})
		end
		return true
	end

	local tree = math.max(0, tonumber(row_info.tree_width) or 0)
	if tree > 0 then
		mark(bufnr, row, 0, { end_col = tree, hl_group = "AcpActionTree", priority = 170 })
		local highlight = row_info.role == "action_command" and "AcpActionCommand" or "AcpActionOutput"
		mark(bufnr, row, tree, { end_col = #line, hl_group = highlight, priority = 160 })
	end
	return true
end

local function structural_line_highlight(role)
	if role == "error" then
		return "AcpTranscriptError"
	elseif role == "warning" then
		return "AcpTranscriptWarning"
	elseif role == "change" then
		return "AcpTranscriptTool"
	elseif role == "notice" or role == "context" then
		return "AcpTranscriptMeta"
	end
end

function M.refresh_transcript(bufnr, start_row, chat, end_row)
	if not valid_buf(bufnr) then
		return
	end
	start_row = math.max(0, math.floor(tonumber(start_row) or 0))
	if end_row ~= nil then
		end_row = math.max(
			start_row,
			math.min(vim.api.nvim_buf_line_count(bufnr), math.floor(tonumber(end_row) or start_row))
		)
	else
		end_row = -1
	end
	vim.api.nvim_buf_clear_namespace(bufnr, transcript_ns, start_row, end_row)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
	for offset, line in ipairs(lines) do
		local row = start_row + offset - 1
		local line_number = row + 1
		local block = chat and chat.block_at and chat:block_at(line_number) or nil
		local row_info = block and chat and chat.row_at and chat:row_at(line_number, block) or nil
		if block and block.kind == "activity" and highlight_action_row(bufnr, row, line, block, row_info) then
			-- Action cells use literal Codex CLI tree glyphs and structured highlights.
		elseif row_info and row_info.role == "header" and row_info.header_kind == "user" then
			highlight_line(bufnr, row, line, "AcpUserHeader")
		elseif row_info and row_info.role == "header" and row_info.header_kind == "agent" then
			highlight_line(bufnr, row, line, "AcpAgentHeader")
		elseif
			row_info
			and row_info.role == "header"
			and (row_info.header_kind == "plan" or row_info.header_kind == "review")
		then
			highlight_line(bufnr, row, line, "AcpSectionHeader")
		elseif row_info and row_info.role == "code_fence" then
			highlight_line(bufnr, row, line, "AcpCodeFence")
		elseif row_info and structural_line_highlight(row_info.role) then
			highlight_line(bufnr, row, line, structural_line_highlight(row_info.role))
		end
		if not (row_info and row_info.role == "code_fence") then
			highlight_inline_code(bufnr, row, line)
		end
	end
end

return M
