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

local function line_text(bufnr, line)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		return nil
	end
	return vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
end

local function range_text(bufnr, range)
	if not range then
		return nil
	end

	local line = line_text(bufnr, range.line1)
	if not line or line == "" then
		return nil
	end
	if range.line1 == range.line2 and range.col1 and range.col2 and range.col2 > range.col1 then
		return clean(line:sub(range.col1, range.col2 - 1))
	end
	return clean(line)
end

local function word_range(source)
	if not source or not source.bufnr or not vim.api.nvim_buf_is_valid(source.bufnr) then
		return nil
	end

	local cursor = source.cursor or { 1, 0 }
	local row = math.max(1, cursor[1] or 1)
	local line = line_text(source.bufnr, row) or ""
	local pos = math.max(1, (cursor[2] or 0) + 1)
	local start_col = pos
	local end_col = pos

	while start_col > 1 and line:sub(start_col - 1, start_col - 1):match("[%w_]") do
		start_col = start_col - 1
	end
	while end_col <= #line and line:sub(end_col, end_col):match("[%w_]") do
		end_col = end_col + 1
	end

	if end_col <= start_col then
		return {
			line1 = row,
			line2 = row,
			col1 = pos,
			col2 = pos,
		}
	end

	return {
		line1 = row,
		line2 = row,
		col1 = start_col,
		col2 = end_col,
	}
end

function M.normalize(result, source)
	if type(result) ~= "table" then
		return nil
	end

	local range
	local placeholder = clean(result.placeholder)
	local default_behavior = result.defaultBehavior == true
	if default_behavior then
		range = word_range(source)
	elseif result.range then
		range = lsp_range(result.range)
	else
		range = lsp_range(result)
	end
	if not range then
		return nil
	end

	return {
		range = range,
		placeholder = placeholder or range_text(source and source.bufnr, range),
		default_behavior = default_behavior,
	}
end

function M.prompt(source, item, new_name)
	local name = clean(new_name)
	if not name then
		return nil, "Rename target is empty"
	end
	if not item or not item.range then
		return nil, "LSP prepare-rename result has no range"
	end

	local current_name = clean(item.placeholder) or range_text(source and source.bufnr, item.range) or "symbol"
	local rename_source = context.capture(source.bufnr, source.winid, item.range)
	local rendered_context = context.render(rename_source, {
		include_diagnostics = false,
		treesitter_text_lines = 32,
		selection_limit = 120,
	})
	if not rendered_context then
		return nil, "Failed to render rename context"
	end

	return table.concat({
		("Rename this symbol to `%s`. Keep behavior unchanged and update all relevant references."):format(name),
		"",
		"Rename target:",
		("- Current name: %s"):format(current_name),
		("- New name: %s"):format(name),
		("- Range: lines %d-%d"):format(item.range.line1, item.range.line2),
		"",
		rendered_context,
	}, "\n")
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP prepare-rename requests are unavailable")
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

	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "textDocument/prepareRename", params, function(results)
		local last_error
		for _, response in pairs(results or {}) do
			if type(response) == "table" and response.result ~= nil then
				local item = M.normalize(response.result, source)
				if item then
					callback(item, nil)
					return
				end
			elseif type(response) == "table" and type(response.error) == "table" then
				last_error = response.error.message
			end
		end
		callback(nil, last_error or "No LSP prepare-rename result")
	end)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports prepare rename")
		return false
	end
	return true
end

return M
