local context = require("acp.context")

local M = {}

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lsp_range(range)
	if type(range) ~= "table" or type(range.start) ~= "table" or type(range["end"]) ~= "table" then
		return nil
	end

	local line1 = (tonumber(range.start.line) or 0) + 1
	local line2 = (tonumber(range["end"].line) or (line1 - 1)) + 1
	if line2 < line1 then
		line2 = line1
	end
	return {
		line1 = line1,
		line2 = line2,
		col1 = (tonumber(range.start.character) or 0) + 1,
		col2 = (tonumber(range["end"].character) or 0) + 1,
	}
end

local function short(value, limit)
	local label = clean(value) or "?"
	limit = limit or 72
	if #label > limit then
		return label:sub(1, limit - 3) .. "..."
	end
	return label
end

function M.range(item)
	if type(item) == "table" and item.range and item.range.line1 then
		return item.range
	end
	return lsp_range(type(item) == "table" and item.range or nil)
end

function M.target(item)
	return clean(type(item) == "table" and item.target or nil)
end

function M.tooltip(item)
	return clean(type(item) == "table" and item.tooltip or nil)
end

function M.label(item)
	local target = M.target(item)
	if target and target:match("^file://") and vim.uri_to_fname then
		local ok, filename = pcall(vim.uri_to_fname, target)
		if ok and filename and filename ~= "" then
			return short(vim.fn.fnamemodify(filename, ":~:."))
		end
	end
	return short(target or M.tooltip(item) or "Unresolved document link")
end

function M.normalize(results)
	local items = {}
	local function collect(item)
		if type(item) == "table" and lsp_range(item.range) then
			table.insert(items, {
				range = lsp_range(item.range),
				target = clean(item.target),
				tooltip = clean(item.tooltip),
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
		return (left.range.col1 or 1) < (right.range.col1 or 1)
	end)
	return items
end

function M.picker_lines(items)
	local lines = { "ACP Document Links", "" }
	local line_items = {}
	for index, item in ipairs(items or {}) do
		local range = M.range(item) or {}
		table.insert(lines, ("%d. %d:%d  %s"):format(index, range.line1 or 1, range.col1 or 1, M.label(item)))
		line_items[#lines] = item
		if M.tooltip(item) and M.tooltip(item) ~= M.label(item) then
			table.insert(lines, ("      %s"):format(short(M.tooltip(item), 96)))
			line_items[#lines] = item
		end
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to add link context, Q for quickfix, or q/<Esc> to close.")
	return lines, line_items
end

function M.quickfix_items(bufnr, items)
	local qf_items = {}
	for _, item in ipairs(items or {}) do
		local range = M.range(item)
		if range then
			table.insert(qf_items, {
				bufnr = bufnr,
				lnum = range.line1,
				col = range.col1 or 1,
				end_lnum = range.line2,
				end_col = range.col2 or range.col1 or 1,
				text = ("DOCUMENT LINK: %s"):format(M.label(item)),
			})
		end
	end
	return qf_items
end

function M.prompt(source, item)
	local range = M.range(item)
	if not range then
		return nil, "LSP document link has no range"
	end

	local link_source = context.capture(source.bufnr, source.winid, range)
	local rendered_context = context.render(link_source, {
		include_diagnostics = false,
		treesitter_text_lines = 24,
		selection_limit = 120,
	})
	if not rendered_context then
		return nil, "Failed to render LSP document-link context"
	end

	local lines = {
		("Use this LSP document link as context: %s."):format(M.label(item)),
		"",
		"Document link:",
		("- Label: %s"):format(M.label(item)),
		("- Range: lines %d-%d"):format(range.line1, range.line2),
	}
	local target = M.target(item)
	if target then
		table.insert(lines, ("- Target: %s"):format(target))
	end
	local tooltip = M.tooltip(item)
	if tooltip then
		table.insert(lines, ("- Tooltip: %s"):format(tooltip))
	end
	table.insert(lines, "")
	table.insert(lines, rendered_context)
	return table.concat(lines, "\n")
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP document-link requests are unavailable")
		return false
	end

	local params = {
		textDocument = {
			uri = vim.uri_from_bufnr(source.bufnr),
		},
	}

	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "textDocument/documentLink", params, function(results)
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
		callback(nil, "No attached LSP client supports document links")
		return false
	end
	return true
end

return M
