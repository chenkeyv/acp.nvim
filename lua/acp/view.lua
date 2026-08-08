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
		AcpTranscriptTool = { fg = "#e0af68" },
		AcpTranscriptError = { link = "DiagnosticError" },
		AcpTranscriptWarning = { link = "DiagnosticWarn" },
		AcpCodeFence = { fg = "#e0af68", bold = true },
		AcpInlineCode = { fg = "#7dcfff" },
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
	local sections = state.output_cache and state.output_cache.sections
	if sections and #sections > 0 then
		local low = 1
		local high = #sections
		local current
		while low <= high do
			local middle = math.floor((low + high) / 2)
			if (sections[middle].line or 1) <= cursor[1] then
				current = sections[middle]
				low = middle + 1
			else
				high = middle - 1
			end
		end
		return current
	end
	local lines = vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false)
	return output.current_section(lines, cursor[1])
end

local function status_highlight(state)
	local status = tostring(state.status or "idle"):lower()
	if status:find("error", 1, true) or status == "disconnected" then
		return "AcpChatStatusError"
	elseif state.busy or state.starting or status == "stopping" then
		return "AcpChatStatusActive"
	end
	return "AcpChatStatusOk"
end

local function status_icon(state)
	local status = tostring(state.status or "idle"):lower()
	if status:find("error", 1, true) or status == "disconnected" then
		return icons.get("error")
	elseif state.busy or state.starting or status == "stopping" then
		return icons.get("busy")
	end
	return icons.get("idle")
end

function M.chat_winbar(state)
	state = state or {}
	local chunks = { statusline_chunk((" %s Codex "):format(icons.get("agent")), "AcpChatTitle") }
	table.insert(chunks, separator())
	table.insert(
		chunks,
		statusline_chunk(("%s %s"):format(status_icon(state), state.status or "idle"), status_highlight(state))
	)
	table.insert(chunks, "%<")
	local section = current_section(state)
	if section then
		local title = tostring(section.title or section.kind or "output")
		if #title > 32 then
			title = title:sub(1, 29) .. "..."
		end
		table.insert(chunks, separator())
		table.insert(
			chunks,
			statusline_chunk(("%s %s"):format(icons.get("section"), title), "AcpChatMeta")
		)
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
	local queued = #(state.queue or {})
	if queued > 0 then
		add_title_chunk(chunks, ("%d queued"):format(queued), "AcpChatStatusActive")
	end
	return chunks
end

function M.prompt_footer()
	return {
		{ " <C-s> steer ", "AcpPromptKey" },
		{ "·", "AcpPromptHint" },
		{ " <C-CR> send ", "AcpPromptKey" },
	}
end

local function flatten(chunks)
	local values = {}
	for _, chunk in ipairs(chunks or {}) do
		table.insert(values, chunk[1] or "")
	end
	return table.concat(values)
end

function M.prompt_key(state)
	return flatten(M.prompt_title(state)) .. "\0" .. flatten(M.prompt_footer())
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
	local bounds = output_bounds(output_win)
	if not bounds then
		return nil
	end
	local geometry = M.prompt_geometry(bounds, opts)
	return {
		relative = "editor",
		row = geometry.row,
		col = geometry.col,
		width = geometry.width,
		height = geometry.height,
		style = "minimal",
		border = vim.deepcopy(prompt_border),
		title = M.prompt_title(state),
		title_pos = "left",
		footer = M.prompt_footer(),
		footer_pos = "right",
		zindex = 50,
	}, geometry.reserved_rows, M.prompt_key(state)
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
	vim.wo[winid].winhighlight =
		"NormalFloat:AcpPromptFloat,FloatBorder:AcpPromptBorder,FloatTitle:AcpPromptTitle"
end

