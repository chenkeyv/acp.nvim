local icons = require("acp.icons")

local M = {}

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function short(value, limit)
	local label = clean(value)
	if not label then
		return nil
	end
	limit = limit or 36
	if #label > limit then
		return label:sub(1, limit - 3) .. "..."
	end
	return label
end

local function status_label(session)
	return clean(session and session.run_status) or (session and session.busy and "running" or "idle")
end

local function status_style(status)
	status = status or "idle"
	if status:match("^error") then
		return (" %s ERROR "):format(icons.error), "AcpSessionError"
	end
	if status == "idle" or status:match("^stopped") or status:match("^restored") then
		return (" %s IDLE "):format(icons.idle), "AcpSessionIdle"
	end
	return (" %s BUSY "):format(icons.busy), "AcpSessionBusy"
end

function M.define_highlights()
	vim.api.nvim_set_hl(0, "AcpSessionHeader", { fg = "#7aa2f7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpSessionCurrent", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "AcpSessionMeta", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpSessionIdle", { link = "DiagnosticOk", default = true })
	vim.api.nvim_set_hl(0, "AcpSessionBusy", { fg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpSessionError", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "AcpSessionChanged", { fg = "#1a1b26", bg = "#9ece6a", bold = true, default = true })
end

local function stats_label(stats)
	if type(stats) ~= "table" then
		return nil
	end

	local parts = {}
	if tonumber(stats.sections) and stats.sections > 0 then
		table.insert(parts, ("%d sec"):format(stats.sections))
	end
	if tonumber(stats.code_blocks) and stats.code_blocks > 0 then
		table.insert(parts, ("%d code"):format(stats.code_blocks))
	end
	if tonumber(stats.locations) and stats.locations > 0 then
		table.insert(parts, ("%d loc"):format(stats.locations))
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "  ")
end

local function meta_label(session)
	local parts = {}
	local stats = stats_label(session and session.transcript_stats)
	if stats then
		table.insert(parts, stats)
	end
	local source = short(session and session.source_label, 42)
	if source then
		table.insert(parts, source)
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "  |  ")
end

function M.panel(sessions, current_id, change_count)
	local lines = { "Sessions", "" }
	local line_ids = {}
	local styles = {
		[1] = {
			line_hl_group = "AcpSessionHeader",
			virt_text = { { (" %s <leader>ak actions "):format(icons.action), "AcpSessionMeta" } },
		},
	}

	for _, session in ipairs(sessions or {}) do
		local changes = change_count and change_count(session) or 0
		local status = status_label(session)
		local badge, badge_hl = status_style(status)
		local marker = session.id == current_id and ">" or " "
		local model = clean(session.model)
		local title = ("%s #%d %s%s %s"):format(
			marker,
			session.id or 0,
			clean(session.adapter) or "?",
			model and (" " .. model) or "",
			icons.session
		)

		table.insert(lines, title)
		line_ids[#lines] = session.id
		styles[#lines] = {
			line_hl_group = session.id == current_id and "AcpSessionCurrent" or nil,
			virt_text = { { badge, badge_hl } },
		}

		local detail = status
		if changes > 0 then
			detail = ("%s  %d change(s)"):format(detail, changes)
		end
		table.insert(lines, ("  %s"):format(detail))
		line_ids[#lines] = session.id
		styles[#lines] = {
			line_hl_group = badge_hl,
			virt_text = changes > 0 and {
				{ (" %s %d change(s) "):format(icons.changes, changes), "AcpSessionChanged" },
			} or nil,
		}

		local meta = meta_label(session)
		if meta then
			table.insert(lines, ("  %s"):format(meta))
			line_ids[#lines] = session.id
			styles[#lines] = {
				line_hl_group = "AcpSessionMeta",
			}
		end
	end

	return lines, line_ids, styles
end

local function restore_title(session)
	return clean(session and session.title) or clean(session and session.sessionId) or "[untitled]"
end

function M.restore_lines(list)
	local lines = { ("%s ACP Adapter Sessions"):format(icons.restore), "" }
	local line_sessions = {}

	for index, session in ipairs(list or {}) do
		local parts = {}
		local session_id = clean(session.sessionId)
		local updated = clean(session.updatedAt)
		local model = clean(session.model)
		local cwd = clean(session.cwd) or "[unknown cwd]"

		if session_id then
			table.insert(parts, ("id %s"):format(short(session_id, 28)))
		end
		if updated then
			table.insert(parts, ("updated %s"):format(short(updated, 34)))
		end
		if model then
			table.insert(parts, ("model %s"):format(short(model, 28)))
		end

		table.insert(lines, ("%d. %s %s"):format(index, short(restore_title(session), 72), icons.restore))
		line_sessions[#lines] = session
		table.insert(lines, ("   %s"):format(#parts > 0 and table.concat(parts, "  ") or "no metadata"))
		line_sessions[#lines] = session
		table.insert(lines, ("   cwd %s"):format(short(cwd, 72)))
		line_sessions[#lines] = session
	end

	table.insert(lines, "")
	table.insert(lines, ("Press <Enter> to restore, or q/<Esc> to close. %s"):format(icons.key))
	return lines, line_sessions
end

function M.restore_preview(session)
	if not session then
		return nil
	end

	local lines = {
		("%s ACP Adapter Session"):format(icons.restore),
		"",
		("Title: %s"):format(restore_title(session)),
	}
	local fields = {
		{ "Session ID", session.sessionId },
		{ "Updated", session.updatedAt },
		{ "Created", session.createdAt },
		{ "Cwd", session.cwd },
		{ "Model", session.model },
	}
	for _, field in ipairs(fields) do
		local value = clean(field[2])
		if value then
			table.insert(lines, ("%s: %s"):format(field[1], value))
		end
	end

	return {
		lines = lines,
		filetype = "acp-sessions",
		title = (" %s ACP restore %s "):format(icons.restore, short(restore_title(session), 32)),
	}
end

return M
