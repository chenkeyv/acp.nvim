local M = {}

local severity_order = {
	{ key = "ERROR", label = "E" },
	{ key = "WARN", label = "W" },
	{ key = "INFO", label = "I" },
	{ key = "HINT", label = "H" },
}

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function diagnostic_summary(bufnr, start_line, end_line)
	if not (vim.diagnostic and vim.diagnostic.severity and valid_buf(bufnr)) then
		return nil
	end

	local counts = {}
	for _, item in ipairs(severity_order) do
		counts[vim.diagnostic.severity[item.key]] = 0
	end

	for _, item in ipairs(vim.diagnostic.get(bufnr)) do
		local line = (item.lnum or 0) + 1
		if line >= start_line and line <= end_line and counts[item.severity] ~= nil then
			counts[item.severity] = counts[item.severity] + 1
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
	return table.concat(badges, " ")
end

function M.define_highlights()
	vim.api.nvim_set_hl(0, "AcpSourceContext", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceLabel", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceDiagnostics", { link = "DiagnosticWarn", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceLens", { link = "DiagnosticInfo", default = true })
end

function M.marks(state)
	if not state or not state.source or not state.source.bufnr then
		return {}
	end

	local source = state.source
	local start_line = source.cursor and source.cursor[1] or 1
	local end_line = start_line
	if source.range then
		start_line = source.range.line1 or start_line
		end_line = source.range.line2 or start_line
	end
	if end_line < start_line then
		start_line, end_line = end_line, start_line
	end

	local status = state.run_status or (state.busy and "running" or "ready")
	local label = (" ACP #%s %s "):format(tostring(state.id or "?"), status)
	local diagnostics = diagnostic_summary(source.bufnr, start_line, end_line)
	local lens_diagnostics = diagnostics and ("diagnostics " .. diagnostics .. "  ") or ""
	local lens = (" ACP #%s source context  %s:AcpSourceActions focus/add/refresh/LSP/Tree-sitter "):format(
		tostring(state.id or "?"),
		lens_diagnostics
	)
	local marks = {}
	for line = start_line, end_line do
		table.insert(marks, {
			line = line,
			opts = {
				line_hl_group = "AcpSourceContext",
				priority = 50,
			},
		})
	end
	if #marks > 0 then
		marks[1].opts.virt_text = { { label, "AcpSourceLabel" } }
		if diagnostics then
			table.insert(marks[1].opts.virt_text, { diagnostics .. " ", "AcpSourceDiagnostics" })
		end
		marks[1].opts.virt_text_pos = "right_align"
		marks[1].opts.virt_lines = { { { lens, "AcpSourceLens" } } }
		marks[1].opts.virt_lines_above = true
		marks[1].opts.sign_text = "A>"
		marks[1].opts.sign_hl_group = "AcpSourceLabel"
	end
	return marks
end

return M
