local document_colors = require("acp.document_colors")
local document_links = require("acp.document_links")
local folding_ranges = require("acp.folding_ranges")

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

local function highlight_group(kind)
	if tonumber(kind) == 3 then
		return "AcpSourceHighlightWrite"
	end
	if tonumber(kind) == 2 then
		return "AcpSourceHighlightRead"
	end
	return "AcpSourceHighlightText"
end

local function highlight_marks(source, highlights)
	if not (source and valid_buf(source.bufnr)) then
		return {}
	end

	local line_count = vim.api.nvim_buf_line_count(source.bufnr)
	local marks = {}
	for _, item in ipairs(highlights or {}) do
		local range = item.range
		if range and range.line1 and range.line2 then
			local line1 = math.max(1, math.min(range.line1, line_count))
			local line2 = math.max(1, math.min(range.line2, line_count))
			if line2 < line1 then
				line1, line2 = line2, line1
			end
			for line = line1, line2 do
				local text = vim.api.nvim_buf_get_lines(source.bufnr, line - 1, line, false)[1] or ""
				local line_length = #text
				local start_col = line == line1 and math.max(0, (range.col1 or 1) - 1) or 0
				start_col = math.min(start_col, line_length)
				local end_col = line == line2 and math.max(start_col + 1, (range.col2 or start_col + 2) - 1) or line_length
				end_col = math.min(end_col, line_length)
				if end_col > start_col then
					table.insert(marks, {
						line = line,
						col = start_col,
						opts = {
							end_col = end_col,
							hl_group = highlight_group(item.kind),
							priority = 75,
						},
					})
				end
			end
		end
	end
	return marks
end

local function color_marks(source, colors)
	if not (source and valid_buf(source.bufnr)) then
		return {}
	end

	local line_count = vim.api.nvim_buf_line_count(source.bufnr)
	local marks = {}
	for _, item in ipairs(colors or {}) do
		local range = document_colors.range(item)
		if range and range.line1 and range.line2 then
			local line1 = math.max(1, math.min(range.line1, line_count))
			local line2 = math.max(1, math.min(range.line2, line_count))
			if line2 < line1 then
				line1, line2 = line2, line1
			end
			local color_hl = document_colors.highlight_group(item)
			for line = line1, line2 do
				local text = vim.api.nvim_buf_get_lines(source.bufnr, line - 1, line, false)[1] or ""
				local line_length = #text
				local start_col = line == line1 and math.max(0, (range.col1 or 1) - 1) or 0
				start_col = math.min(start_col, line_length)
				local end_col = line == line2 and math.max(start_col + 1, (range.col2 or start_col + 2) - 1) or line_length
				end_col = math.min(end_col, line_length)
				if end_col > start_col then
					table.insert(marks, {
						line = line,
						col = start_col,
						opts = {
							end_col = end_col,
							hl_group = "AcpSourceColorRange",
							priority = 76,
						},
					})
				end
			end
			table.insert(marks, {
				line = line1,
				col = 0,
				opts = {
					virt_text = { { (" COLOR %s "):format(document_colors.label(item)), color_hl } },
					virt_text_pos = "right_align",
					sign_text = "C>",
					sign_hl_group = color_hl,
					priority = 86,
				},
			})
		end
	end
	return marks
end

local function link_marks(source, links)
	if not (source and valid_buf(source.bufnr)) then
		return {}
	end

	local line_count = vim.api.nvim_buf_line_count(source.bufnr)
	local marks = {}
	for _, item in ipairs(links or {}) do
		local range = document_links.range(item)
		if range and range.line1 and range.line2 then
			local line1 = math.max(1, math.min(range.line1, line_count))
			local line2 = math.max(1, math.min(range.line2, line_count))
			if line2 < line1 then
				line1, line2 = line2, line1
			end
			for line = line1, line2 do
				local text = vim.api.nvim_buf_get_lines(source.bufnr, line - 1, line, false)[1] or ""
				local line_length = #text
				local start_col = line == line1 and math.max(0, (range.col1 or 1) - 1) or 0
				start_col = math.min(start_col, line_length)
				local end_col = line == line2 and math.max(start_col + 1, (range.col2 or start_col + 2) - 1) or line_length
				end_col = math.min(end_col, line_length)
				if end_col > start_col then
					table.insert(marks, {
						line = line,
						col = start_col,
						opts = {
							end_col = end_col,
							hl_group = "AcpSourceLinkRange",
							priority = 77,
						},
					})
				end
			end
			table.insert(marks, {
				line = line1,
				col = 0,
				opts = {
					virt_text = { { (" LINK %s "):format(document_links.label(item)), "AcpSourceLinkBadge" } },
					virt_text_pos = "right_align",
					sign_text = "L>",
					sign_hl_group = "AcpSourceLinkBadge",
					priority = 87,
				},
			})
		end
	end
	return marks
