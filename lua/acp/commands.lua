local M = {}

function M.picker_lines(commands)
	local lines = { "ACP Commands", "" }
	local line_commands = {}
	for index, command in ipairs(commands or {}) do
		local name = command.name or ("command-" .. index)
		table.insert(lines, ("%d. /%s"):format(index, name))
		line_commands[#lines] = command
		if command.description and command.description ~= "" then
			table.insert(lines, ("   %s"):format(command.description))
			line_commands[#lines] = command
		end
		if command.input and command.input.hint and command.input.hint ~= "" then
			table.insert(lines, ("   input: %s"):format(command.input.hint))
			line_commands[#lines] = command
		end
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to draft, or q/<Esc> to close.")
	return lines, line_commands
end

function M.slash_text(command)
	local name = command and command.name
	if type(name) ~= "string" or name == "" then
		return nil
	end

	local text = "/" .. name
	if command.input then
		text = text .. " "
	end
	return text
end

function M.completion_start(line, cursor_col)
	line = line or ""
	cursor_col = cursor_col or #line
	local before_cursor = line:sub(1, cursor_col)
	local start = before_cursor:match("^()/%S*$")
	if not start then
		return -3
	end
	return start - 1
end

function M.completion_items(commands, base)
	base = base or ""
	if base:sub(1, 1) ~= "/" then
		return {}
	end

	local prefix = base:sub(2):lower()
	local items = {}
	for _, command in ipairs(commands or {}) do
		local name = command.name
		if type(name) == "string" and name ~= "" and name:lower():sub(1, #prefix) == prefix then
			local word = M.slash_text(command)
			if word then
				local item = {
					word = word,
					abbr = "/" .. name,
					kind = "Function",
					dup = 0,
				}
				if command.description and command.description ~= "" then
					item.info = command.description
				end
				if command.input and command.input.hint and command.input.hint ~= "" then
					item.menu = command.input.hint
				else
					item.menu = "ACP"
				end
				table.insert(items, item)
			end
		end
	end

	return items
end

return M
