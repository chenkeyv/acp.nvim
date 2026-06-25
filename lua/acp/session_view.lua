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
		return " ERROR ", "AcpSessionError"
	end
	if status == "idle" or status:match("^stopped") or status:match("^restored") then
		return " IDLE ", "AcpSessionIdle"
	end
	return " BUSY ", "AcpSessionBusy"
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
			virt_text = { { " <leader>ak actions ", "AcpSessionMeta" } },
		},
	}

	for _, session in ipairs(sessions or {}) do
		local changes = change_count and change_count(session) or 0
		local status = status_label(session)
		local badge, badge_hl = status_style(status)
		local marker = session.id == current_id and ">" or " "
		local model = clean(session.model)
		local title = ("%s #%d %s%s"):format(
			marker,
			session.id or 0,
			clean(session.adapter) or "?",
			model and (" " .. model) or ""
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
			virt_text = changes > 0 and { { (" %d change(s) "):format(changes), "AcpSessionChanged" } } or nil,
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

return M
