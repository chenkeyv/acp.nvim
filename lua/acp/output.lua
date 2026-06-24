local M = {}

local animation_frames = { "|", "/", "-", "\\" }
local filetype_aliases = {
	bash = "sh",
	js = "javascript",
	jsonc = "json",
	md = "markdown",
	py = "python",
	shell = "sh",
	ts = "typescript",
	yml = "yaml",
	zsh = "sh",
}

local reference_token_pattern = "[^%s%[%]%(%){}<>,;]+:%d+:?%d*"

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_path(path)
	if not path or path == "" then
		return nil
	end
	local expanded = vim.fn.expand(path)
	local absolute = vim.fn.fnamemodify(expanded, ":p")
	return absolute ~= "" and absolute or nil
end

local function resolve_reference_path(raw_path, cwd)
	if not raw_path or raw_path == "" or raw_path:match("^%d+$") or raw_path:match("^%a[%w+.-]*://") then
		return nil
	end

	local path = raw_path
	if not path:match("^/") and not path:match("^~") then
		path = vim.fs.joinpath(cwd or vim.fn.getcwd(), path)
	end

	local absolute = normalize_path(path)
	if not absolute or vim.fn.filereadable(absolute) ~= 1 then
		return nil
	end
	return absolute
end

local function display_path(path, cwd)
	local normalized_cwd = normalize_path(cwd or vim.fn.getcwd())
	if normalized_cwd and path:sub(1, #normalized_cwd) == normalized_cwd then
		local relative = path:sub(#normalized_cwd + 1):gsub("^/", "")
		if relative ~= "" then
			return relative
		end
	end
	return vim.fn.fnamemodify(path, ":~:.")
end

local function parse_reference_token(token)
	token = token and token:gsub("^[`'\"%(%)%[%]{},;]+", ""):gsub("[`'\"%(%)%[%]{},;%.]+$", "")
	if not token or token == "" or token:find("://", 1, true) then
		return nil
	end

	local raw_path, line, column = token:match("^(.-):(%d+):(%d+)$")
	if not raw_path then
		raw_path, line = token:match("^(.-):(%d+)$")
	end
	if not raw_path or raw_path == "" then
		return nil
	end

	return raw_path, tonumber(line), tonumber(column) or 1
end

local function format_count(value)
	local number = tonumber(value)
	if not number then
		return clean(value) or "?"
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

local function source_label(source)
	if not source or not source.bufnr or not vim.api.nvim_buf_is_valid(source.bufnr) then
		return "none"
	end

	local name = vim.api.nvim_buf_get_name(source.bufnr)
	local path = name ~= "" and vim.fn.fnamemodify(name, ":.") or ("buffer " .. source.bufnr)
	local cursor = source.cursor or { 1, 0 }
	local filetype = vim.bo[source.bufnr].filetype ~= "" and vim.bo[source.bufnr].filetype or "text"
	if source.range then
		return ("%s:%d-%d [%s]"):format(path, source.range.line1, source.range.line2, filetype)
	end
	return ("%s:%d [%s]"):format(path, cursor[1] or 1, filetype)
end

local function metadata_label(state)
	local model = clean(state and state.model) or "?"
	local context_window = state and state.context_window and format_count(state.context_window) or "?"
	return ("Model: %s | Context: %s"):format(model, context_window)
end

local function title_parts(state, opts)
	opts = opts or {}
	local parts = {
		("ACP %s #%s"):format(clean(state and state.adapter) or "?", tostring(state and state.id or "?")),
		clean(state and state.run_status) or (state and state.busy and "running" or "idle"),
	}

	local model = clean(state and state.model)
	if model then
		table.insert(parts, model)
	end
	local context_window = clean(state and state.context_window)
	if context_window then
		table.insert(parts, ("ctx %s"):format(format_count(context_window)))
	end
	if opts.change_count and opts.change_count > 0 then
		table.insert(parts, ("%d change(s)"):format(opts.change_count))
	end

	return parts
end

function M.window_title(state, opts)
	return (" %s "):format(table.concat(title_parts(state, opts), " | "))
end

function M.winbar(state, opts)
	return M.window_title(state, opts):gsub("%%", "%%%%")
end

function M.dashboard_lines(state)
	return {
		("ACP: %s"):format(clean(state and state.adapter) or "?"),
		("Session: #%s | Mode: %s"):format(tostring(state and state.id or "?"), clean(state and state.mode) or "?"),
		metadata_label(state),
		("Source: %s"):format(source_label(state and state.source)),
		"Keys: [[/]] sections | za folds | <leader>av outline | <leader>ag locs | <leader>ab code | <leader>af changes | <leader>ad diagnostics",
		"",
	}
end

function M.define_highlights()
	vim.api.nvim_set_hl(0, "AcpOutputHeader", { fg = "#7aa2f7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputMeta", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpOutputKey", { fg = "#e0af68", default = true })
	vim.api.nvim_set_hl(0, "AcpUserHeader", { fg = "#9ece6a", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpAgentHeader", { fg = "#7dcfff", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpStatus", { fg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpStatusDone", { link = "DiagnosticOk", default = true })
	vim.api.nvim_set_hl(0, "AcpStatusError", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "AcpTool", { fg = "#bb9af7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpTerminal", { fg = "#2ac3de", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpFile", { fg = "#9ece6a", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpThought", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpError", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "AcpBadge", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeUser", { fg = "#1a1b26", bg = "#9ece6a", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeAgent", { fg = "#1a1b26", bg = "#7dcfff", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeStatus", { fg = "#1a1b26", bg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeError", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeTool", { fg = "#1a1b26", bg = "#bb9af7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpGhostText", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpCodeFence", { fg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpInjectedLanguage", { fg = "#1a1b26", bg = "#7aa2f7", bold = true, default = true })
end

function M.line_style(line)
	if line == "You" then
		return { line_hl_group = "AcpUserHeader", badge = " USER ", badge_hl = "AcpBadgeUser" }
	end
	if line == "Agent" then
		return { line_hl_group = "AcpAgentHeader", badge = " AGENT ", badge_hl = "AcpBadgeAgent" }
	end
	if line:match("^ACP:") then
		return { line_hl_group = "AcpOutputHeader", badge = " SESSION ", badge_hl = "AcpBadge" }
	end
	if line:match("^Session:") or line:match("^Model:") or line:match("^Source:") then
		return { line_hl_group = "AcpOutputMeta" }
	end
	if line:match("^Keys:") then
		return { line_hl_group = "AcpOutputKey" }
	end
	if line:match("^Status:%s+error") then
		return { line_hl_group = "AcpStatusError", badge = " ERROR ", badge_hl = "AcpBadgeError" }
	end
	if line:match("^Status:%s+stopped") or line:match("^Status:%s+restored") then
		return { line_hl_group = "AcpStatusDone", badge = " DONE ", badge_hl = "AcpBadgeStatus" }
	end
	if line:match("^Status:") then
		return { line_hl_group = "AcpStatus", badge = " LIVE ", badge_hl = "AcpBadgeStatus" }
	end
	if line:match("^Tool") then
		return { line_hl_group = "AcpTool", badge = " TOOL ", badge_hl = "AcpBadgeTool" }
	end
	if line:match("^Terminal:") then
		return { line_hl_group = "AcpTerminal", badge = " TERM ", badge_hl = "AcpBadgeTool" }
	end
	if line:match("^Wrote ") then
		return { line_hl_group = "AcpFile", badge = " FILE ", badge_hl = "AcpBadgeUser" }
	end
	if line:match("^Thought:") then
		return { line_hl_group = "AcpThought", badge = " NOTE ", badge_hl = "AcpBadge" }
	end
	if line:match("^stderr:") then
		return { line_hl_group = "AcpError", badge = " STDERR ", badge_hl = "AcpBadgeError" }
	end
end

function M.is_section(line)
	return line == "You"
		or line == "Agent"
		or line:match("^ACP:")
		or line:match("^Status:")
		or line:match("^Tool")
		or line:match("^Terminal:")
		or line:match("^Wrote ")
		or line:match("^Thought:")
		or line:match("^stderr:")
end

local function section_label(line)
	if line == "You" then
		return "USER", "Prompt"
	end
	if line == "Agent" then
		return "AGENT", "Response"
	end
	if line:match("^ACP:") then
		return "SESSION", line
	end
	if line:match("^Status:") then
		return "STATUS", line:gsub("^Status:%s*", "")
	end
	if line:match("^Tool update:") then
		return "TOOL", line:gsub("^Tool update:%s*", "Update: ")
	end
	if line:match("^Tool:") then
		return "TOOL", line:gsub("^Tool:%s*", "")
	end
	if line:match("^Terminal:") then
		return "TERM", line:gsub("^Terminal:%s*", "")
	end
	if line:match("^Wrote ") then
		return "FILE", line:gsub("^Wrote%s+", "")
	end
	if line:match("^Thought:") then
		return "NOTE", line:gsub("^Thought:%s*", "")
	end
	if line:match("^stderr:") then
		return "STDERR", "stderr"
	end
	return "SECTION", line
end

local function preview_after(lines, index)
	for next_index = index + 1, #lines do
		local line = clean(lines[next_index])
		if line and not M.is_section(line) then
			return line:sub(1, 96)
		end
	end
end

function M.sections(lines)
	local sections = {}
	for index, line in ipairs(lines or {}) do
		if M.is_section(line) then
			local kind, title = section_label(line)
			table.insert(sections, {
				line = index,
				kind = kind,
				title = clean(title) or kind,
				preview = preview_after(lines, index),
			})
		end
	end
	return sections
end

function M.outline_lines(sections)
	local lines = { "ACP Output Outline", "" }
	local line_sections = {}
	for _, section in ipairs(sections or {}) do
		local title = section.title
		if #title > 88 then
			title = title:sub(1, 85) .. "..."
		end
		table.insert(lines, ("%4d  %-7s  %s"):format(section.line, section.kind, title))
		line_sections[#lines] = section
		if section.preview then
			table.insert(lines, ("      %s"):format(section.preview))
			line_sections[#lines] = section
		end
	end
	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to jump, or q/<Esc> to close.")
	return lines, line_sections
end

function M.animation_frame(index)
	local number = tonumber(index) or 1
	return animation_frames[((number - 1) % #animation_frames) + 1]
end

function M.ghost_text(state, lines, frame)
	lines = lines or {}
	if state and state.busy then
		return ("%s %s"):format(M.animation_frame(frame), clean(state.run_status) or "working")
	end

	if #M.sections(lines) <= 1 then
		return "Ready - draft in the prompt buffer"
	end

	return "Idle - [[/]] sections, za folds, <leader>av outline, <leader>ag locs, <leader>ab code"
end

function M.filetype_for_language(language)
	local value = clean(language)
	if not value then
		return "text"
	end

	value = value:lower()
	return filetype_aliases[value] or value
end

local function block_lines(lines, block, closed)
	local first = block.start_line + 1
	local last = closed and (block.end_line - 1) or block.end_line
	local body = {}

	for index = first, last do
		table.insert(body, lines[index] or "")
	end
	if #body == 0 then
		table.insert(body, "")
	end
	return body
end

local function finish_block(blocks, lines, block, end_line, closed)
	block.end_line = end_line
	block.closed = closed
	block.filetype = M.filetype_for_language(block.language)
	block.lines = block_lines(lines, block, closed)
	block.line_count = #block.lines == 1 and block.lines[1] == "" and 0 or #block.lines
	block.preview = clean(block.lines[1])
	table.insert(blocks, block)
end

function M.code_blocks(lines)
	local blocks = {}
	local current

	for index, line in ipairs(lines or {}) do
		local language = line:match("^%s*```%s*([^%s`]*)")
		if language then
			if current then
				finish_block(blocks, lines, current, index, true)
				current = nil
			else
				current = {
					start_line = index,
					language = clean(language) or "text",
				}
			end
		end
	end

	if current then
		finish_block(blocks, lines, current, #lines, false)
	end

	return blocks
end

function M.code_block_lines(blocks)
	local lines = { "ACP Output Code Blocks", "" }
	local line_blocks = {}

	for _, block in ipairs(blocks or {}) do
		local language = block.language or "text"
		if #language > 16 then
			language = language:sub(1, 13) .. "..."
		end
		local count = ("%d line%s"):format(block.line_count or 0, block.line_count == 1 and "" or "s")
		table.insert(lines, ("%4d-%-4d  %-16s  %s"):format(block.start_line, block.end_line, language, count))
		line_blocks[#lines] = block
		if block.preview then
			table.insert(lines, ("      %s"):format(block.preview:sub(1, 96)))
			line_blocks[#lines] = block
		end
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to open a scratch buffer, / to filter, or q/<Esc> to close.")
	return lines, line_blocks
end

function M.file_references(lines, opts)
	opts = opts or {}
	local cwd = opts.cwd or vim.fn.getcwd()
	local limit = opts.limit or 120
	local references = {}
	local seen = {}

	for source_line, line in ipairs(lines or {}) do
		for token in tostring(line):gmatch(reference_token_pattern) do
			local raw_path, target_line, column = parse_reference_token(token)
			local path = resolve_reference_path(raw_path, cwd)
			if path and target_line then
				local key = ("%s:%d:%d"):format(path, target_line, column)
				if not seen[key] then
					seen[key] = true
					table.insert(references, {
						path = path,
						display_path = display_path(path, cwd),
						line = target_line,
						column = column,
						source_line = source_line,
						source_text = clean(line),
					})
					if #references >= limit then
						return references
					end
				end
			end
		end
	end

	return references
end

function M.file_reference_lines(references)
	local lines = { "ACP Output Locations", "" }
	local line_references = {}

	for _, reference in ipairs(references or {}) do
		local location = ("%s:%d:%d"):format(reference.display_path or reference.path or "?", reference.line or 1, reference.column or 1)
		table.insert(lines, ("%4d  %s"):format(reference.source_line or 1, location))
		line_references[#lines] = reference
		if reference.source_text then
			table.insert(lines, ("      %s"):format(reference.source_text:sub(1, 96)))
			line_references[#lines] = reference
		end
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to jump, / to filter, or q/<Esc> to close.")
	return lines, line_references
end

function M.fold_level(lines, lnum)
	lines = lines or {}
	local line = lines[lnum]
	if not line then
		return "0"
	end

	if M.is_section(line) then
		return ">1"
	end

	for index = lnum - 1, 1, -1 do
		if M.is_section(lines[index]) then
			return "1"
		end
	end

	return "0"
end

function M.fold_text(lines, foldstart, foldend)
	lines = lines or {}
	local line = lines[foldstart] or ""
	local kind, title = section_label(line)
	title = clean(title) or kind
	local count = math.max(1, (tonumber(foldend) or foldstart) - foldstart + 1)
	local preview = preview_after(lines, foldstart)
	local suffix = preview and ("  " .. preview) or ""
	local text = ("[%s] %s  (%d line%s)%s"):format(kind, title, count, count == 1 and "" or "s", suffix)

	if #text > 120 then
		return text:sub(1, 117) .. "..."
	end
	return text
end

function M.next_section(lines, current, direction)
	direction = direction < 0 and -1 or 1
	local index = current + direction
	while index >= 1 and index <= #lines do
		if M.is_section(lines[index]) then
			return index
		end
		index = index + direction
	end
end

return M
