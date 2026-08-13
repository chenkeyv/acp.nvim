local icons = require("acp.icons")

local M = {}

local filetype_aliases = {
	bash = "sh",
	js = "javascript",
	jsx = "javascriptreact",
	lua = "lua",
	md = "markdown",
	py = "python",
	rb = "ruby",
	rs = "rust",
	sh = "sh",
	shell = "sh",
	ts = "typescript",
	yml = "yaml",
	zsh = "sh",
}

local reference_token_pattern = "[^%s%[%]%(%){}<>,;]+:%d+:?%d*"

function M.strip_ansi(value)
	return tostring(value or "")
		:gsub("\27%][^\7]*\7", "")
		:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
		:gsub("%^%[%[[0-?]*[ -/]*[@-~]", "")
end

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	local text = M.strip_ansi(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return text ~= "" and text or nil
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
	if not raw_path then
		raw_path = tostring(token or ""):gsub("^[`'\"]+", ""):gsub("[`'\"]+$", "")
		target_line = 1
		column = 1
	end
	local path = resolve_reference_path(raw_path, opts.cwd)
	if not path then
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
	local ranges = {}
	local start = 1
	while start <= #line do
		local first, last = line:find(reference_token_pattern, start)
		if not first then
			break
		end
		callback(line:sub(first, last), first, last)
		table.insert(ranges, { first, last })
		start = last + 1
	end
	start = 1
	while start <= #line do
		local first, last, token = line:find("`([^`]+)`", start)
		if not first then
			break
		end
		local duplicate = false
		for _, range in ipairs(ranges) do
			if first <= range[2] and last >= range[1] then
				duplicate = true
				break
			end
		end
		if not duplicate then
			callback(token, first + 1, last - 1)
		end
		start = last + 1
	end
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
	width = math.max(3, tonumber(width) or 10)
	total = tonumber(total) or 0
	if total <= 0 then
		return string.rep(icons.pulse_empty, width)
	end
	local ratio = math.max(0, math.min(1, (tonumber(line) or 1) / total))
	local filled = math.floor((ratio * width) + 0.5)
	if ratio > 0 then
		filled = math.max(1, filled)
	end
	filled = math.min(width, filled)
	return string.rep(icons.pulse_full, filled) .. string.rep(icons.pulse_empty, width - filled)
end

local function ui_hints(items)
	local parts = {}
	for _, item in ipairs(items or {}) do
		table.insert(parts, ("%s %s"):format(item[1] or icons.key, item[2] or ""))
	end
	return table.concat(parts, "  ")
end

function M.define_highlights()
	for name, definition in pairs({
		AcpBadge = { link = "Visual" },
		AcpInjectedCode = { link = "Visual" },
		AcpInjectedLanguage = { fg = "#1a1b26", bg = "#7aa2f7", bold = true },
		AcpOutputPulse = { link = "IncSearch" },
		AcpOutputPulseSoft = { link = "Search" },
		AcpOutputReference = { link = "Underlined" },
	}) do
		definition.default = true
		vim.api.nvim_set_hl(0, name, definition)
	end
end

local function plural(count, label)
	return ("%d %s%s"):format(count, label, count == 1 and "" or "s")
end

function M.activity_summary(group)
	local counts = (group and group.counts) or {}
	local parts = {}
	for _, entry in ipairs({
		{ "command", "command" },
		{ "tool", "tool" },
		{ "file", "file" },
	}) do
		local count = tonumber(counts[entry[1]]) or 0
		if count > 0 then
			table.insert(parts, plural(count, entry[2]))
		end
	end
	local count = tonumber(group and group.count) or 0
	local detail = #parts > 0 and table.concat(parts, " · ") or plural(count, "item")
	return ("%d completed · %s"):format(count, detail)
end

function M.activity_fold_text(group)
	local text = ("%s ACTIVITY  %s  <Enter>/K details"):format(icons.command, M.activity_summary(group))
	return #text > 120 and (text:sub(1, 117) .. "...") or text
end

function M.filetype_for_language(language)
	local value = clean(language)
	if not value then
		return "text"
	end
	value = value:lower()
	return filetype_aliases[value] or value
end

function M.code_block_text(block)
	if not block or not block.lines then
		return nil
	end
	return table.concat(block.lines, "\n")
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
				end
			end
		end)
		if #references >= limit then
			break
		end
	end
	while #references > limit do
		table.remove(references)
	end
	return references
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

