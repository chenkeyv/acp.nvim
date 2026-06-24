local context = require("acp.context")

local M = {}

local function clamp(value)
	local number = tonumber(value) or 0
	if number < 0 then
		return 0
	end
	if number > 1 then
		return 1
	end
	return number
end

local function byte(value)
	return math.floor(clamp(value) * 255 + 0.5)
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

function M.range(item)
	if type(item) == "table" and item.range and item.range.line1 then
		return item.range
	end
	return lsp_range(type(item) == "table" and item.range or nil)
end

function M.hex(color)
	if type(color) ~= "table" then
		return "#000000"
	end
	return ("#%02X%02X%02X"):format(byte(color.red), byte(color.green), byte(color.blue))
end

function M.label(item)
	local color = type(item) == "table" and item.color or item
	local hex = M.hex(color)
	if type(color) == "table" and color.alpha ~= nil and clamp(color.alpha) < 1 then
		return ("%s alpha %.2f"):format(hex, clamp(color.alpha))
	end
	return hex
end

function M.highlight_group(item)
	local color = type(item) == "table" and item.color or item
	local hex = M.hex(color)
	local red = byte(color and color.red)
	local green = byte(color and color.green)
	local blue = byte(color and color.blue)
	local luminance = (0.299 * red + 0.587 * green + 0.114 * blue) / 255
	local fg = luminance > 0.55 and "#1a1b26" or "#c0caf5"
	local name = "AcpDocumentColor" .. hex:gsub("#", "")
	vim.api.nvim_set_hl(0, name, { fg = fg, bg = hex, bold = true, default = true })
	return name
end

function M.normalize(results)
	local items = {}
	local function collect(item)
		if type(item) == "table" and type(item.color) == "table" and lsp_range(item.range) then
			table.insert(items, {
				color = {
					red = clamp(item.color.red),
					green = clamp(item.color.green),
					blue = clamp(item.color.blue),
					alpha = clamp(item.color.alpha == nil and 1 or item.color.alpha),
				},
				range = lsp_range(item.range),
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
	local lines = { "ACP Document Colors", "" }
	local line_items = {}
	for index, item in ipairs(items or {}) do
		local range = M.range(item) or {}
		table.insert(lines, ("%d. %d:%d  %s"):format(index, range.line1 or 1, range.col1 or 1, M.label(item)))
		line_items[#lines] = item
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to add color context, Q for quickfix, or q/<Esc> to close.")
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
				text = ("DOCUMENT COLOR: %s"):format(M.label(item)),
			})
		end
	end
	return qf_items
end

function M.prompt(source, item)
	local range = M.range(item)
	if not range then
		return nil, "LSP document color has no range"
	end

	local color_source = context.capture(source.bufnr, source.winid, range)
	local rendered_context = context.render(color_source, {
		include_diagnostics = false,
		treesitter_text_lines = 24,
		selection_limit = 80,
	})
	if not rendered_context then
		return nil, "Failed to render LSP document-color context"
	end

	return table.concat({
		("Use this LSP document color as context: %s."):format(M.label(item)),
		"",
		"Document color:",
		("- Value: %s"):format(M.label(item)),
		("- Range: lines %d-%d"):format(range.line1, range.line2),
		"",
		rendered_context,
	}, "\n")
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP document-color requests are unavailable")
		return false
	end

	local params = {
		textDocument = {
			uri = vim.uri_from_bufnr(source.bufnr),
		},
	}

	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "textDocument/documentColor", params, function(results)
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
		callback(nil, "No attached LSP client supports document colors")
		return false
	end
	return true
end

return M
