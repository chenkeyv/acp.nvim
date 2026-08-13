local M = {}

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

local function preview_text(value)
	local text = tostring(value or "")
	local marker = text:find("… (K to inspect)", 1, true)
	if marker then
		text = text:sub(1, marker - 1):gsub("%s+$", "")
	end
	if text:match("^… %+%d+ lines") then
		return ""
	end
	return text
end

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

local function treesitter_spans(text)
	local spans = {}
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
				})
			end
		end
	end)
	return ok and spans or {}
end

local function lexical_spans(text)
	local spans = {}
	local function append(pattern, group)
		local start = 1
		while true do
			local first, last = text:find(pattern, start)
			if not first then
				return
			end
			table.insert(spans, { start_col = first - 1, end_col = last, group = group })
			start = last + 1
		end
	end

	local first, last = text:find("^%s*[^%s|&;]+")
	if first then
		local command_start = text:find("%S", first)
		table.insert(spans, {
			start_col = (command_start or first) - 1,
			end_col = last,
			group = "AcpShellCommand",
		})
	end
	append("'[^']*'", "AcpShellString")
	append('"[^"]*"', "AcpShellString")
	append("%$[%w_]+", "AcpShellVariable")
	append("&&", "AcpShellOperator")
	append("||", "AcpShellOperator")
	append("[|;]", "AcpShellOperator")
	return spans
end

function M.shell_spans(value)
	local text = preview_text(value)
	if text == "" then
		return {}
	end
	local spans = treesitter_spans(text)
	return #spans > 0 and spans or lexical_spans(text)
end

return M
