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

return M
