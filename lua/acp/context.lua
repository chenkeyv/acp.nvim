local M = {}

local severity_names = {
	[vim.diagnostic.severity.ERROR] = "ERROR",
	[vim.diagnostic.severity.WARN] = "WARN",
	[vim.diagnostic.severity.INFO] = "INFO",
	[vim.diagnostic.severity.HINT] = "HINT",
}

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function clean_line(text)
	return tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function source_cursor(source)
	if valid_win(source.winid) and vim.api.nvim_win_get_buf(source.winid) == source.bufnr then
		return vim.api.nvim_win_get_cursor(source.winid)
	end
	return source.cursor or { 1, 0 }
end

local function buffer_path(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return "[No Name]"
	end
	return vim.fn.fnamemodify(name, ":.")
end

local function current_line(bufnr, line)
	local lines = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)
	return lines[1]
end

local function normalize_range(range)
	if type(range) ~= "table" or not range.line1 or not range.line2 then
		return nil
	end

	local line1 = math.max(1, tonumber(range.line1) or 1)
	local line2 = math.max(1, tonumber(range.line2) or line1)
	if line2 < line1 then
		line1, line2 = line2, line1
	end
	return {
		line1 = line1,
		line2 = line2,
	}
end

local function selected_lines(bufnr, range, limit)
	range = normalize_range(range)
	if not range then
		return nil
	end

	local max_line = vim.api.nvim_buf_line_count(bufnr)
	local line1 = math.min(range.line1, max_line)
	local line2 = math.min(range.line2, max_line)
	local requested = line2 - line1 + 1
	local stop = math.min(line2, line1 + limit - 1)
	local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, stop, false)

	return {
		line1 = line1,
		line2 = line2,
		requested = requested,
		lines = lines,
		truncated = requested > #lines,
	}
end

local function lsp_client_names(bufnr)
	local clients = {}
	local ok, result
	if vim.lsp.get_clients then
		ok, result = pcall(vim.lsp.get_clients, { bufnr = bufnr })
	elseif vim.lsp.get_active_clients then
		ok, result = pcall(vim.lsp.get_active_clients, { bufnr = bufnr })
	end
	if not ok then
		return clients
	end

	for _, client in ipairs(result or {}) do
		if client.name and client.name ~= "" then
			table.insert(clients, client.name)
		end
	end
	table.sort(clients)
	return clients
end

local function treesitter_node(bufnr, cursor)
	if not vim.treesitter or not vim.treesitter.get_node then
		return nil
	end

	local ok, node = pcall(vim.treesitter.get_node, {
		bufnr = bufnr,
		pos = { cursor[1] - 1, cursor[2] },
	})
	if not ok or not node then
		return nil
	end

	local start_row, start_col, end_row, end_col = node:range()
	return ("%s at %d:%d-%d:%d"):format(node:type(), start_row + 1, start_col + 1, end_row + 1, end_col)
end

