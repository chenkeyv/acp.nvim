local M = {}

local animation_frames = { "|", "/", "-", "\\" }
local motion_frames = { "[>   ]", "[=>  ]", "[ => ]", "[  =>]", "[   >]", "[  <=]", "[ <= ]", "[<=  ]" }
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

local function reference_from_token(token, opts)
	opts = opts or {}
	local raw_path, target_line, column = parse_reference_token(token)
	local path = resolve_reference_path(raw_path, opts.cwd)
	if not path or not target_line then
		return nil
	end

	return {
		path = path,
		display_path = display_path(path, opts.cwd),
		line = target_line,
		column = column,
		source_line = opts.source_line,
		source_col = opts.source_col,
		source_end_col = opts.source_end_col,
		source_text = clean(opts.source_text),
	}
end

local function each_reference_token(line, callback)
	line = tostring(line or "")
	local start = 1
	while start <= #line do
		local first, last = line:find(reference_token_pattern, start)
		if not first then
			break
		end
		callback(line:sub(first, last), first, last)
		start = last + 1
	end
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

local function short_label(value, limit)
	local label = clean(value) or "?"
	limit = limit or 48
	if #label > limit then
		return label:sub(1, limit - 3) .. "..."
	end
	return label
end

local function flatten_chunks(chunks)
	local text = {}
	for _, chunk in ipairs(chunks or {}) do
		table.insert(text, chunk[1] or "")
	end
	return table.concat(text)
end

local function position_percent(line, total)
	total = tonumber(total) or 0
	if total <= 0 then
		return nil
	end
	line = math.max(1, math.min(tonumber(line) or 1, total))
	return ("%3d%%"):format(math.floor((line / total) * 100 + 0.5))
end

local function progress_bar(line, total, width)
	width = tonumber(width) or 10
	width = math.max(3, width)
	total = tonumber(total) or 0
	if total <= 0 then
		return "[" .. string.rep("-", width) .. "]"
	end

	local ratio = math.max(0, math.min(1, (tonumber(line) or 1) / total))
	local filled = math.floor((ratio * width) + 0.5)
	if ratio > 0 then
		filled = math.max(1, filled)
	end
	filled = math.min(width, filled)
	return "[" .. string.rep("=", filled) .. string.rep("-", width - filled) .. "]"
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
	if opts.current_item then
		local item_label = clean(opts.current_item.label) or opts.current_item.kind or "item"
		if #item_label > 36 then
			item_label = item_label:sub(1, 33) .. "..."
		end
		table.insert(
			parts,
			("item %d/%d %s: %s"):format(
				opts.current_item.index or 1,
				opts.current_item.total or 1,
				(opts.current_item.kind or "item"):upper(),
				item_label
			)
		)
	end
	if opts.current_section then
		local section_title = clean(opts.current_section.title) or opts.current_section.kind or "section"
		if #section_title > 36 then
			section_title = section_title:sub(1, 33) .. "..."
		end
		table.insert(parts, ("at %s: %s"):format(opts.current_section.kind or "SECTION", section_title))
	end

	return parts
end

function M.window_title(state, opts)
	return (" %s "):format(table.concat(title_parts(state, opts), " | "))
end

function M.winbar(state, opts)
	return M.window_title(state, opts):gsub("%%", "%%%%")
end

local function summary_label(stats)
	stats = stats or {}
	return ("Transcript: %d section%s | %d code | %d loc%s | %d change%s"):format(
		stats.sections or 0,
		stats.sections == 1 and "" or "s",
		stats.code_blocks or 0,
		stats.locations or 0,
		stats.locations == 1 and "" or "s",
		stats.changes or 0,
		stats.changes == 1 and "" or "s"
	)
end

