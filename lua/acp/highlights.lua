local M = {}

local kind_names = {
	[1] = "text",
	[2] = "read",
	[3] = "write",
}

function M.kind_name(kind)
	return kind_names[tonumber(kind) or 1] or "text"
end

function M.range(item)
	local range = type(item) == "table" and item.range or nil
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

function M.normalize(results)
	local items = {}
	for _, item in ipairs(results or {}) do
		local range = M.range(item)
		if range then
			table.insert(items, {
				kind = tonumber(item.kind) or 1,
				range = range,
			})
		end
	end
	return items
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP document-highlight requests are unavailable")
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
	}

	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "textDocument/documentHighlight", params, function(results)
		local raw_items = {}
		for _, response in pairs(results or {}) do
			if type(response) == "table" and type(response.result) == "table" then
				vim.list_extend(raw_items, response.result)
			end
		end
		callback(M.normalize(raw_items), nil)
	end)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports document highlights")
		return false
	end
	return true
end

return M
