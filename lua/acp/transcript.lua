local icons = require("acp.icons")

local M = {}

local headers = {
	agent = { icon = "agent", label = "Codex" },
	plan = { icon = "section", label = "Plan" },
	review = { icon = "section", label = "Review" },
	user = { icon = "user", label = "You" },
}

function M.line(kind, content)
	return ("%s %s"):format(icons.get(kind), tostring(content or ""))
end

function M.header(kind, suffix)
	local header = headers[kind]
	if not header then
		return M.line("section", tostring(kind or "Section"))
	end
	return M.line(header.icon, header.label .. tostring(suffix or ""))
end

return M
