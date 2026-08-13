local M = {}

local shell_programs = {
	ash = true,
	bash = true,
	dash = true,
	ksh = true,
	mksh = true,
	sh = true,
	zsh = true,
}

local base_priority = 140
local nested_priority_step = 20
local maximum_wrapper_depth = 3

local exact_shell_capture_groups = {
	["variable.parameter"] = "AcpShellArgument",
}

local shell_capture_groups = {
	comment = "AcpShellComment",
	constant = "AcpShellNumber",
	constructor = "AcpShellCommand",
	["function"] = "AcpShellCommand",
	keyword = "AcpShellKeyword",
	number = "AcpShellNumber",
	operator = "AcpShellOperator",
	property = "AcpShellArgument",
	punctuation = "AcpShellPunctuation",
	string = "AcpShellString",
	type = "AcpShellArgument",
	variable = "AcpShellVariable",
}

local function capture_group(name)
	name = tostring(name or "")
	if exact_shell_capture_groups[name] then
		return exact_shell_capture_groups[name]
	end
	for prefix, group in pairs(shell_capture_groups) do
		if name == prefix or name:sub(1, #prefix + 1) == prefix .. "." then
			return group
		end
	end
end

local function command_string_option(value)
	value = tostring(value or "")
	if value == "--" or value:sub(1, 1) ~= "-" or value:sub(2, 2) == "-" then
		return false
	end
	return value:sub(2):find("c", 1, true) ~= nil
end

local function shell_command_argument(command, text)
	local names = command:field("name")
	local name = names[1] and vim.treesitter.get_node_text(names[1], text) or nil
	name = name and vim.fs.basename(name) or nil
	if not shell_programs[name] then
		return nil
	end

	local arguments = command:field("argument")
	for index, argument in ipairs(arguments) do
		local value = vim.treesitter.get_node_text(argument, text)
		if value == "--" then
			return nil
		end
		if command_string_option(value) then
			return arguments[index + 1]
		end
	end
end

local function identity_boundaries(length)
	local boundaries = {}
	for index = 0, length do
		boundaries[index] = index
	end
	return boundaries
end

local function quoted_payload(node, text)
	local start_row, start_col, end_row, end_col = node:range()
	if start_row ~= 0 or end_row ~= 0 or end_col <= start_col then
		return nil
	end
	local source = text:sub(start_col + 1, end_col)
	local node_type = node:type()
	if node_type ~= "string" and node_type ~= "raw_string" then
		return source, start_col, identity_boundaries(#source)
	end
	if #source < 2 then
		return nil
	end

	local content = source:sub(2, -2)
	local content_col = start_col + 1
	if node_type == "raw_string" then
		return content, content_col, identity_boundaries(#content)
	end

	local chunks = {}
	local boundaries = { [0] = 0 }
	local source_index = 1
	local output_length = 0
	while source_index <= #content do
		local value = content:sub(source_index, source_index)
		local consumed = 1
		if value == "\\" and source_index < #content then
			local escaped = content:sub(source_index + 1, source_index + 1)
			if escaped == "$" or escaped == "`" or escaped == '"' or escaped == "\\" then
				value = escaped
				consumed = 2
			end
		end
		table.insert(chunks, value)
		boundaries[output_length] = source_index - 1
		output_length = output_length + #value
		boundaries[output_length] = source_index - 1 + consumed
		source_index = source_index + consumed
	end
	return table.concat(chunks), content_col, boundaries
end

local function each_command(node, callback)
	if node:type() == "command" then
		callback(node)
	end
	for child in node:iter_children() do
		if child:named() then
			each_command(child, callback)
		end
	end
end

local function treesitter_spans(text, depth)
	local spans = {}
	depth = math.max(0, tonumber(depth) or 0)
	local ok = pcall(function()
		local parser = vim.treesitter.get_string_parser(text, "bash")
		local tree = parser:parse()[1]
		local query = vim.treesitter.query.get("bash", "highlights")
		if not tree or not query then
			return
		end
		for id, node in query:iter_captures(tree:root(), text, 0, -1) do
			local group = capture_group(query.captures[id])
			local start_row, start_col, end_row, end_col = node:range()
			if group and start_row == 0 and end_row == 0 and end_col > start_col then
				table.insert(spans, {
					start_col = start_col,
					end_col = end_col,
					group = group,
					priority = base_priority + depth * nested_priority_step,
				})
			end
		end
		if depth >= maximum_wrapper_depth then
			return
		end
		each_command(tree:root(), function(command)
			local argument = shell_command_argument(command, text)
			if not argument then
				return
			end
			local payload, source_col, boundaries = quoted_payload(argument, text)
			if not payload or payload == "" then
				return
			end
			for _, span in ipairs(treesitter_spans(payload, depth + 1)) do
				local start_col = boundaries[span.start_col]
				local end_col = boundaries[span.end_col]
				if start_col and end_col and end_col > start_col then
					table.insert(spans, {
						start_col = source_col + start_col,
						end_col = source_col + end_col,
						group = span.group,
						priority = span.priority,
					})
				end
			end
		end)
	end)
	return ok and spans or {}
end

function M.shell_spans(value)
	local text = tostring(value or "")
	if text == "" then
		return {}
	end
	return treesitter_spans(text)
end

return M
