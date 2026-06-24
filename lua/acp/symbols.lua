local M = {}

local kind_names = {
	[1] = "File",
	[2] = "Module",
	[3] = "Namespace",
	[4] = "Package",
	[5] = "Class",
	[6] = "Method",
	[7] = "Property",
	[8] = "Field",
	[9] = "Constructor",
	[10] = "Enum",
	[11] = "Interface",
	[12] = "Function",
	[13] = "Variable",
	[14] = "Constant",
	[15] = "String",
	[16] = "Number",
	[17] = "Boolean",
	[18] = "Array",
	[19] = "Object",
	[20] = "Key",
	[21] = "Null",
	[22] = "EnumMember",
	[23] = "Struct",
	[24] = "Event",
	[25] = "Operator",
	[26] = "TypeParameter",
}

local function symbol_range(symbol)
	if type(symbol) ~= "table" then
		return nil
	end
	if type(symbol.range) == "table" then
		return symbol.range
	end
	if type(symbol.location) == "table" and type(symbol.location.range) == "table" then
		return symbol.location.range
	end
	return nil
end

function M.kind_name(kind)
	if type(kind) == "string" and kind ~= "" then
		return kind
	end
	return kind_names[kind] or "Symbol"
end

function M.range(symbol)
	local range = symbol_range(symbol)
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

function M.range_lines(symbol)
	local range = M.range(symbol)
	if not range then
		return nil
	end
	return range.line1, range.line2
end

local function collect(out, symbol, depth)
	if type(symbol) ~= "table" or type(symbol.name) ~= "string" or symbol.name == "" then
		return
	end

	table.insert(out, {
		name = symbol.name,
		kind = symbol.kind,
		detail = symbol.detail,
		range = symbol_range(symbol),
		depth = depth,
	})

	for _, child in ipairs(symbol.children or {}) do
		collect(out, child, depth + 1)
	end
end

function M.flatten(results)
	local out = {}
	for _, symbol in ipairs(results or {}) do
		collect(out, symbol, 0)
	end
	return out
end

function M.picker_lines(symbols)
	local lines = { "ACP Symbols", "" }
	local line_symbols = {}
	for index, symbol in ipairs(symbols or {}) do
		local line1, line2 = M.range_lines(symbol)
		local location = line1 and (" lines %d-%d"):format(line1, line2) or ""
		local indent = string.rep("  ", symbol.depth or 0)
		table.insert(lines, ("%d. %s%s  %s%s"):format(
			index,
			indent,
			symbol.name,
			M.kind_name(symbol.kind),
			location
		))
		line_symbols[#lines] = symbol
		if symbol.detail and symbol.detail ~= "" then
			table.insert(lines, ("   %s%s"):format(indent, symbol.detail))
			line_symbols[#lines] = symbol
		end
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to add context, Q for quickfix, or q/<Esc> to close.")
	return lines, line_symbols
end

function M.quickfix_items(bufnr, symbols)
	local items = {}
	for _, symbol in ipairs(symbols or {}) do
		local range = M.range(symbol)
		if range then
			table.insert(items, {
				bufnr = bufnr,
				lnum = range.line1,
				col = range.col1 or 1,
				end_lnum = range.line2,
				end_col = range.col2 or range.col1 or 1,
				text = ("SYMBOL: %s (%s)"):format(symbol.name or "?", M.kind_name(symbol.kind)),
			})
		end
	end
	return items
end

return M