function M.dashboard_lines(state, opts)
	opts = opts or {}
	return {
		("ACP: %s"):format(clean(state and state.adapter) or "?"),
		("Session: #%s | Mode: %s"):format(tostring(state and state.id or "?"), clean(state and state.mode) or "?"),
		metadata_label(state),
		("Source: %s"):format(source_label(state and state.source)),
		summary_label(opts.stats),
		"Keys: ? actions | K inspect | ]o/[o items | <leader>ax search | gf refs | <leader>ay yank | [[/]] sections | <leader>av outline",
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
	vim.api.nvim_set_hl(0, "AcpWarning", { link = "DiagnosticWarn", default = true })
	vim.api.nvim_set_hl(0, "AcpBadge", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeUser", { fg = "#1a1b26", bg = "#9ece6a", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeAgent", { fg = "#1a1b26", bg = "#7dcfff", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeStatus", { fg = "#1a1b26", bg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeError", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeWarn", { fg = "#1a1b26", bg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpBadgeTool", { fg = "#1a1b26", bg = "#bb9af7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpGhostText", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpOutputHint", { link = "AcpGhostText", default = true })
	vim.api.nvim_set_hl(0, "AcpCodeFence", { fg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpCodeBlockHeader", { fg = "#1a1b26", bg = "#414868", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpCodeBlockSign", { link = "AcpCodeFence", default = true })
	vim.api.nvim_set_hl(0, "AcpInjectedLanguage", { fg = "#1a1b26", bg = "#7aa2f7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpInjectedLanguageActive", { fg = "#1a1b26", bg = "#9ece6a", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpCodeBlockLensMuted", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpOutputReference", { link = "Underlined", default = true })
	vim.api.nvim_set_hl(0, "AcpOutputReferenceBadge", { fg = "#1a1b26", bg = "#2ac3de", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpSectionStats", { fg = "#1a1b26", bg = "#565f89", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputTimeline", { fg = "#c0caf5", bg = "#3b4261", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputRail", { fg = "#9ece6a", bg = "#1f2335", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpCurrentSection", { link = "CursorLine", default = true })
	vim.api.nvim_set_hl(0, "AcpCurrentItem", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "AcpOutputActivity", { fg = "#1a1b26", bg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputActivityCard", { fg = "#c0caf5", bg = "#24283b", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputActivityTool", { fg = "#1a1b26", bg = "#bb9af7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputActivityTerminal", { fg = "#1a1b26", bg = "#2ac3de", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputActivityFile", { fg = "#1a1b26", bg = "#9ece6a", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputActivityProblem", { fg = "#1a1b26", bg = "#f7768e", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputLive", { fg = "#1a1b26", bg = "#f7768e", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputMotion", { fg = "#1a1b26", bg = "#2ac3de", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputIdle", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpOutputPulse", { link = "IncSearch", default = true })
	vim.api.nvim_set_hl(0, "AcpOutputPulseSoft", { link = "Search", default = true })
	vim.api.nvim_set_hl(0, "AcpOutputSkyline", { fg = "#1a1b26", bg = "#c0caf5", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpOutputSkylineDim", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpOutputSpark", { fg = "#ff9e64", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpInjectedCode", { link = "Visual", default = true })
end

function M.activity_separator(line)
	line = line or ""
	if line:match("^Tool update:") then
		return ("---- TOOL UPDATE: %s | K inspect | ]o/[o items ----"):format(short_label((line:gsub("^Tool update:%s*", ""))))
	end
	if line:match("^Tool:") then
		return ("---- TOOL: %s | K inspect | ]o/[o items ----"):format(short_label((line:gsub("^Tool:%s*", ""))))
	end
	if line:match("^Terminal:") then
		return ("---- TERMINAL: %s | K inspect | ]o/[o items ----"):format(short_label((line:gsub("^Terminal:%s*", ""))))
	end
	if line:match("^Terminal output truncated") then
		return "---- TERMINAL WARNING: output truncated | <leader>ae problems ----"
	end
	if line:match("^stderr:") then
		return "---- STDERR: problem output | K inspect | <leader>ae problems ----"
	end
end

function M.activity_lens_chunks(line, frame)
	line = line or ""
	local label
	local title
	local hint
	local hl
	if line:match("^Tool update:") then
		label = " TOOL UPDATE "
		title = clean(line:gsub("^Tool update:%s*", "")) or "updated"
		hint = "K inspect | ]o/[o items | ? actions"
		hl = "AcpOutputActivityTool"
	elseif line:match("^Tool:") then
		label = " TOOL CALL "
		title = clean(line:gsub("^Tool:%s*", "")) or "tool"
		hint = "K inspect | ]o/[o items | ? actions"
		hl = "AcpOutputActivityTool"
	elseif line:match("^Terminal:") then
		label = " TERMINAL "
		title = clean(line:gsub("^Terminal:%s*", "")) or "terminal"
		hint = "streaming output | K inspect | <leader>ae problems"
		hl = "AcpOutputActivityTerminal"
	elseif line:match("^Terminal output truncated") then
		label = " TERMINAL WARN "
		title = "output truncated"
		hint = "<leader>ae problems | K inspect"
		hl = "AcpOutputActivityProblem"
	elseif line:match("^stderr:") then
		label = " STDERR "
		title = clean(line:gsub("^stderr:%s*", "")) or "problem output"
		hint = "<leader>ae problems | K inspect"
		hl = "AcpOutputActivityProblem"
	elseif line:match("^Wrote ") then
		label = " FILE WRITE "
		title = clean(line:gsub("^Wrote%s+", "")) or "file"
		hint = ":AcpChanges preview | <leader>af files"
		hl = "AcpOutputActivityFile"
	else
		return nil
	end

	if #title > 46 then
		title = title:sub(1, 43) .. "..."
	end
	return {
		{ (" %s "):format(M.motion_frame(frame)), "AcpOutputMotion" },
		{ label, hl },
		{ (" %s "):format(title), "AcpOutputActivityCard" },
		{ ("| %s "):format(hint), "AcpOutputHint" },
	}
end

function M.line_style(line)
	if line == "You" then
		return {
			line_hl_group = "AcpUserHeader",
			badge = " USER ",
			badge_hl = "AcpBadgeUser",
			sign_text = "U>",
			separator = "---- USER: Prompt ----",
		}
	end
	if line == "Agent" then
		return {
			line_hl_group = "AcpAgentHeader",
			badge = " AGENT ",
			badge_hl = "AcpBadgeAgent",
			sign_text = "A>",
			separator = "---- AGENT: Response ----",
		}
	end
	if line:match("^ACP:") then
		return { line_hl_group = "AcpOutputHeader", badge = " SESSION ", badge_hl = "AcpBadge", sign_text = "S>" }
	end
	if line:match("^Session:") or line:match("^Model:") or line:match("^Source:") or line:match("^Transcript:") then
		return { line_hl_group = "AcpOutputMeta" }
	end
	if line:match("^Keys:") then
		return { line_hl_group = "AcpOutputKey" }
	end
	if line:match("^Status:%s+error") then
		return {
			line_hl_group = "AcpStatusError",
			badge = " ERROR ",
			badge_hl = "AcpBadgeError",
			sign_text = "E!",
			separator = "---- STATUS: Error ----",
		}
	end
	if line:match("^Status:%s+stopped") or line:match("^Status:%s+restored") then
		return {
			line_hl_group = "AcpStatusDone",
			badge = " DONE ",
			badge_hl = "AcpBadgeStatus",
			sign_text = "OK",
			separator = "---- STATUS: Done ----",
		}
	end
	if line:match("^Status:") then
		return {
			line_hl_group = "AcpStatus",
			badge = " LIVE ",
			badge_hl = "AcpBadgeStatus",
			sign_text = "R>",
			separator = "---- STATUS: Live ----",
		}
	end
	if line:match("^Tool") then
		return {
			line_hl_group = "AcpTool",
			badge = " TOOL ",
			badge_hl = "AcpBadgeTool",
			sign_text = "T>",
			separator = M.activity_separator(line),
		}
	end
	if line:match("^Terminal:") then
		return {
			line_hl_group = "AcpTerminal",
			badge = " TERM ",
			badge_hl = "AcpBadgeTool",
			sign_text = "$>",
			separator = M.activity_separator(line),
		}
	end
	if line:match("^Terminal output truncated") then
		return {
			line_hl_group = "AcpWarning",
			badge = " WARN ",
			badge_hl = "AcpBadgeWarn",
			sign_text = "W!",
			separator = M.activity_separator(line),
		}
	end
	if line:match("^Wrote ") then
		return {
			line_hl_group = "AcpFile",
			badge = " FILE ",
			badge_hl = "AcpBadgeUser",
			sign_text = "F>",
			separator = "---- FILE WRITE ----",
		}
	end
	if line:match("^Thought:") then
		return {
			line_hl_group = "AcpThought",
			badge = " NOTE ",
			badge_hl = "AcpBadge",
			sign_text = "N>",
			separator = "---- NOTE ----",
		}
	end
	if line:match("^stderr:") then
		return {
			line_hl_group = "AcpError",
			badge = " STDERR ",
			badge_hl = "AcpBadgeError",
			sign_text = "!>",
			separator = M.activity_separator(line),
		}
	end
end

function M.is_section(line)
	return line == "You"
		or line == "Agent"
		or line:match("^ACP:")
		or line:match("^Status:")
		or line:match("^Tool")
		or line:match("^Terminal:")
		or line:match("^Terminal output truncated")
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
	if line:match("^Terminal output truncated") then
		return "TERM", "Output truncated"
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
	local total = #(lines or {})
	for index, line in ipairs(lines or {}) do
		if M.is_section(line) then
			local kind, title = section_label(line)
			table.insert(sections, {
				line = index,
				kind = kind,
				title = clean(title) or kind,
				preview = preview_after(lines, index),
				total_lines = total,
			})
		end
	end
	return sections
end

function M.current_section(lines, lnum)
	lines = lines or {}
	local current = math.max(1, math.min(tonumber(lnum) or 1, #lines))
	for index = current, 1, -1 do
		if M.is_section(lines[index]) then
			local kind, title = section_label(lines[index])
			return {
				line = index,
				kind = kind,
				title = clean(title) or kind,
				preview = preview_after(lines, index),
			}
		end
	end
end

function M.section_range(lines, lnum)
	lines = lines or {}
	local section = M.current_section(lines, lnum)
	if not section then
		return nil
	end

	local line2 = #lines
	for index = section.line + 1, #lines do
		if M.is_section(lines[index]) then
			line2 = index - 1
			break
		end
	end

	return {
		line1 = section.line,
		line2 = math.max(section.line, line2),
		kind = section.kind,
		title = section.title,
		preview = section.preview,
	}
end

function M.section_lines(lines, lnum, opts)
	lines = lines or {}
	opts = opts or {}
	local range = M.section_range(lines, lnum)
	if not range then
		return nil
	end

	local section_lines = {}
	for index = range.line1, range.line2 do
		table.insert(section_lines, lines[index] or "")
	end

	if opts.trim_blank ~= false then
		while #section_lines > 1 and not clean(section_lines[#section_lines]) do
			table.remove(section_lines)
		end
	end

	return section_lines, range
end

function M.section_text(lines, lnum, opts)
	local section_lines, range = M.section_lines(lines, lnum, opts)
	if not section_lines then
		return nil
	end
	return table.concat(section_lines, "\n"), range, section_lines
end

local function section_body(lines, range)
	local body = {}
	if not range then
		return body
	end

	for index = range.line1 + 1, range.line2 do
		table.insert(body, lines[index] or "")
	end
	while #body > 0 and not clean(body[#body]) do
		table.remove(body)
	end
	return body
end

local function section_summary_label(body)
	local line_count = 0
	local word_count = 0
	for _, line in ipairs(body or {}) do
		if clean(line) then
			line_count = line_count + 1
			for _ in tostring(line):gmatch("%S+") do
				word_count = word_count + 1
			end
		end
	end

	if line_count == 0 then
		return nil
	end

	local code_count = #M.code_blocks(body)
	if code_count > 0 then
		return ("%dL | %d code"):format(line_count, code_count), {
			lines = line_count,
			words = word_count,
			code_blocks = code_count,
		}
	end

	return ("%dL | %dw"):format(line_count, word_count), {
		lines = line_count,
		words = word_count,
		code_blocks = 0,
	}
end

function M.section_summaries(lines)
	lines = lines or {}
	local summaries = {}
	local sections = M.sections(lines)

	for index, section in ipairs(sections) do
		if section.kind ~= "SESSION" then
			local next_section = sections[index + 1]
			local range = {
				line1 = section.line,
				line2 = next_section and (next_section.line - 1) or #lines,
			}
			local label, metrics = section_summary_label(section_body(lines, range))
			if label then
				metrics.line = section.line
				metrics.kind = section.kind
				metrics.label = (" %s "):format(label)
				summaries[section.line] = metrics
			end
		end
	end

	return summaries
end

function M.section_timeline(lines)
	local markers = {}
	local sections = M.sections(lines)
	local count = #sections

	for index, section in ipairs(sections) do
		local progress = position_percent(section.line, section.total_lines) or "   ?"
		markers[section.line] = {
			index = index,
			total = count,
			line = section.line,
			kind = section.kind,
			progress = progress,
			label = (" %d/%d %s "):format(index, count, progress),
		}
	end

	return markers
end

function M.statuscolumn_marker(lines, lnum, opts)
	opts = opts or {}
	lines = lines or {}
	lnum = math.max(1, math.min(tonumber(lnum) or 1, #lines))
	if not lines[lnum] then
		return "  "
	end

	local problem = M.problem_diagnostic_at(lines, lnum)
	if problem then
		return problem.severity == vim.diagnostic.severity.WARN and "W!" or "E!"
	end

	local block = M.code_block_at(lines, lnum)
	if block then
		if lnum == block.start_line then
			return "C>"
		end
		if lnum == block.end_line and block.closed then
			return "C<"
		end
		return "C|"
	end

	if M.file_reference_at(lines, lnum, 0, { cwd = opts.cwd }) then
		return "R>"
	end

	local section_index = 0
	local inside_section = false

	for index = 1, lnum do
		if M.is_section(lines[index]) then
			section_index = section_index + 1
			inside_section = true
			if index == lnum then
				return section_index < 100 and ("%02d"):format(section_index) or "++"
			end
		end
	end

	return inside_section and " |" or "  "
end

function M.outline_lines(sections, opts)
	opts = opts or {}
	local lines = { "ACP Output Outline", "" }
	local line_sections = {}
	local total = opts.total_lines
	for _, section in ipairs(sections or {}) do
		total = total or section.total_lines
		local title = section.title
		if #title > 88 then
			title = title:sub(1, 85) .. "..."
		end
		local progress = position_percent(section.line, total) or "   ?"
		table.insert(lines, ("%4d  %s  %-7s  %s"):format(section.line, progress, section.kind, title))
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

local map_kind_priority = {
	section = 1,
	problem = 2,
	code = 3,
	reference = 4,
}

local map_kind_tokens = {
	section = "SEC",
	problem = "ERR",
	code = "COD",
	reference = "REF",
}

function M.output_map_entries(lines, opts)
	opts = opts or {}
	lines = lines or {}
	local entries = {}
	local total = #lines

	for _, section in ipairs(M.sections(lines)) do
		table.insert(entries, {
			kind = "section",
			line = section.line,
			col = 1,
			label = ("%s: %s"):format(section.kind or "SECTION", section.title or "section"),
			total_lines = total,
		})
	end

	for _, item in ipairs(M.output_items(lines, opts)) do
		table.insert(entries, {
			kind = item.kind or "item",
			line = item.line or 1,
			line2 = item.line2,
			col = item.col or 1,
			label = item.label or item.kind or "item",
			total_lines = total,
		})
	end

	table.sort(entries, function(left, right)
		if left.line == right.line then
			return (map_kind_priority[left.kind] or 9) < (map_kind_priority[right.kind] or 9)
		end
		return left.line < right.line
	end)
	return entries
end

function M.progress_bar(line, total, width)
	return progress_bar(line, total, width)
end

function M.output_map_summary(entries)
	local counts = {
		total = 0,
		section = 0,
		problem = 0,
		code = 0,
		reference = 0,
	}
	for _, entry in ipairs(entries or {}) do
		counts.total = counts.total + 1
		local kind = entry.kind
		if counts[kind] ~= nil then
			counts[kind] = counts[kind] + 1
		end
	end
	return ("Entries: %d | sections %d | problems %d | code %d | refs %d"):format(
		counts.total,
		counts.section,
		counts.problem,
		counts.code,
		counts.reference
	)
end

function M.output_map_lines(entries, opts)
	opts = opts or {}
	local lines = { "ACP Output Map", M.output_map_summary(entries), "" }
	local line_entries = {}
	local current_line = tonumber(opts.current_line)
	local total = tonumber(opts.total_lines)

	for _, entry in ipairs(entries or {}) do
		total = total or entry.total_lines
		local label = clean(entry.label) or entry.kind or "item"
		if #label > 44 then
			label = label:sub(1, 41) .. "..."
		end
		local line1 = tonumber(entry.line) or 1
		local line2 = tonumber(entry.line2) or line1
		local marker = current_line and current_line >= line1 and current_line <= line2 and ">" or " "
		local progress = position_percent(line1, total) or "   ?"
		local bar = progress_bar(line1, total, opts.bar_width or 10)
		local token = map_kind_tokens[entry.kind] or "ITM"
		table.insert(lines, ("%s %s  %4d  %s  %-3s  %-9s  %s"):format(
			marker,
			bar,
			line1,
			progress,
			token,
			(entry.kind or "item"):upper(),
			label
		))
		line_entries[#lines] = entry
	end

	if #lines == 3 then
		table.insert(lines, "No transcript map entries yet")
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to jump, K to preview, Q for quickfix, or q/<Esc> to close.")
	return lines, line_entries
end

local function output_line_context(lines, entry)
	if not entry or not entry.line then
		return nil
	end

	lines = lines or {}
	local line_count = #lines
	if line_count == 0 then
		return nil
	end

	local line = math.max(1, math.min(entry.line, line_count))
	local start_line = math.max(1, line - 5)
	local end_line = math.min(line_count, line + 5)
	local preview = {}
	for index = start_line, end_line do
		local marker = index == line and ">" or " "
		table.insert(preview, ("%s %4d  %s"):format(marker, index, lines[index] or ""))
	end

	return {
		lines = preview,
		filetype = "acp",
		title = (" ACP output line %d "):format(line),
		cursor_line = line - start_line + 1,
	}
end

function M.output_map_preview(lines, entry)
	if not entry then
		return nil
	end

	lines = lines or {}
	if entry.kind == "code" then
		local block = M.code_block_at(lines, entry.line)
		if block then
			return {
				lines = block.lines,
				filetype = block.filetype or "text",
				title = (" ACP %s code lines %d-%d "):format(
					block.language or "code",
					block.start_line or 1,
					block.end_line or 1
				),
				cursor_line = 1,
			}
		end
	end

	if entry.kind == "section" then
		local section_lines, range = M.section_lines(lines, entry.line, { trim_blank = false })
		if section_lines and range then
			return {
				lines = section_lines,
				filetype = "acp",
				title = (" ACP %s section lines %d-%d "):format(
					range.kind or "output",
					range.line1 or 1,
					range.line2 or 1
				),
				cursor_line = 1,
			}
		end
	end

	return output_line_context(lines, entry)
end

function M.output_map_quickfix_items(entries, bufnr)
	local items = {}
	for _, entry in ipairs(entries or {}) do
		local kind = (entry.kind or "item"):upper()
		local label = clean(entry.label) or "ACP output map entry"
		table.insert(items, {
			bufnr = bufnr,
			lnum = entry.line or 1,
			col = entry.col or 1,
			text = ("%s: %s"):format(kind, label),
		})
	end
	return items
end

function M.animation_frame(index)
	local number = tonumber(index) or 1
	return animation_frames[((number - 1) % #animation_frames) + 1]
end

function M.motion_frame(index)
	local number = tonumber(index) or 1
	return motion_frames[((number - 1) % #motion_frames) + 1]
end

function M.activity_badge(state, stats, frame)
	stats = stats or {}
	local status = clean(state and state.run_status)
	local busy = state and state.busy
	status = status or (busy and "running" or "idle")
	if #status > 28 then
		status = status:sub(1, 25) .. "..."
	end

	local prefix = busy and (M.animation_frame(frame) .. " ") or ""
	local label = ("%s%s | %d section%s | %d code | %d loc%s | %d change%s"):format(
		prefix,
		status,
		stats.sections or 0,
		stats.sections == 1 and "" or "s",
		stats.code_blocks or 0,
		stats.locations or 0,
		stats.locations == 1 and "" or "s",
		stats.changes or 0,
		stats.changes == 1 and "" or "s"
	)
	if busy then
		label = ("%s | %s"):format(label, M.motion_frame(frame))
	end

	local lower_status = status:lower()
	local hl = "AcpOutputIdle"
	if lower_status:find("error", 1, true) or lower_status:find("failed", 1, true) then
		hl = "AcpBadgeError"
	elseif busy then
		hl = "AcpOutputActivity"
	elseif
		lower_status:find("done", 1, true)
		or lower_status:find("stopped", 1, true)
		or lower_status:find("restored", 1, true)
	then
		hl = "AcpStatusDone"
	end

	return (" %s "):format(label), hl
end

function M.live_status_label(state, frame)
	local status = clean(state and state.run_status) or "working"
	if #status > 32 then
		status = status:sub(1, 29) .. "..."
	end
	return (" %s live: %s %s "):format(M.animation_frame(frame), status, M.motion_frame(frame)), "AcpOutputLive"
end

function M.ghost_text(state, lines, frame)
	return flatten_chunks(M.ghost_text_chunks(state, lines, frame))
end

function M.ghost_text_chunks(state, lines, frame)
	lines = lines or {}
	local stats = M.transcript_stats(lines)
	if state and state.busy then
		return {
			{ ("%s %s "):format(M.animation_frame(frame), M.motion_frame(frame)), "AcpOutputLive" },
			{ clean(state.run_status) or "working", "AcpOutputActivity" },
			{ " | ", "AcpOutputSkylineDim" },
			{ "FLOW ", "AcpOutputSkyline" },
			{ M.skyline(lines, { width = 18 }), "AcpOutputRail" },
			{
				(" | %d sections | %d code | %d refs"):format(
					stats.sections or 0,
					stats.code_blocks or 0,
					stats.locations or 0
				),
				"AcpGhostText",
			},
		}
	end

	if #M.sections(lines) <= 1 then
		return {
			{ "Ready", "AcpOutputSkyline" },
			{ " - draft in prompt | ? actions | <leader>ax search", "AcpGhostText" },
		}
	end

	return {
		{ "Idle ", "AcpOutputIdle" },
		{ M.skyline(lines, { width = 18 }), "AcpOutputRail" },
		{
			(" | %d sections | %d code | %d refs | [[/]] sections | <leader>av outline"):format(
				stats.sections or 0,
				stats.code_blocks or 0,
				stats.locations or 0
			),
			"AcpGhostText",
		},
	}
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

function M.code_block_at(lines, lnum)
	local line = tonumber(lnum) or 1
	for _, block in ipairs(M.code_blocks(lines)) do
		if line >= block.start_line and line <= block.end_line then
			return block
		end
	end
	return nil
end

function M.code_block_text(block)
	if not block or not block.lines then
		return nil
	end
	return table.concat(block.lines, "\n")
end

function M.code_block_lens(block, injection_active, frame)
	block = block or {}
	local language = clean(block.language) or "text"
	if #language > 18 then
		language = language:sub(1, 15) .. "..."
	end
	local filetype = clean(block.filetype) or M.filetype_for_language(language)
	if #filetype > 18 then
		filetype = filetype:sub(1, 15) .. "..."
	end
	local line_count = tonumber(block.line_count) or 0
	local count = ("%d line%s"):format(line_count, line_count == 1 and "" or "s")
	local injection = injection_active and "Tree-sitter injection" or "fence detection"
	local state = block.closed == false and ("live " .. M.animation_frame(frame)) or "ready"
	local body_line1 = (block.start_line or 1) + 1
	local body_line2 = block.closed == false and (block.end_line or body_line1) or ((block.end_line or body_line1) - 1)
	if body_line2 < body_line1 then
		body_line1 = block.start_line or 1
		body_line2 = block.end_line or body_line1
	end
	local scope = ("L%d-%d"):format(body_line1, body_line2)
	local injection_hl = injection_active and "AcpInjectedLanguageActive" or "AcpInjectedLanguage"
	local state_hl = block.closed == false and "AcpOutputLive" or "AcpCodeBlockLensMuted"
	return {
		{ " CODE ", "AcpCodeBlockHeader" },
		{ language, "AcpInjectedLanguage" },
		{ (" -> %s "):format(filetype), "AcpCodeBlockHeader" },
		{ ("| %s | "):format(count), "AcpCodeBlockLensMuted" },
		{ ("%s | "):format(scope), "AcpOutputSkylineDim" },
		{ injection, injection_hl },
		{ (" | %s | "):format(state), state_hl },
		{ "<Enter> open | <leader>aY yank ", "AcpOutputHint" },
	}
end

function M.code_block_header(block, injection_active, frame)
	local text = {}
	for _, chunk in ipairs(M.code_block_lens(block, injection_active, frame)) do
		table.insert(text, chunk[1])
	end
	return table.concat(text)
end

function M.injected_languages(lines)
	local languages = {}
	local seen = {}
	for _, block in ipairs(M.code_blocks(lines)) do
		local filetype = clean(block.filetype) or M.filetype_for_language(block.language)
		if filetype and not seen[filetype] then
			seen[filetype] = true
			table.insert(languages, filetype)
		end
	end
	return languages
end

function M.injection_ranges(lines)
	local ranges = {}
	for _, block in ipairs(M.code_blocks(lines)) do
		local line1 = block.start_line + 1
		local line2 = block.closed and (block.end_line - 1) or block.end_line
		if line2 < line1 then
			line1 = block.start_line
			line2 = block.end_line
		end
		table.insert(ranges, {
			line1 = line1,
			line2 = line2,
			fence_line = block.start_line,
			language = clean(block.language) or "text",
			filetype = clean(block.filetype) or M.filetype_for_language(block.language),
			line_count = block.line_count or 0,
			closed = block.closed ~= false,
		})
	end
	return ranges
end

function M.injection_badge_chunks(block, injection_active, frame)
	block = block or {}
	local filetype = clean(block.filetype) or M.filetype_for_language(block.language)
	local line1 = (block.start_line or 1) + 1
	local line2 = block.closed == false and (block.end_line or line1) or ((block.end_line or line1) - 1)
	if line2 < line1 then
		line1 = block.start_line or 1
		line2 = block.end_line or line1
	end
	local injection_hl = injection_active and "AcpInjectedLanguageActive" or "AcpInjectedLanguage"
	local injection_label = injection_active and "TS" or "fence"
	return {
		{ (" %s "):format(M.motion_frame(frame)), "AcpOutputMotion" },
		{ " INJECT ", injection_hl },
		{ ("%s "):format(filetype), "AcpInjectedLanguage" },
		{ ("%s L%d-%d "):format(injection_label, line1, line2), "AcpOutputSkylineDim" },
	}
end

function M.injection_badge(block, injection_active, frame)
	return flatten_chunks(M.injection_badge_chunks(block, injection_active, frame))
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
	table.insert(lines, "Press <Enter> to open a scratch buffer, Q for quickfix, / to filter, or q/<Esc> to close.")
	return lines, line_blocks
end

function M.code_block_quickfix_items(blocks, bufnr)
	local items = {}
	for _, block in ipairs(blocks or {}) do
		local language = clean(block.language) or "text"
		local line_count = tonumber(block.line_count) or 0
		table.insert(items, {
			bufnr = bufnr,
			lnum = block.start_line or 1,
			col = 1,
			text = ("CODE %s lines %d-%d (%d line%s)"):format(
				language,
				block.start_line or 1,
				block.end_line or block.start_line or 1,
				line_count,
				line_count == 1 and "" or "s"
			),
		})
	end
	return items
end

function M.file_references(lines, opts)
	opts = opts or {}
	local cwd = opts.cwd or vim.fn.getcwd()
	local limit = opts.limit or 120
	local references = {}
	local seen = {}

	for source_line, line in ipairs(lines or {}) do
		each_reference_token(line, function(token, first, last)
			local reference = reference_from_token(token, {
				cwd = cwd,
				source_line = source_line,
				source_col = first,
				source_end_col = last,
				source_text = line,
			})
			if reference then
				local key = ("%s:%d:%d"):format(reference.path, reference.line, reference.column)
				if not seen[key] then
					seen[key] = true
					table.insert(references, reference)
					if #references >= limit then
						return references
					end
				end
			end
		end)
		if #references >= limit then
			return references
		end
	end

	return references
end

function M.file_reference_at(lines, lnum, col, opts)
	opts = opts or {}
	lines = lines or {}
	local source_line = math.max(1, math.min(tonumber(lnum) or 1, #lines))
	local line = lines[source_line]
	if not line then
		return nil
	end

	local cursor_col = (tonumber(col) or 0) + 1
	local fallback
	each_reference_token(line, function(token, first, last)
		local reference = reference_from_token(token, {
			cwd = opts.cwd or vim.fn.getcwd(),
			source_line = source_line,
			source_col = first,
			source_end_col = last,
			source_text = line,
		})
		if not reference then
			return
		end

		fallback = fallback or reference
		if cursor_col >= first and cursor_col <= last + 1 then
			fallback = reference
		end
	end)
	return fallback
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
	table.insert(lines, "Press <Enter> to jump, Q for quickfix, / to filter, or q/<Esc> to close.")
	return lines, line_references
end

function M.file_reference_quickfix_items(references)
	local items = {}
	for _, reference in ipairs(references or {}) do
		table.insert(items, {
			filename = reference.path,
			lnum = reference.line or 1,
			col = reference.column or 1,
			text = reference.source_text or reference.display_path or reference.path,
		})
	end
	return items
end

function M.reference_badge(count)
	local number = tonumber(count) or 0
	if number <= 1 then
		return " REF "
	end
	return (" REF x%d "):format(number)
end

function M.problem_diagnostics(lines)
	local items = {}
	for index, line in ipairs(lines or {}) do
		local severity
		local message

		if line:match("^Status:%s+error") then
			severity = vim.diagnostic.severity.ERROR
			message = clean(line:gsub("^Status:%s*", "")) or "ACP status error"
		elseif line:match("^stderr:") then
			severity = vim.diagnostic.severity.ERROR
			local preview = preview_after(lines, index)
			message = preview and ("stderr: %s"):format(preview) or "stderr output"
		elseif line:match("^Terminal output truncated") then
			severity = vim.diagnostic.severity.WARN
			message = clean(line) or "Terminal output truncated"
		end

		if severity then
			table.insert(items, {
				lnum = index - 1,
				col = 0,
				end_lnum = index - 1,
				end_col = #line,
				severity = severity,
				source = "acp.nvim",
				message = message,
			})
		end
	end
	return items
end

function M.problem_diagnostic_at(lines, lnum)
	local target = (tonumber(lnum) or 1) - 1
	for _, item in ipairs(M.problem_diagnostics(lines)) do
		if item.lnum == target then
			return item
		end
	end
	return nil
end

function M.current_output_item(lines, lnum, col, opts)
	opts = opts or {}
	lines = lines or {}
	local line_number = math.max(1, math.min(tonumber(lnum) or 1, #lines))
	local target

	local reference = M.file_reference_at(lines, line_number, col, { cwd = opts.cwd })
	if reference then
		target = {
			kind = "reference",
			line = reference.source_line or line_number,
			col = reference.source_col or 1,
		}
	else
		local block = M.code_block_at(lines, line_number)
		if block then
			target = {
				kind = "code",
				line = block.start_line or line_number,
				line2 = block.end_line or block.start_line or line_number,
				col = 1,
			}
		elseif M.problem_diagnostic_at(lines, line_number) then
			target = {
				kind = "problem",
				line = line_number,
				col = 1,
			}
		end
	end

	if not target then
		return nil
	end

	local items = M.output_items(lines, opts)
	for index, item in ipairs(items) do
		if item.kind == target.kind and item.line == target.line and item.col == target.col then
			return {
				index = index,
				total = #items,
				kind = item.kind,
				line = item.line,
				line2 = target.line2 or item.line,
				col = item.col,
				label = item.label,
			}
		end
	end
	return nil
end

function M.output_items(lines, opts)
	opts = opts or {}
	lines = lines or {}
	local items = {}
	local order = {
		problem = 1,
		reference = 2,
		code = 3,
	}

	for _, item in ipairs(M.problem_diagnostics(lines)) do
		table.insert(items, {
			kind = "problem",
			line = (item.lnum or 0) + 1,
			col = (item.col or 0) + 1,
			label = item.message,
			total_lines = #lines,
		})
	end
	for _, reference in ipairs(M.file_references(lines, { cwd = opts.cwd })) do
		table.insert(items, {
			kind = "reference",
			line = reference.source_line or 1,
			col = reference.source_col or 1,
			label = ("%s:%d:%d"):format(reference.display_path or reference.path or "?", reference.line or 1, reference.column or 1),
			total_lines = #lines,
		})
	end
	for _, block in ipairs(M.code_blocks(lines)) do
		table.insert(items, {
			kind = "code",
			line = block.start_line or 1,
			line2 = block.end_line or block.start_line or 1,
			col = 1,
			label = ("%s code block"):format(block.language or "text"),
			total_lines = #lines,
		})
	end

	table.sort(items, function(left, right)
		if left.line ~= right.line then
			return left.line < right.line
		end
		if left.col ~= right.col then
			return left.col < right.col
		end
		return (order[left.kind] or 99) < (order[right.kind] or 99)
	end)
	return items
end

function M.output_item_lines(items, opts)
	opts = opts or {}
	local lines = { "ACP Output Items", "" }
	local line_items = {}
	local total = opts.total_lines

	for _, item in ipairs(items or {}) do
		total = total or item.total_lines
		local label = clean(item.label) or item.kind or "item"
		if #label > 96 then
			label = label:sub(1, 93) .. "..."
		end
		local progress = position_percent(item.line, total) or "   ?"
		table.insert(lines, ("%4d  %s  %-9s  %s"):format(item.line or 1, progress, (item.kind or "item"):upper(), label))
		line_items[#lines] = item
	end

	table.insert(lines, "")
	table.insert(lines, "Type / to filter, press <Enter> to jump, Q for quickfix, or q/<Esc> to close.")
	return lines, line_items
end

function M.output_item_quickfix_items(items, bufnr)
	local qf_items = {}
	for _, item in ipairs(items or {}) do
		local kind = (item.kind or "item"):upper()
		local label = clean(item.label) or "ACP output item"
		table.insert(qf_items, {
			bufnr = bufnr,
			lnum = item.line or 1,
			col = item.col or 1,
			text = ("%s: %s"):format(kind, label),
		})
	end
	return qf_items
end

function M.next_output_item(lines, current, direction, opts)
	direction = tonumber(direction) or 1
	direction = direction < 0 and -1 or 1
	current = tonumber(current) or 1
	local items = M.output_items(lines, opts)
	if direction > 0 then
		for _, item in ipairs(items) do
			if item.line > current then
				return item
			end
		end
		return nil
	end

	for index = #items, 1, -1 do
		local item = items[index]
		if item.line < current then
			return item
		end
	end
	return nil
end

local skyline_priority = {
	["."] = 0,
	S = 1,
	R = 2,
	C = 3,
	E = 4,
	[">"] = 5,
}

local function skyline_mark(cells, total, line, token)
	local width = #cells
	if width == 0 then
		return
	end
	local position = 1
	if total > 1 then
		position = math.floor((((tonumber(line) or 1) - 1) / (total - 1)) * (width - 1) + 1.5)
	end
	position = math.max(1, math.min(width, position))
	local current = cells[position] or "."
	if (skyline_priority[token] or 0) >= (skyline_priority[current] or 0) then
		cells[position] = token
	end
end

function M.skyline(lines, opts)
	opts = opts or {}
	lines = lines or {}
	local width = math.max(8, tonumber(opts.width) or 24)
	local cells = {}
	for index = 1, width do
		cells[index] = "."
	end

	local total = #lines
	if total == 0 then
		return "[" .. table.concat(cells) .. "]"
	end

	for _, section in ipairs(M.sections(lines)) do
		skyline_mark(cells, total, section.line, "S")
	end
	for _, item in ipairs(M.output_items(lines, opts)) do
		local token = item.kind == "problem" and "E" or item.kind == "code" and "C" or item.kind == "reference" and "R" or "."
		skyline_mark(cells, total, item.line, token)
	end
	if opts.current_line then
		skyline_mark(cells, total, opts.current_line, ">")
	end

	return "[" .. table.concat(cells) .. "]"
end

function M.skyline_chunks(lines, opts)
	opts = opts or {}
	lines = lines or {}
	local stats = M.transcript_stats(lines, {
		cwd = opts.cwd,
		change_count = opts.change_count,
		start_line = opts.start_line,
	})
	local languages = M.injected_languages(lines)
	local language_items = {}
	for index = 1, math.min(#languages, 3) do
		table.insert(language_items, languages[index])
	end
	local language_label = #language_items > 0 and table.concat(language_items, ",") or "none"
	local status = clean(opts.run_status) or (opts.busy and "working" or "idle")
	local status_hl = opts.busy and "AcpOutputLive" or "AcpOutputIdle"
	if #status > 24 then
		status = status:sub(1, 21) .. "..."
	end
	local injection = opts.language_injection and "Tree-sitter" or "fence"
	return {
		{ " FLOW ", "AcpOutputSkyline" },
		{ M.skyline(lines, { width = opts.width or 24, current_line = opts.current_line, cwd = opts.cwd }), "AcpOutputRail" },
		{ (" %s "):format(M.animation_frame(opts.frame)), "AcpOutputSpark" },
		{
			("sections %d | code %d | refs %d | changes %d | "):format(
				stats.sections or 0,
				stats.code_blocks or 0,
				stats.locations or 0,
				stats.changes or 0
			),
			"AcpOutputSkylineDim",
		},
		{ ("inject %s:%s | "):format(injection, language_label), opts.language_injection and "AcpInjectedLanguageActive" or "AcpInjectedLanguage" },
		{ status, status_hl },
	}
end

function M.skyline_text(lines, opts)
	return flatten_chunks(M.skyline_chunks(lines, opts))
end

local function output_item_hl(kind)
	if kind == "problem" then
		return "AcpBadgeError"
	end
	if kind == "code" then
		return "AcpCodeBlockHeader"
	end
	if kind == "reference" then
		return "AcpOutputReferenceBadge"
	end
	return "AcpSectionStats"
end

function M.cursor_ribbon_chunks(lines, lnum, col, opts)
	opts = opts or {}
	lines = lines or {}
	if #lines == 0 then
		return nil
	end

	local line_number = math.max(1, math.min(tonumber(lnum) or 1, #lines))
	local section = M.current_section(lines, line_number)
	local range = M.section_range(lines, line_number)
	local item = M.current_output_item(lines, line_number, col, opts)
	local nearby = item
		or M.next_output_item(lines, line_number, 1, opts)
		or M.next_output_item(lines, line_number, -1, opts)
	local section_kind = section and section.kind or "TEXT"
	local title = short_label(section and section.title or clean(lines[line_number]) or "output", 30)
	local span = range and ("L%d-%d"):format(range.line1, range.line2) or ("L%d"):format(line_number)
	local progress = position_percent(line_number, #lines) or "  ?"
	local item_kind = nearby and nearby.kind or nil
	local item_label = nearby and short_label(nearby.label or nearby.kind, 26) or nil

	local chunks = {
		{ " CTX ", "AcpOutputSkyline" },
		{ progress .. " ", "AcpOutputTimeline" },
		{
			M.skyline(lines, { width = opts.width or 22, current_line = line_number, cwd = opts.cwd }),
			"AcpOutputRail",
		},
		{ " | ", "AcpOutputSkylineDim" },
		{ (" %s "):format(section_kind), "AcpSectionStats" },
		{ title, "AcpOutputHint" },
		{ (" %s"):format(span), "AcpOutputSkylineDim" },
	}

	if item_kind then
		local prefix = item and " | ITEM " or " | NEAR "
		table.insert(chunks, { prefix, output_item_hl(item_kind) })
		table.insert(chunks, { (item_kind or "item"):upper(), output_item_hl(item_kind) })
		table.insert(chunks, { item_label and (" " .. item_label) or "", "AcpOutputHint" })
	else
		table.insert(chunks, { " | [[/]] sections | ]o/[o items", "AcpOutputHint" })
	end

	return chunks
end

function M.cursor_ribbon(lines, lnum, col, opts)
	local chunks = M.cursor_ribbon_chunks(lines, lnum, col, opts)
	if not chunks then
		return nil
	end
	return flatten_chunks(chunks)
end

function M.cursor_hint_chunks(lines, lnum, col, opts)
	opts = opts or {}
	lines = lines or {}
	local line_number = math.max(1, math.min(tonumber(lnum) or 1, #lines))
	local line = lines[line_number]
	if not line then
		return nil
	end

	if M.file_reference_at(lines, line_number, col, { cwd = opts.cwd }) then
		return {
			{ " REF ", "AcpOutputReferenceBadge" },
			{ " ? menu | K inspect | <Enter> open ref | ]o/[o items", "AcpOutputHint" },
		}
	end

	local block = M.code_block_at(lines, line_number)
	if block then
		local filetype = clean(block.filetype) or M.filetype_for_language(block.language)
		local injection = opts.language_injection and "Tree-sitter injection" or "fence detection"
		local injection_hl = opts.language_injection and "AcpInjectedLanguageActive" or "AcpInjectedLanguage"
		return {
			{ " CODE ", "AcpCodeBlockHeader" },
			{ ("code %s "):format(filetype), "AcpInjectedLanguage" },
			{ ("%s "):format(injection), injection_hl },
			{ "? menu | K inspect | <Enter> open code | <leader>aY yank | ]o/[o items", "AcpOutputHint" },
		}
	end

	if line:match("^Status:%s+error") or line:match("^stderr:") or line:match("^Terminal output truncated") then
		return {
			{ " PROBLEM ", "AcpBadgeError" },
			{ " ? menu | K inspect | ]o/[o items | <leader>ae problems", "AcpOutputHint" },
		}
	end

	if M.is_section(line) then
		return {
			{ " SECTION ", "AcpSectionStats" },
			{ " ? menu | K inspect | <leader>ai draft | <leader>ay yank", "AcpOutputHint" },
		}
	end
	return nil
end

function M.cursor_hint(lines, lnum, col, opts)
	local chunks = M.cursor_hint_chunks(lines, lnum, col, opts)
	if not chunks then
		return nil
	end
	return flatten_chunks(chunks)
end

function M.transcript_stats(lines, opts)
	opts = opts or {}
	local body = {}
	for index = opts.start_line or 1, #(lines or {}) do
		table.insert(body, lines[index])
	end

	return {
		sections = #M.sections(body),
		code_blocks = #M.code_blocks(body),
		locations = #M.file_references(body, { cwd = opts.cwd }),
		changes = opts.change_count or 0,
	}
end

function M.transcript_entries(lines, opts)
	opts = opts or {}
	local limit = opts.limit or 500
	local entries = {}
	local total = #(lines or {})

	for index, line in ipairs(lines or {}) do
		local text = clean(line)
		if text then
			local kind = "TEXT"
			if M.is_section(line) then
				kind = section_label(line)
			end
			table.insert(entries, {
				line = index,
				kind = kind,
				text = text,
				total_lines = total,
			})
			if #entries >= limit then
				return entries
			end
		end
	end

	return entries
end

function M.transcript_entry_lines(entries, opts)
	opts = opts or {}
	local lines = { "ACP Output Search", "" }
	local line_entries = {}
	local total = opts.total_lines

	for _, entry in ipairs(entries or {}) do
		total = total or entry.total_lines
		local text = entry.text or ""
		if #text > 104 then
			text = text:sub(1, 101) .. "..."
		end
		local progress = position_percent(entry.line, total) or "   ?"
		table.insert(lines, ("%4d  %s  %-7s  %s"):format(entry.line or 1, progress, entry.kind or "TEXT", text))
		line_entries[#lines] = entry
	end

	table.insert(lines, "")
	table.insert(lines, "Type / to filter, press <Enter> to jump, or q/<Esc> to close.")
	return lines, line_entries
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
