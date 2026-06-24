local M = {}

local function append_lines(out, text)
	if type(text) ~= "string" or text == "" then
		return
	end
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		table.insert(out, line)
	end
end

local function append_contents(out, contents)
	if type(contents) == "string" then
		append_lines(out, contents)
	elseif type(contents) == "table" then
		if type(contents.value) == "string" then
			append_lines(out, contents.value)
		else
			for _, item in ipairs(contents) do
				append_contents(out, item)
			end
		end
	end
end

function M.lines(result)
	local out = {}
	if type(result) == "table" then
		append_contents(out, result.contents)
	else
		append_contents(out, result)
	end

	local compact = {}
	for _, line in ipairs(out) do
		if line ~= "" or compact[#compact] ~= "" then
			table.insert(compact, line)
		end
	end
	while compact[#compact] == "" do
		table.remove(compact)
	end
	return compact
end

function M.text(result)
	local lines = M.lines(result)
	return #lines > 0 and table.concat(lines, "\n") or nil
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP hover requests are unavailable")
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

	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "textDocument/hover", params, function(results)
		local docs = {}
		for _, response in pairs(results or {}) do
			if type(response) == "table" then
				local text = M.text(response.result)
				if text and text ~= "" then
					table.insert(docs, text)
				end
			end
		end
		callback(#docs > 0 and table.concat(docs, "\n\n") or nil, nil)
	end)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports hover")
		return false
	end
	return true
end

return M
