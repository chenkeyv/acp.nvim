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

local function option_meta_label(option)
	local parts = { ("%s %s"):format(icons.type, option and option.type or "unknown") }
	if type(option and option.options) == "table" then
		local count = #option.options
		local noun = count == 1 and "value" or "values"
		table.insert(parts, ("%s %d %s"):format(icons.config, count, noun))
	end
	if option and option.category and option.category ~= "" then
		table.insert(parts, ("%s %s"):format(icons.package, option.category))
	end
	return table.concat(parts, "  ")
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
		table.insert(lines, chrome.detail(icons.inspect, option_meta_label(option)))
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
		local marker = choice.value == option.currentValue and (" %s current"):format(icons.preferred) or ""
		table.insert(
			lines,
			("%d. %s %s%s"):format(index, icons.config, display_name(choice, tostring(choice.value)), marker)
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

function M.preview(option)
	if type(option) ~= "table" then
		return nil
	end

	local lines = {
		chrome.title(icons.config, M.option_label(option)),
		"",
		("%s Current: %s"):format(icons.preferred, M.value_label(option, option.currentValue)),
		("%s Id: %s"):format(icons.config, option.id or "?"),
		("%s Type: %s"):format(icons.type, option.type or "?"),
	}
	if option.category and option.category ~= "" then
		table.insert(lines, ("%s Category: %s"):format(icons.package, option.category))
	end
	if option.description and option.description ~= "" then
		table.insert(lines, ("%s %s"):format(icons.note, option.description))
	end

	local choices = {}
	for _, choice in ipairs(option.options or {}) do
		local label = display_name(choice, tostring(choice.value))
		if choice.value == option.currentValue then
			label = label .. " current"
		end
		table.insert(choices, label)
	end
	if #choices > 0 then
		table.insert(lines, "")
		table.insert(lines, ("%s Values"):format(icons.config))
		for _, label in ipairs(choices) do
			table.insert(lines, ("- %s"):format(label))
		end
	end

	return {
		lines = lines,
		filetype = "acp-sessions",
		title = (" %s ACP config %s "):format(icons.config, M.option_label(option)),
		title_icon = icons.config,
	}
end

function M.value_preview(option, choice)
	if type(choice) ~= "table" then
		return nil
	end

	local selected = choice.value == (option and option.currentValue)
	local lines = {
		chrome.title(icons.config, display_name(choice, tostring(choice.value))),
		"",
		("%s Option: %s"):format(icons.config, M.option_label(option)),
		("%s Value: %s"):format(icons.type, tostring(choice.value)),
		("%s State: %s"):format(icons.preferred, selected and "current" or "available"),
	}
	if choice.description and choice.description ~= "" then
		table.insert(lines, ("%s %s"):format(icons.note, choice.description))
	end

	return {
		lines = lines,
		filetype = "acp-sessions",
		title = (" %s ACP value %s "):format(icons.config, display_name(choice, tostring(choice.value))),
		title_icon = icons.config,
	}
end

return M
