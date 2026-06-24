local M = {}

function M.picker_lines(actions)
	local lines = { "ACP Actions", "" }
	local line_actions = {}

	for index, action in ipairs(actions or {}) do
		local key = action.key and action.key ~= "" and ("  " .. action.key) or ""
		local scope = action.scope and action.scope ~= "" and (" [" .. action.scope .. "]") or ""
		table.insert(lines, ("%2d. %-22s%s"):format(index, action.label or "Action", key))
		line_actions[#lines] = action
		if action.detail and action.detail ~= "" then
			table.insert(lines, ("    %s%s"):format(action.detail, scope))
			line_actions[#lines] = action
		end
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to run, or q/<Esc> to close.")
	return lines, line_actions
end

return M