function M.output_items(opts)
	opts = opts or {}
	local total_lines = tonumber(opts.total_lines) or 0
	local items = {}
	local order = { problem = 1, reference = 2, code = 3, activity = 4 }
	for _, diagnostic in ipairs(opts.diagnostics or {}) do
		table.insert(items, {
			kind = "problem",
			line = (diagnostic.lnum or 0) + 1,
			col = (diagnostic.col or 0) + 1,
			label = diagnostic.message,
			total_lines = total_lines,
			block_id = diagnostic.block_id,
		})
	end
	for _, reference in ipairs(opts.references or {}) do
		table.insert(items, {
			kind = "reference",
			line = reference.source_line or 1,
			col = reference.source_col or 1,
			end_col = reference.source_end_col or reference.source_col or 1,
			label = ("%s:%d:%d"):format(
				reference.display_path or reference.path or "?",
				reference.line or 1,
				reference.column or 1
			),
			total_lines = total_lines,
			block_id = reference.block_id,
		})
	end
	for _, block in ipairs(opts.blocks or {}) do
		table.insert(items, {
			kind = "code",
			line = block.start_line or 1,
			line2 = block.end_line or block.start_line or 1,
			col = 1,
			label = ("%s code block"):format(block.language or "text"),
			total_lines = total_lines,
			block_id = block.block_id,
		})
	end
	for _, activity in ipairs(opts.activities or {}) do
		table.insert(items, vim.tbl_extend("force", {}, activity, { total_lines = total_lines }))
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

local function output_item_icon(kind)
	return kind == "activity" and icons.command
		or kind == "problem" and icons.error
		or kind == "code" and icons.code
		or kind == "reference" and icons.reference
		or icons.section
end

function M.output_item_quickfix_items(items, bufnr)
	local quickfix = {}
	for _, item in ipairs(items or {}) do
		local kind = (item.kind or "item"):upper()
		local label = clean(item.label) or "ACP output item"
		table.insert(quickfix, {
			bufnr = bufnr,
			lnum = item.line or 1,
			col = item.col or 1,
			text = ("%s %s: %s"):format(output_item_icon(item.kind), kind, label),
		})
	end
	return quickfix
end

local map_kind_priority = { section = 1, activity = 2, problem = 3, code = 4, reference = 5 }
local map_kind_tokens = {
	section = icons.section,
	activity = icons.command,
	problem = icons.error,
	code = icons.code,
	reference = icons.reference,
}

function M.output_map_entries(opts)
	opts = opts or {}
	local entries = {}
	local total = tonumber(opts.total_lines) or 0
	for _, section in ipairs(opts.sections or {}) do
		table.insert(entries, {
			kind = "section",
			line = section.line,
			line2 = section.line2,
			col = 1,
			label = ("%s: %s"):format(section.kind or "SECTION", section.title or "section"),
			total_lines = total,
			block_id = section.block_id,
		})
	end
	for _, item in ipairs(opts.items or {}) do
		table.insert(entries, {
			kind = item.kind or "item",
			line = item.line or 1,
			line2 = item.line2,
			col = item.col or 1,
			label = item.label or item.kind or "item",
			total_lines = total,
			block_id = item.block_id,
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

function M.output_map_lines(entries, opts)
	opts = opts or {}
	local lines = { ("%s ACP Output Map"):format(icons.map), "" }
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
		local marker = current_line and current_line >= line1 and current_line <= line2 and icons.location
			or icons.pulse_empty
		local progress = position_percent(line1, total) or "   ?"
		local bar = progress_bar(line1, total, opts.bar_width or 10)
		local token = map_kind_tokens[entry.kind] or icons.map
		table.insert(
			lines,
			("%s %s  %4d  %s  %s  %-9s  %s"):format(
				marker,
				bar,
				line1,
				progress,
				token,
				(entry.kind or "item"):upper(),
				label
			)
		)
		line_entries[#lines] = entry
	end
	if #lines == 2 then
		table.insert(lines, ("%s No transcript map entries yet"):format(icons.note))
	end
	table.insert(lines, "")
	table.insert(
		lines,
		ui_hints({
			{ icons.enter, "<Enter> jump" },
			{ icons.inspect, "K preview" },
			{ icons.quickfix, "Q quickfix" },
			{ icons.close, "q/<Esc> close" },
		})
	)
	return lines, line_entries
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

return M