local function diagnostics(bufnr, line, limit)
	local items = vim.diagnostic.get(bufnr, { lnum = line - 1 })
	if #items == 0 then
		return {}
	end

	table.sort(items, function(left, right)
		return (left.severity or 999) < (right.severity or 999)
	end)

	local lines = {}
	for index, diagnostic in ipairs(items) do
		if index > limit then
			table.insert(lines, ("- ... %d more diagnostic(s)"):format(#items - limit))
			break
		end
		local severity = severity_names[diagnostic.severity] or "INFO"
		table.insert(lines, ("- %s: %s"):format(severity, clean_line(diagnostic.message)))
	end
	return lines
end

local function diagnostic_counts(items)
	local counts = {
		[vim.diagnostic.severity.ERROR] = 0,
		[vim.diagnostic.severity.WARN] = 0,
		[vim.diagnostic.severity.INFO] = 0,
		[vim.diagnostic.severity.HINT] = 0,
	}

	for _, diagnostic in ipairs(items) do
		if counts[diagnostic.severity] ~= nil then
			counts[diagnostic.severity] = counts[diagnostic.severity] + 1
		end
	end

	return counts
end

local function diagnostic_summary(bufnr, line, limit)
	local items = vim.diagnostic.get(bufnr)
	if #items == 0 then
		return nil, {}
	end

	local counts = diagnostic_counts(items)
	local summary = ("%d error(s), %d warning(s), %d info, %d hint(s)"):format(
		counts[vim.diagnostic.severity.ERROR],
		counts[vim.diagnostic.severity.WARN],
		counts[vim.diagnostic.severity.INFO],
		counts[vim.diagnostic.severity.HINT]
	)

	table.sort(items, function(left, right)
		local left_distance = math.abs((left.lnum or 0) - (line - 1))
		local right_distance = math.abs((right.lnum or 0) - (line - 1))
		if left_distance ~= right_distance then
			return left_distance < right_distance
		end
		if (left.severity or 999) ~= (right.severity or 999) then
			return (left.severity or 999) < (right.severity or 999)
		end
		return (left.lnum or 0) < (right.lnum or 0)
	end)

	local lines = {}
	for index, diagnostic in ipairs(items) do
		if index > limit then
			table.insert(lines, ("- ... %d more diagnostic(s)"):format(#items - limit))
			break
		end
		local severity = severity_names[diagnostic.severity] or "INFO"
		table.insert(lines, ("- %d:%d %s: %s"):format(
			(diagnostic.lnum or 0) + 1,
			(diagnostic.col or 0) + 1,
			severity,
			clean_line(diagnostic.message)
		))
	end

	return summary, lines
end

function M.capture(bufnr, winid, range)
	if not valid_buf(bufnr) then
		return nil
	end

	local cursor = { 1, 0 }
	if valid_win(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
		cursor = vim.api.nvim_win_get_cursor(winid)
	end

	return {
		bufnr = bufnr,
		winid = winid,
		cursor = cursor,
		range = normalize_range(range),
	}
end

function M.render(source, opts)
	opts = opts or {}
	if not source or not valid_buf(source.bufnr) then
		return nil
	end

	local cursor = source_cursor(source)
	local bufnr = source.bufnr
	local line = math.max(1, cursor[1])
	local col = math.max(0, cursor[2])
	local lines = {
		"Context",
		("File: %s"):format(buffer_path(bufnr)),
		("Filetype: %s"):format(vim.bo[bufnr].filetype ~= "" and vim.bo[bufnr].filetype or "text"),
		("Cursor: %d:%d"):format(line, col + 1),
	}

	local clients = lsp_client_names(bufnr)
	if #clients > 0 then
		table.insert(lines, ("LSP clients: %s"):format(table.concat(clients, ", ")))
	end

	local node = treesitter_node(bufnr, cursor)
	if node then
		table.insert(lines, ("Tree-sitter: %s"):format(node))
	end

	local text = current_line(bufnr, line)
	if text and text ~= "" then
		table.insert(lines, ("Line: %s"):format(clean_line(text)))
	end

	local selection = selected_lines(bufnr, source.range, opts.selection_limit or 80)
	if selection then
		table.insert(lines, ("Selection: lines %d-%d (%d line(s))"):format(
			selection.line1,
			selection.line2,
			selection.requested
		))
		table.insert(lines, "Selected text:")
		for _, selected in ipairs(selection.lines) do
			table.insert(lines, selected)
		end
		if selection.truncated then
			table.insert(lines, ("... %d more selected line(s)"):format(selection.requested - #selection.lines))
		end
	end

	local diagnostic_lines = diagnostics(bufnr, line, opts.diagnostic_limit or 5)
	if #diagnostic_lines > 0 then
		table.insert(lines, "Diagnostics:")
		vim.list_extend(lines, diagnostic_lines)
	end

	local summary, buffer_diagnostics = diagnostic_summary(bufnr, line, opts.buffer_diagnostic_limit or 5)
	if summary then
		table.insert(lines, "Buffer diagnostics:")
		table.insert(lines, ("Summary: %s"):format(summary))
		vim.list_extend(lines, buffer_diagnostics)
	end

	return table.concat(lines, "\n")
end

return M