end

local function fold_marks(source, folds)
	if not (source and valid_buf(source.bufnr)) then
		return {}
	end

	local line_count = vim.api.nvim_buf_line_count(source.bufnr)
	local marks = {}
	for _, item in ipairs(folds or {}) do
		local range = folding_ranges.range(item)
		if range and range.line1 and range.line2 then
			local line1 = math.max(1, math.min(range.line1, line_count))
			local line2 = math.max(1, math.min(range.line2, line_count))
			if line2 < line1 then
				line1, line2 = line2, line1
			end
			for line = line1, line2 do
				table.insert(marks, {
					line = line,
					col = 0,
					opts = {
						line_hl_group = "AcpSourceFoldRange",
						priority = 7,
					},
				})
			end
			table.insert(marks, {
				line = line1,
				col = 0,
				opts = {
					virt_text = { { (" FOLD %s "):format(folding_ranges.label(item)), "AcpSourceFoldBadge" } },
					virt_text_pos = "right_align",
					sign_text = "F>",
					sign_hl_group = "AcpSourceFoldBadge",
					priority = 85,
				},
			})
		end
	end
	return marks
end

function M.define_highlights()
	vim.api.nvim_set_hl(0, "AcpSourceContext", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceLabel", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceDiagnostics", { link = "DiagnosticWarn", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceLens", { link = "DiagnosticInfo", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceHighlightText", { link = "LspReferenceText", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceHighlightRead", { link = "LspReferenceRead", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceHighlightWrite", { link = "LspReferenceWrite", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceColorRange", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceLinkRange", { link = "Underlined", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceLinkBadge", { fg = "#1a1b26", bg = "#2ac3de", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpSourceFoldRange", { link = "CursorLine", default = true })
	vim.api.nvim_set_hl(0, "AcpSourceFoldBadge", { fg = "#1a1b26", bg = "#e0af68", bold = true, default = true })
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
	local highlight_count = #(state.source_highlights or {})
	local lens_highlights = highlight_count > 0 and ("highlights " .. highlight_count .. "  ") or ""
	local color_count = #(state.source_colors or {})
	local lens_colors = color_count > 0 and ("colors " .. color_count .. "  ") or ""
	local link_count = #(state.source_document_links or {})
	local lens_links = link_count > 0 and ("links " .. link_count .. "  ") or ""
	local fold_count = #(state.source_folding_ranges or {})
	local lens_folds = fold_count > 0 and ("folds " .. fold_count .. "  ") or ""
	local lens = (" ACP #%s source context  %s:AcpSourceActions focus/add/refresh/LSP/Tree-sitter "):format(
		tostring(state.id or "?"),
		lens_diagnostics .. lens_highlights .. lens_colors .. lens_links .. lens_folds
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
	for _, mark in ipairs(highlight_marks(source, state.source_highlights)) do
		table.insert(marks, mark)
	end
	for _, mark in ipairs(color_marks(source, state.source_colors)) do
		table.insert(marks, mark)
	end
	for _, mark in ipairs(link_marks(source, state.source_document_links)) do
		table.insert(marks, mark)
	end
	for _, mark in ipairs(fold_marks(source, state.source_folding_ranges)) do
		table.insert(marks, mark)
	end
	return marks
end

return M
