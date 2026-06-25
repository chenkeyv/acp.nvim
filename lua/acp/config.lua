local M = {}
local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")

local function display_name(item, fallback)
	local name = item and item.name
	if type(name) == "string" and name ~= "" then
		return name
	end
	return fallback
end

function M.select_options(config_options)
	local out = {}
	for _, option in ipairs(config_options or {}) do
		if
			type(option) == "table"
			and type(option.id) == "string"
			and option.id ~= ""
			and option.type == "select"
			and type(option.options) == "table"
			and #option.options > 0
		then
			table.insert(out, option)
		end
	end
	return out
end

function M.value_label(option, value)
	for _, choice in ipairs((option and option.options) or {}) do
		if choice.value == value then
			return display_name(choice, tostring(value))
		end
	end
	return value ~= nil and tostring(value) or "[unset]"
end

function M.option_label(option)
	return display_name(option, option and option.id or "[unknown]")
end

function M.picker_lines(config_options)
	local options = M.select_options(config_options)
	local lines = { chrome.title(icons.config, "ACP Config"), "" }
	local line_options = {}
	for index, option in ipairs(options) do
		local category = option.category and option.category ~= "" and (" [" .. option.category .. "]") or ""
		table.insert(
			lines,
			chrome.row(
				index,
				icons.config,
				("%s: %s%s"):format(M.option_label(option), M.value_label(option, option.currentValue), category)
			)
		)
		line_options[#lines] = option
		if option.description and option.description ~= "" then
			table.insert(lines, chrome.detail(icons.note, option.description))
			line_options[#lines] = option
		end
	end

	table.insert(lines, "")
	table.insert(lines, chrome.footer("Press <Enter> to edit, or q/<Esc> to close."))
	return lines, line_options
end

function M.value_lines(option)
	local lines = { chrome.title(icons.config, ("ACP Config: %s"):format(M.option_label(option))), "" }
	local line_values = {}
	for index, choice in ipairs((option and option.options) or {}) do
		local marker = choice.value == option.currentValue and " *" or ""
		table.insert(
			lines,
			("%d. %s%s %s"):format(index, display_name(choice, tostring(choice.value)), marker, icons.config)
		)
		line_values[#lines] = choice
		if choice.description and choice.description ~= "" then
			table.insert(lines, chrome.detail(icons.note, choice.description))
			line_values[#lines] = choice
		end
	end

	table.insert(lines, "")
	table.insert(lines, chrome.footer("Press <Enter> to apply, or q/<Esc> to close."))
	return lines, line_values
end

return M
