local context = require("acp.context")

local M = {}

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function range(item)
	if type(item) ~= "table" then
		return nil
	end
	local line1 = tonumber(item.startLine)
	local line2 = tonumber(item.endLine)
	if not (line1 and line2) then
		return nil
	end
	line1 = line1 + 1
	line2 = line2 + 1
	if line2 < line1 then
		line2 = line1
	end
	return {
		line1 = line1,
		line2 = line2,
		col1 = item.startCharacter and ((tonumber(item.startCharacter) or 0) + 1) or 1,
		col2 = item.endCharacter and ((tonumber(item.endCharacter) or 0) + 1) or nil,
	}
end

function M.range(item)
	if type(item) == "table" and item.range and item.range.line1 then
		return item.range
	end
	return range(item)
end

function M.kind(item)
	return clean(type(item) == "table" and item.kind or nil) or "region"
end

function M.label(item)
	local range_value = M.range(item) or {}
	local collapsed = clean(type(item) == "table" and item.collapsedText or nil)
	if collapsed then
		return ("%s lines %d-%d: %s"):format(M.kind(item), range_value.line1 or 1, range_value.line2 or 1, collapsed)
	end
	return ("%s lines %d-%d"):format(M.kind(item), range_value.line1 or 1, range_value.line2 or 1)
end

function M.normalize(results)
	local items = {}
	local function collect(item)
		local normalized_range = range(item)
		if type(item) == "table" and normalized_range then
			table.insert(items, {
				range = normalized_range,
				kind = M.kind(item),
				collapsedText = clean(item.collapsedText),
			})
		elseif type(item) == "table" then
			for _, child in ipairs(item) do
				collect(child)
			end
		end
	end
	collect(results)

	table.sort(items, function(left, right)
		if (left.range.line1 or 1) ~= (right.range.line1 or 1) then
			return (left.range.line1 or 1) < (right.range.line1 or 1)
		end
		if (left.range.line2 or 1) ~= (right.range.line2 or 1) then
			return (left.range.line2 or 1) < (right.range.line2 or 1)
		end
		return (left.kind or "") < (right.kind or "")
	end)
	return items
end

function M.picker_lines(items)
	local lines = { "ACP Folding Ranges", "" }
	local line_items = {}
	for index, item in ipairs(items or {}) do
		local range_value = M.range(item) or {}
		local line_count = math.max(1, (range_value.line2 or 1) - (range_value.line1 or 1) + 1)
		table.insert(lines, ("%d. %d-%d  %-12s  %d line%s"):format(
			index,
			range_value.line1 or 1,
			range_value.line2 or 1,
			M.kind(item),
			line_count,
			line_count == 1 and "" or "s"
		))
		line_items[#lines] = item
		local collapsed = clean(item.collapsedText)
		if collapsed then
			table.insert(lines, ("      %s"):format(collapsed:sub(1, 96)))
			line_items[#lines] = item
		end
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to add folding-range context, Q for quickfix, or q/<Esc> to close.")
	return lines, line_items
end

function M.quickfix_items(bufnr, items)
	local qf_items = {}
	for _, item in ipairs(items or {}) do
		local range_value = M.range(item)
		if range_value then
			table.insert(qf_items, {
				bufnr = bufnr,
				lnum = range_value.line1,
				col = range_value.col1 or 1,
				end_lnum = range_value.line2,
				end_col = range_value.col2 or range_value.col1 or 1,
				text = ("FOLDING RANGE: %s"):format(M.label(item)),
			})
		end
	end
	return qf_items
end

function M.prompt(source, item)
	local range_value = M.range(item)
	if not range_value then
		return nil, "LSP folding range has no range"
	end

	local fold_source = context.capture(source.bufnr, source.winid, range_value)
	local rendered_context = context.render(fold_source, {
		include_diagnostics = false,
		treesitter_text_lines = 48,
		selection_limit = 240,
	})
	if not rendered_context then
		return nil, "Failed to render LSP folding-range context"
	end

	local lines = {
		("Use this LSP folding range as context: %s."):format(M.label(item)),
		"",
		"Folding range:",
		("- Kind: %s"):format(M.kind(item)),
		("- Range: lines %d-%d"):format(range_value.line1, range_value.line2),
	}
	local collapsed = clean(item.collapsedText)
	if collapsed then
		table.insert(lines, ("- Collapsed text: %s"):format(collapsed))
	end
	table.insert(lines, "")
	table.insert(lines, rendered_context)
	return table.concat(lines, "\n")
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP folding-range requests are unavailable")
		return false
	end

	local params = {
		textDocument = {
			uri = vim.uri_from_bufnr(source.bufnr),
		},
	}

	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "textDocument/foldingRange", params, function(results)
		local raw = {}
		for _, response in pairs(results or {}) do
			if type(response) == "table" and type(response.result) == "table" then
				vim.list_extend(raw, response.result)
			end
		end
		callback(M.normalize(raw), nil)
	end)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports folding ranges")
		return false
	end
	return true
end

return M
