local M = {}

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
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
		"Keys: [[/]] sections | <leader>av outline | <leader>af changes | <leader>ad diagnostics",
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
