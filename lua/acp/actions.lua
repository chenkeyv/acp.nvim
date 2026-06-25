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
	if lower:find("prompt", 1, true) then
		return icons.prompt
	end
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
	if lower:find("help", 1, true) then
		return icons.help
	end
	if lower:find("send", 1, true) then
		return icons.send
	end
	if lower:find("stop", 1, true) then
		return icons.stop
	end
	if lower:find("inspect", 1, true) then
		return icons.inspect
	end
	if lower:find("yank", 1, true) or lower:find("copy", 1, true) then
		return icons.yank
	end
	if lower:find("draft", 1, true) or lower:find("rename", 1, true) then
		return icons.edit
	end
	if lower:find("previous", 1, true) or lower:find("next", 1, true) then
		return icons.jump
	end
	if lower:find("command", 1, true) or lower:find("slash", 1, true) then
		return icons.command
	end
	if lower:find("config", 1, true) then
		return icons.config
	end
	if lower:find("change", 1, true) then
		return icons.changes
	end
	if lower:find("tree", 1, true) then
		return icons.treesitter
	end
	if lower:find("symbol", 1, true) then
		return icons.symbol
	end
	if lower:find("call", 1, true) or lower:find("callee", 1, true) then
		return icons.call
	end
	if lower:find("type", 1, true) or lower:find("supertype", 1, true) or lower:find("subtype", 1, true) then
		return icons.type
	end
	if lower:find("inlay", 1, true) or lower:find("signature", 1, true) or lower:find("hover", 1, true) then
		return icons.hint
	end
	if lower:find("selection", 1, true) or lower:find("highlight", 1, true) then
		return icons.scope
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
	if lower:find("link", 1, true) then
		return icons.link
	end
	if lower:find("reference", 1, true) or lower:find("location", 1, true) then
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
	if lower:find("open", 1, true) or lower:find("jump", 1, true) or lower:find("focus", 1, true) then
		return icons.jump
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
		local scope_chip = scope and ("  %s %s"):format(scope_icon(scope), scope) or ""
		table.insert(
			lines,
			("%2d. %s %-24s%s%s"):format(
				index,
				action_icon(action),
				clean(action.label) or "Action",
				scope_chip,
				key_chip
			)
		)
		line_actions[#lines] = action
		if action.detail and action.detail ~= "" then
			table.insert(lines, ("    %s %s"):format(icons.note, clean(action.detail) or ""))
			line_actions[#lines] = action
		end
	end

	table.insert(lines, "")
	table.insert(lines, ("Press <Enter> to run, or q/<Esc> to close. %s"):format(icons.key))
	return lines, line_actions
end

function M.preview(action)
	if type(action) ~= "table" then
		return nil
	end

	local label = clean(action.label) or "Action"
	local detail = clean(action.detail)
	local key = clean(action.key)
	local scope = clean(action.scope)
	local icon = action_icon(action)
	local lines = { icons.title(label, icon), "" }

	if detail then
		table.insert(lines, ("%s %s"):format(icons.note, detail))
	end
	if scope then
		table.insert(lines, ("%s Scope: %s"):format(scope_icon(scope), scope))
	end
	if key then
		table.insert(lines, ("%s Key: %s"):format(icons.key, key))
	end

	table.insert(lines, "")
	table.insert(lines, ("%s Press <Enter> to run this workflow."):format(icons.send))
	table.insert(lines, ("%s q/<Esc> closes the picker."):format(icons.key))

	return {
		lines = lines,
		filetype = "acp",
		title = (" %s ACP action "):format(icon),
		title_icon = icon,
	}
end

function M.previewer(line_actions, fallback)
	return function(row, view)
		local preview = M.preview(line_actions and line_actions[row])
		if not preview then
			return fallback and fallback(row, view) or nil
		end

		local extra = fallback and fallback(row, view) or nil
		if extra and type(extra.lines) == "table" and #extra.lines > 0 then
			table.insert(preview.lines, "")
			table.insert(preview.lines, ("%s Context"):format(icons.inspect))
			vim.list_extend(preview.lines, extra.lines)
		end
		return preview
	end
end

return M
