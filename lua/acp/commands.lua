local icons = require("acp.icons")
local chrome = require("acp.picker_chrome")

local M = {}

function M.picker_lines(commands)
	local lines = { chrome.title(icons.command, "ACP Commands"), "" }
	local line_commands = {}
	for index, command in ipairs(commands or {}) do
		local name = command.name or ("command-" .. index)
		table.insert(lines, chrome.row(index, icons.command, ("/%s"):format(name)))
		line_commands[#lines] = command
		if command.description and command.description ~= "" then
			table.insert(lines, chrome.detail(icons.note, command.description))
			line_commands[#lines] = command
		end
		if command.input and command.input.hint and command.input.hint ~= "" then
			table.insert(lines, chrome.detail(icons.key, ("input: %s"):format(command.input.hint)))
			line_commands[#lines] = command
		end
	end

	table.insert(lines, "")
	table.insert(lines, chrome.footer("Press <Enter> to draft, or q/<Esc> to close."))
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

local function completion_menu(command)
	if command.input and command.input.hint and command.input.hint ~= "" then
		return ("%s %s"):format(icons.key, command.input.hint)
	end
	return icons.title("ACP")
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
					abbr = ("%s /%s"):format(icons.terminal, name),
					icon = icons.terminal,
					kind = "Function",
					dup = 0,
				}
				if command.description and command.description ~= "" then
					item.info = command.description
				end
				item.menu = completion_menu(command)
				table.insert(items, item)
			end
		end
	end

	return items
end

return M
