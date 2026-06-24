local M = {}

function M.range_lines(item)
	local range = item and item.range
	if type(range) ~= "table" then
		return nil
	end

	local line1 = (tonumber(range.start_row) or 0) + 1
	local line2 = (tonumber(range.end_row) or (line1 - 1)) + 1
	if line2 < line1 then
		line2 = line1
	end
	return line1, line2
end

local function node_item(node, depth)
	if not node then
		return nil
	end

	local type_ok, node_type = pcall(function()
		return node:type()
	end)
	local range_ok, start_row, start_col, end_row, end_col = pcall(function()
		return node:range()
	end)
	if not type_ok or not range_ok or type(node_type) ~= "string" then
		return nil
	end

	return {
		node = node,
		type = node_type,
		depth = depth,
		range = {
			start_row = start_row,
			start_col = start_col,
			end_row = end_row,
			end_col = end_col,
		},
	}
end

function M.nodes(bufnr, cursor)
	if not vim.treesitter or not vim.treesitter.get_node then
		return nil, "Tree-sitter node lookup is unavailable"
	end

	local ok, node = pcall(vim.treesitter.get_node, {
		bufnr = bufnr,
		pos = { cursor[1] - 1, cursor[2] },
	})
	if not ok then
		return nil, node
	end
	if not node then
		return {}, nil
	end

	local out = {}
	local seen = {}
	local depth = 0
	while node and not seen[node] and depth < 40 do
		seen[node] = true
		local item = node_item(node, depth)
		if item then
			table.insert(out, item)
		end

		local ok, parent = pcall(function()
			if not node.parent then
				return nil
			end
			return node:parent()
		end)
		if not ok or not parent then
			break
		end
		node = parent
		depth = depth + 1
	end

	return out, nil
end

function M.picker_lines(nodes)
	local lines = { "ACP Tree-sitter Nodes", "" }
	local line_nodes = {}
	for index, item in ipairs(nodes or {}) do
		local line1, line2 = M.range_lines(item)
		local location = line1 and (" lines %d-%d"):format(line1, line2) or ""
		local indent = string.rep("  ", item.depth or 0)
		table.insert(lines, ("%d. %s%s%s"):format(index, indent, item.type or "node", location))
		line_nodes[#lines] = item
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to add context, or q/<Esc> to close.")
	return lines, line_nodes
end

return M
