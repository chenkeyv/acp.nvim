local icons = require("acp.icons")

local M = {}

local severity_order = {
	{ key = "ERROR", label = icons.error },
	{ key = "WARN", label = icons.warning },
	{ key = "INFO", label = icons.info },
	{ key = "HINT", label = icons.hint },
}

local function trim(text)
	return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function short(value, limit)
	local label = clean(value)
	if not label then
		return nil
	end
	limit = limit or 42
	if #label > limit then
		return label:sub(1, limit - 3) .. "..."
	end
	return label
end

local function word_count(text)
	local count = 0
	for _ in tostring(text or ""):gmatch("%S+") do
		count = count + 1
	end
	return count
end

local function format_count(value)
	local number = tonumber(value)
	if not number then
		return clean(value)
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
	if not (source and source.bufnr and vim.api.nvim_buf_is_valid(source.bufnr)) then
		return ("%s source none"):format(icons.source)
	end

	local name = vim.api.nvim_buf_get_name(source.bufnr)
	local path = name ~= "" and vim.fn.fnamemodify(name, ":.") or ("buffer " .. source.bufnr)
	local filetype = vim.bo[source.bufnr].filetype ~= "" and vim.bo[source.bufnr].filetype or "text"
	if source.range then
		return ("%s source %s:%d-%d [%s]"):format(icons.source, path, source.range.line1, source.range.line2, filetype)
	end
	local cursor = source.cursor or { 1, 0 }
	return ("%s source %s:%d [%s]"):format(icons.source, path, cursor[1] or 1, filetype)
end

local function source_lines(source)
	local start_line = source and source.cursor and source.cursor[1] or 1
	local end_line = start_line
	if source and source.range then
		start_line = source.range.line1 or start_line
		end_line = source.range.line2 or start_line
	end
	if end_line < start_line then
		start_line, end_line = end_line, start_line
	end
	return start_line, end_line
end

local function diagnostic_label(source)
	if
		not (
			vim.diagnostic
			and vim.diagnostic.severity
			and source
			and source.bufnr
			and vim.api.nvim_buf_is_valid(source.bufnr)
		)
	then
		return nil
	end

	local start_line, end_line = source_lines(source)
	local counts = {}
	for _, item in ipairs(severity_order) do
		counts[vim.diagnostic.severity[item.key]] = 0
	end

	for _, diagnostic in ipairs(vim.diagnostic.get(source.bufnr)) do
		local line = (diagnostic.lnum or 0) + 1
		if line >= start_line and line <= end_line and counts[diagnostic.severity] ~= nil then
			counts[diagnostic.severity] = counts[diagnostic.severity] + 1
		end
	end

	local badges = {}
	for _, item in ipairs(severity_order) do
		local count = counts[vim.diagnostic.severity[item.key]] or 0
		if count > 0 then
			table.insert(badges, ("%s%d"):format(item.label, count))
		end
	end
	if #badges == 0 then
		return nil
	end
	return ("%s diagnostics %s"):format(icons.diagnostics, table.concat(badges, " "))
end

local function ribbon_chunks(opts)
	opts = opts or {}
	local chunks = {
		{ (" %s ACP "):format(icons.acp), "AcpPromptBadge" },
	}
	local adapter = short(opts.adapter, 18)
	if adapter then
		table.insert(chunks, { (" %s %s "):format(icons.session, adapter), "AcpPromptRibbon" })
	end
	local model = short(opts.model, 28)
	if model then
		table.insert(chunks, { ("%s model %s "):format(icons.model, model), "AcpPromptMeta" })
	end
	local context_window = format_count(opts.context_window)
	if context_window then
		table.insert(chunks, { ("%s ctx %s "):format(icons.context, context_window), "AcpPromptMeta" })
	end
	local status = short(opts.run_status or (opts.busy and "running" or "ready"), 28)
	if status then
		table.insert(
			chunks,
			{ ("%s status %s "):format(icons.status, status), opts.busy and "AcpPromptBusy" or "AcpPromptMeta" }
		)
	end
	local diagnostics = diagnostic_label(opts.source)
	if diagnostics then
		table.insert(chunks, { diagnostics .. " ", "AcpPromptDiagnostics" })
	end
	table.insert(chunks, { short(source_label(opts.source), 64) or "source none", "AcpPromptSource" })
	if opts.blink then
		table.insert(chunks, { ("  %s blink"):format(icons.blink), "AcpPromptMeta" })
	end
	return chunks
end

function M.define_highlights()
	vim.api.nvim_set_hl(0, "AcpPromptGhost", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpPromptStats", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpPromptBadge", { fg = "#1a1b26", bg = "#9ece6a", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPromptRibbon", { fg = "#7aa2f7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPromptMeta", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpPromptBusy", { fg = "#1a1b26", bg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPromptDiagnostics", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "AcpPromptSource", { fg = "#7dcfff", default = true })
end

function M.info(lines, opts)
	opts = opts or {}
	lines = lines or { "" }
	local text = table.concat(lines, "\n")
	local content = trim(text)
	local ribbon = ribbon_chunks(opts)

	if content == "" then
		local hint = opts.busy and ("%s Agent is responding - <leader>aq stop"):format(icons.busy)
			or ("%s Ask ACP - <C-s> send | ? actions | @context completion"):format(icons.prompt)
		return {
			empty = true,
			ghost = hint,
			ribbon = ribbon,
		}
	end

	local line_count = math.max(1, #lines)
	local chars = vim.fn.strchars(text)
	local words = word_count(content)
	return {
		empty = false,
		ribbon = ribbon,
		stats = ("%d line%s | %d char%s | %d word%s"):format(
			line_count,
			line_count == 1 and "" or "s",
			chars,
			chars == 1 and "" or "s",
			words,
			words == 1 and "" or "s"
		),
	}
end

return M
