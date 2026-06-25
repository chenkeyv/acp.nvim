local icons = require("acp.icons")

local M = {}

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function scope_icon(scope)
	scope = clean(scope)
	if not scope then
		return icons.action
	end

	local lower = scope:lower()
	if lower:find("tree", 1, true) then
		return icons.treesitter
	end
	if lower:find("lsp", 1, true) then
		return icons.lsp
	end
	if lower:find("source", 1, true) then
		return icons.source
	end
	if lower:find("output", 1, true) then
		return icons.map
	end
	if lower:find("session", 1, true) then
		return icons.session
	end
	if lower:find("global", 1, true) then
		return icons.acp
	end
	return icons.action
end

local function action_icon(action)
	local label = clean(action and action.label) or ""
	local lower = label:lower()
	if lower:find("quickfix", 1, true) then
		return icons.quickfix
	end
	if lower:find("diagnostic", 1, true) or lower:find("problem", 1, true) then
		return icons.diagnostics
	end
	if lower:find("search", 1, true) then
		return icons.search
	end
	if lower:find("map", 1, true) or lower:find("outline", 1, true) or lower:find("item", 1, true) then
		return icons.map
	end
	if lower:find("code", 1, true) then
		return icons.code
	end
	if lower:find("reference", 1, true) or lower:find("location", 1, true) or lower:find("link", 1, true) then
		return icons.reference
	end
	if lower:find("color", 1, true) then
		return icons.color
	end
	if lower:find("fold", 1, true) then
		return icons.fold
	end
	if lower:find("history", 1, true) then
		return icons.history
	end
	if lower:find("restore", 1, true) then
		return icons.restore
	end
	if lower:find("context", 1, true) then
		return icons.context
	end
	return scope_icon(action and action.scope)
end

function M.picker_lines(actions)
	local lines = { ("%s ACP Actions"):format(icons.action), "" }
	local line_actions = {}

	for index, action in ipairs(actions or {}) do
		local key = clean(action.key)
		local key_chip = key and ("  %s %s"):format(icons.key, key) or ""
		local scope = clean(action.scope)
		local scope_chip = scope and (" [%s] %s"):format(scope, scope_icon(scope)) or ""
		table.insert(
			lines,
			("%2d. %s %-24s%s"):format(index, action_icon(action), clean(action.label) or "Action", key_chip)
		)
		line_actions[#lines] = action
		if action.detail and action.detail ~= "" then
			table.insert(lines, ("    %s %s%s"):format(icons.note, clean(action.detail) or "", scope_chip))
			line_actions[#lines] = action
		end
	end

	table.insert(lines, "")
	table.insert(lines, ("Press <Enter> to run, or q/<Esc> to close. %s"):format(icons.key))
	return lines, line_actions
end

return M
