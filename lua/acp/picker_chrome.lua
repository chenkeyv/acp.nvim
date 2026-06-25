local icons = require("acp.icons")

local M = {}

function M.title(icon, text)
	return ("%s %s"):format(icon or icons.acp, text or "ACP")
end

function M.footer(text)
	return ("%s %s"):format(text or "Press q/<Esc> to close.", icons.key)
end

function M.row(index, icon, text)
	return ("%d. %s %s"):format(index, icon or icons.section, text or "")
end

function M.detail(icon, text)
	return ("   %s %s"):format(icon or icons.note, text or "")
end

function M.badge(icon, text)
	return ("%s %s"):format(icon or icons.note, text or "")
end

return M
