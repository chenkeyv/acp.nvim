local context = require("acp.context")

local M = {}

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function client_name(client_id)
	if not (vim.lsp and vim.lsp.get_client_by_id) then
		return nil
	end

	local ok, client = pcall(vim.lsp.get_client_by_id, client_id)
	if ok and client and client.name and client.name ~= "" then
		return client.name
	end
	return nil
end

local function range_key(range)
	return ("%d:%d-%d:%d"):format(range.line1, range.col1 or 1, range.line2, range.col2 or 1)
end

local function line_count(range)
	if not range then
		return 0
	end
	return math.max(1, (range.line2 or range.line1 or 1) - (range.line1 or 1) + 1)
end

local function range_label(index, range)
	local count = line_count(range)
	if count <= 1 then
		return index == 1 and "cursor expression" or "expanded expression"
	end
	if count <= 8 then
		return "semantic block"
	end
	return "semantic scope"
end

local function preview_line(bufnr, range)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and range) then
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, range.line1 - 1, range.line1, false)[1]
	line = clean(line)
	if line and #line > 72 then
		line = line:sub(1, 69) .. "..."
	end
	return line
end

function M.lsp_range(range)
	if type(range) ~= "table" or type(range.start) ~= "table" or type(range["end"]) ~= "table" then
		return nil
	end

	local line1 = (tonumber(range.start.line) or 0) + 1
	local line2 = (tonumber(range["end"].line) or (line1 - 1)) + 1
	local col1 = (tonumber(range.start.character) or 0) + 1
	local end_character = tonumber(range["end"].character) or 0
	local col2 = end_character + 1
	if end_character == 0 and line2 > line1 then
		line2 = line2 - 1
	end
	if line2 < line1 then
		line2 = line1
	end

	return {
		line1 = line1,
		line2 = line2,
		col1 = col1,
		col2 = col2,
	}
end

function M.range(item)
	return item and item.range
end

local function collect_chain(out, seen, item, name)
	local node = item
	local depth = 0
	while type(node) == "table" and depth < 40 do
		local range = M.lsp_range(node.range)
		if range then
			local key = range_key(range)
			if not seen[key] then
				seen[key] = true
				table.insert(out, {
					range = range,
					depth = depth,
					client = name,
				})
			end
		end
		node = node.parent
		depth = depth + 1
	end
end

local function collect_result(out, seen, result, name)
	if type(result) ~= "table" then
		return
	end
	if result.range then
		collect_chain(out, seen, result, name)
		return
	end
	for _, item in ipairs(result) do
		collect_chain(out, seen, item, name)
	end
end

function M.flatten(results)
	local out = {}
	local seen = {}
	if type(results) ~= "table" then
		return out
	end

	for client_id, response in pairs(results) do
		if type(response) == "table" and response.result ~= nil then
			collect_result(out, seen, response.result, client_name(client_id))
		end
	end
	if #out == 0 then
		collect_result(out, seen, results, nil)
	end

	table.sort(out, function(left, right)
		local left_range = left.range or {}
		local right_range = right.range or {}
		local left_count = line_count(left_range)
		local right_count = line_count(right_range)
		if left_count ~= right_count then
			return left_count < right_count
		end
		if (left_range.line1 or 1) ~= (right_range.line1 or 1) then
			return (left_range.line1 or 1) < (right_range.line1 or 1)
		end
		return (left_range.col1 or 1) > (right_range.col1 or 1)
	end)

	for index, item in ipairs(out) do
		item.index = index
		item.label = range_label(index, item.range)
	end
	return out
end

function M.picker_lines(items, opts)
	opts = opts or {}
	local lines = { "ACP Selection Ranges", "" }
	local line_items = {}
	for index, item in ipairs(items or {}) do
		local range = item.range or {}
		local count = line_count(range)
		local suffix = count == 1 and "line" or "lines"
		local preview = preview_line(opts.bufnr, range)
		local line = ("%d. %-19s lines %d-%d (%d %s)"):format(
			index,
			item.label or range_label(index, range),
			range.line1 or 1,
			range.line2 or range.line1 or 1,
			count,
			suffix
		)
		if preview then
			line = ("%s  %s"):format(line, preview)
		end
		table.insert(lines, line)
		line_items[#lines] = item
		if item.client then
			table.insert(lines, ("   LSP: %s"):format(item.client))
			line_items[#lines] = item
		end
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to add the selected semantic range, or q/<Esc> to close.")
	return lines, line_items
end

function M.prompt(source, item)
	local range = M.range(item)
	if not range then
		return nil
	end

	local selected_source = context.capture(source.bufnr, source.winid, {
		line1 = range.line1,
		line2 = range.line2,
	})
	if selected_source then
		selected_source.cursor = { range.line1, math.max(0, (range.col1 or 1) - 1) }
	end

	local rendered_context = context.render(selected_source, {
		treesitter_text_lines = 40,
		selection_limit = 160,
	})
	if not rendered_context then
		return nil
	end

	return table.concat({
		("Use this LSP selection range as context: %s."):format(item.label or "semantic range"),
		("Selection: lines %d-%d (%d line(s))"):format(range.line1, range.line2, line_count(range)),
		"",
		rendered_context,
	}, "\n")
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP selection-range requests are unavailable")
		return false
	end

	local cursor = source.cursor or { 1, 0 }
	local params = {
		textDocument = {
			uri = vim.uri_from_bufnr(source.bufnr),
		},
		positions = {
			{
				line = math.max(0, (cursor[1] or 1) - 1),
				character = math.max(0, cursor[2] or 0),
			},
		},
	}

	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "textDocument/selectionRange", params, function(results)
		callback(M.flatten(results), nil)
	end)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports selection ranges")
		return false
	end
	return true
end

return M