function M.configure_output_window(winid, reserved_rows)
	if not valid_win(winid) then
		return
	end
	vim.wo[winid].signcolumn = "yes:1"
	vim.wo[winid].conceallevel = 2
	vim.wo[winid].concealcursor = "nvic"
	vim.wo[winid].foldmethod = "expr"
	vim.wo[winid].foldexpr = "v:lua.acp_nvim_output_foldexpr()"
	vim.wo[winid].foldtext = "v:lua.acp_nvim_output_foldtext()"
	-- Keep transcript sections open while completed activity groups start collapsed.
	vim.wo[winid].foldlevel = 1
	vim.wo[winid].foldcolumn = "1"
	vim.wo[winid].statuscolumn = "%s%C "
	vim.wo[winid].scrolloff = math.max(0, tonumber(reserved_rows) or 0)
	vim.wo[winid].fillchars = "eob: "
end

local function mark(bufnr, row, col, opts)
	pcall(vim.api.nvim_buf_set_extmark, bufnr, transcript_ns, row, col, opts)
end

local function highlight_line(bufnr, row, line, highlight, sign_highlight, sign_icon)
	if line == "" then
		return
	end
	local opts = {
		end_col = #line,
		hl_group = highlight,
		priority = 80,
	}
	if sign_highlight then
		opts.sign_text = sign_icon or icons.get("info")
		opts.sign_hl_group = sign_highlight
	end
	mark(bufnr, row, 0, opts)
end

local function conceal_prefix(bufnr, row, prefix)
	if prefix and prefix ~= "" then
		mark(bufnr, row, 0, {
			end_col = #prefix,
			conceal = "",
			priority = 90,
		})
	end
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

local function quote_style(content)
	local exit_code = tonumber(content:match("^Command.-%(exit%s+([+-]?%d+)%)"))
	if content:match("^Error:")
		or content:match("failed")
		or content:match("cancelled")
		or content:match("canceled")
		or (exit_code ~= nil and exit_code ~= 0)
	then
		return "AcpTranscriptError", "error"
	elseif content:match("^Warning:") then
		return "AcpTranscriptWarning", "warning"
	elseif content:match("^Command") then
		return "AcpTranscriptTool", "command"
	elseif content:match("^Tool") then
		return "AcpTranscriptTool", "tool"
	elseif content:match("^File changes") or content:match("^[%a%s]+%s+`[^`]+`") then
		return "AcpTranscriptTool", "changes"
	elseif content:match("^Context:") then
		return "AcpTranscriptMeta", "context"
	elseif content:match("review mode") or content:match("context compacted") then
		return "AcpTranscriptMeta", "note"
	end
	return "AcpTranscriptMeta", "info"
end

function M.refresh_transcript(bufnr, start_row)
	if not valid_buf(bufnr) then
		return
	end
	start_row = math.max(0, math.floor(tonumber(start_row) or 0))
	vim.api.nvim_buf_clear_namespace(bufnr, transcript_ns, start_row, -1)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, -1, false)
	for offset, line in ipairs(lines) do
		local row = start_row + offset - 1
		local heading = line:match("^(#+%s+)")
		if line:match("^##%s+You") then
			highlight_line(bufnr, row, line, "AcpUserHeader", "AcpUserHeader", icons.get("user"))
			conceal_prefix(bufnr, row, heading)
		elseif line:match("^##%s+Codex") or line == "# Codex" then
			highlight_line(bufnr, row, line, "AcpAgentHeader", "AcpAgentHeader", icons.get("agent"))
			conceal_prefix(bufnr, row, heading)
		elseif line:match("^###%s+") then
			highlight_line(bufnr, row, line, "AcpSectionHeader", "AcpSectionHeader", icons.get("section"))
			conceal_prefix(bufnr, row, heading)
		elseif line:match("^```") then
			highlight_line(bufnr, row, line, "AcpCodeFence", "AcpCodeFence", icons.get("code"))
		elseif line:match("^Working directory:") then
			highlight_line(bufnr, row, line, "AcpTranscriptMeta")
		elseif line:match("^>%s*") then
			local prefix = line:match("^(>%s*)")
			local content = line:sub(#prefix + 1)
			local highlight, icon = quote_style(content)
			highlight_line(bufnr, row, line, highlight, highlight, icons.get(icon))
			conceal_prefix(bufnr, row, prefix)
		end
		if not line:match("^```") then
			highlight_inline_code(bufnr, row, line)
		end
	end
end

return M
