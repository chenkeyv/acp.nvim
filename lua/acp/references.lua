local M = {}

local function reference_uri(reference)
	if type(reference) ~= "table" then
		return nil
	end
	return reference.uri or reference.targetUri
end

local function reference_range(reference)
	if type(reference) ~= "table" then
		return nil
	end
	return reference.range or reference.targetSelectionRange or reference.targetRange
end

function M.uri(reference)
	return reference_uri(reference)
end

function M.range(reference)
	local range = reference_range(reference)
	if not range or type(range.start) ~= "table" or type(range["end"]) ~= "table" then
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

function M.display_path(reference)
	local uri = reference_uri(reference)
	if type(uri) ~= "string" or uri == "" then
		return "[unknown]"
	end

	local ok, path = pcall(vim.uri_to_fname, uri)
	if ok and path and path ~= "" then
		return vim.fn.fnamemodify(path, ":.")
	end
	return uri
end

function M.bufnr(reference)
	local uri = reference_uri(reference)
	if type(uri) ~= "string" or uri == "" then
		return nil, "LSP reference has no URI"
	end

	local ok, bufnr = pcall(vim.uri_to_bufnr, uri)
	if not ok or not bufnr then
		return nil, "Failed to resolve LSP reference buffer"
	end
	if vim.fn.bufloaded(bufnr) == 0 then
		pcall(vim.fn.bufload, bufnr)
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, "LSP reference buffer is invalid"
	end
	return bufnr, nil
end

function M.flatten(results)
	local out = {}
	for _, reference in ipairs(results or {}) do
		if reference_uri(reference) and reference_range(reference) then
			table.insert(out, reference)
		end
	end
	return out
end

function M.picker_lines(references)
	local lines = { "ACP References", "" }
	local line_references = {}
	for index, reference in ipairs(references or {}) do
		local range = M.range(reference)
		local location = range and ("%s:%d"):format(M.display_path(reference), range.line1) or M.display_path(reference)
		table.insert(lines, ("%d. %s"):format(index, location))
		line_references[#lines] = reference
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to add context, Q for quickfix, or q/<Esc> to close.")
	return lines, line_references
end

function M.quickfix_items(references)
	local items = {}
	for _, reference in ipairs(references or {}) do
		local bufnr = M.bufnr(reference)
		local range = M.range(reference)
		if bufnr and range then
			table.insert(items, {
				bufnr = bufnr,
				lnum = range.line1,
				col = range.col1 or 1,
				end_lnum = range.line2,
				end_col = range.col2 or range.col1 or 1,
				text = ("REFERENCE: %s:%d"):format(M.display_path(reference), range.line1),
			})
		end
	end
	return items
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP references requests are unavailable")
		return false
	end

	local cursor = source.cursor or { 1, 0 }
	local params = {
		textDocument = {
			uri = vim.uri_from_bufnr(source.bufnr),
		},
		position = {
			line = math.max(0, (cursor[1] or 1) - 1),
			character = math.max(0, cursor[2] or 0),
		},
		context = {
			includeDeclaration = true,
		},
	}

	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "textDocument/references", params, function(results)
		local raw_references = {}
		for _, response in pairs(results or {}) do
			if type(response) == "table" and type(response.result) == "table" then
				vim.list_extend(raw_references, response.result)
			end
		end
		callback(M.flatten(raw_references), nil)
	end)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports references")
		return false
	end
	return true
end

return M
