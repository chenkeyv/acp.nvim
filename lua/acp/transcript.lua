local icons = require("acp.icons")

local M = {}

local icon_names = {
	"user",
	"agent",
	"section",
	"command",
	"tool",
	"changes",
	"warning",
	"error",
	"context",
	"note",
	"info",
}

local headers = {
	agent = { icon = "agent", label = "Codex" },
	plan = { icon = "section", label = "Plan" },
	review = { icon = "section", label = "Review" },
	user = { icon = "user", label = "You" },
}

local prefixes = {}
local seen_prefixes = {}
for _, name in ipairs(icon_names) do
	for _, glyph in ipairs(icons.variants(name)) do
		if not seen_prefixes[glyph] then
			seen_prefixes[glyph] = true
			table.insert(prefixes, { name = name, glyph = glyph, value = glyph .. " " })
		end
	end
end

local function failed_content(content)
	local exit_code = tonumber(content:match("^Command.-%(exit%s+([+-]?%d+)%)"))
	return content:match("^Error:") ~= nil
		or content:match("failed") ~= nil
		or content:match("cancelled") ~= nil
		or content:match("canceled") ~= nil
		or (exit_code ~= nil and exit_code ~= 0)
end

local function content_kind(content)
	content = tostring(content or "")
	if failed_content(content) then
		return "error"
	elseif content:match("^Warning:") then
		return "warning"
	elseif content:match("^Command") then
		return "command"
	elseif content:match("^Tool") then
		return "tool"
	elseif content:match("^File changes") or content:match("^[%a%s]+%s+`[^`]+`") then
		return "changes"
	elseif content:match("^Context:") then
		return "context"
	elseif content:match("review mode") or content:match("context compacted") then
		return "note"
	end
	return "info"
end

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

function M.parse(line)
	line = tostring(line or "")
	for _, prefix in ipairs(prefixes) do
		if line:sub(1, #prefix.value) == prefix.value then
			local content = line:sub(#prefix.value + 1)
			local kind = (prefix.glyph == ">" or prefix.glyph == "!") and content_kind(content) or prefix.name
			return content, kind, prefix.glyph
		end
	end
	return line, nil, nil
end

function M.header_kind(line)
	line = tostring(line or "")
	if line == "You" or line:match("^##%s+You") then
		return "user"
	end
	if line == "Agent" or line == "# Codex" or line:match("^Agent:%s+") or line:match("^##%s+Codex") then
		return "agent"
	end
	local heading = line:match("^###%s+(.+)")
	if heading then
		return heading:lower()
	end
	local content, icon = M.parse(line)
	if icon == "user" and content:match("^You") then
		return "user"
	elseif icon == "agent" and content:match("^Codex") then
		return "agent"
	elseif icon == "section" and content:match("^Plan") then
		return "plan"
	elseif icon == "section" and content:match("^Review") then
		return "review"
	end
end

function M.activity_kind(content)
	return content_kind(content)
end

function M.migrate_line(line)
	line = tostring(line or "")
	local kind = M.header_kind(line)
	if kind == "user" then
		local content = M.parse(line)
		return M.header("user", line:match("^##%s+You(.*)$") or content:match("^You(.*)$") or "")
	elseif kind == "agent" then
		local status = line:match("^Agent:%s*(.+)$")
		local content, icon = M.parse(line)
		local suffix = icon == "agent" and content:match("^Codex(.*)$") or ""
		return M.header("agent", status and (" · " .. status) or suffix)
	elseif kind == "plan" then
		return M.header("plan")
	elseif kind == "review" then
		return M.header("review")
	end
	local direct, direct_kind = M.parse(line)
	if direct_kind then
		return M.line(direct_kind, direct)
	end
	local quote = line:match("^>%s*(.*)")
	if quote then
		return M.line(M.activity_kind(quote), quote)
	end
	return line
end

return M
