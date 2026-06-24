local M = {}

function M.define_highlights()
	vim.api.nvim_set_hl(0, "AcpSourceContext", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceLabel", { link = "Comment", default = true })
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
	local lens = (" ACP #%s source context  :AcpSourceActions focus/add/refresh/LSP/Tree-sitter "):format(
		tostring(state.id or "?")
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
		marks[1].opts.virt_text_pos = "right_align"
		marks[1].opts.virt_lines = { { { lens, "AcpSourceLens" } } }
		marks[1].opts.virt_lines_above = true
		marks[1].opts.sign_text = "A>"
		marks[1].opts.sign_hl_group = "AcpSourceLabel"
	end
	return marks
end

return M
