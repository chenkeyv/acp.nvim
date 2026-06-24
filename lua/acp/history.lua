local M = {}

local function history_dir()
	return vim.fs.joinpath(vim.fn.stdpath("state"), "acp.nvim", "history")
end

local function sanitize(value)
	return tostring(value or "session"):gsub("[^%w._-]+", "-"):gsub("^-+", ""):gsub("-+$", "")
end

local function timestamp()
	return os.date("!%Y%m%dT%H%M%SZ")
end

local function ensure_dir()
	vim.fn.mkdir(history_dir(), "p")
end

local function session_path(state)
	if state.history_path then
		return state.history_path
	end

	ensure_dir()
	local name = ("%s-%s-%d.txt"):format(timestamp(), sanitize(state.adapter), state.id or 0)
	state.history_path = vim.fs.joinpath(history_dir(), name)
	state.history_created_at = state.history_created_at or timestamp()
	return state.history_path
end

local function metadata_value(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.save(state, lines)
	if not state or not lines then
		return nil
	end

	local path = session_path(state)
	local out = {
		"# ACP Transcript",
		("Title: %s"):format(metadata_value(state.title) or ("ACP " .. tostring(state.id or "?"))),
		("Adapter: %s"):format(metadata_value(state.adapter) or "?"),
		("Model: %s"):format(metadata_value(state.model) or "?"),
		("Created: %s"):format(state.history_created_at or timestamp()),
		("Updated: %s"):format(timestamp()),
		"",
	}

	vim.list_extend(out, lines)
	vim.fn.writefile(out, path)
	return path
end

local function header_value(lines, key)
	local prefix = key .. ": "
	for _, line in ipairs(lines) do
		if line:sub(1, #prefix) == prefix then
			return line:sub(#prefix + 1)
		end
	end
end

local function entry_for(path)
	local ok, lines = pcall(vim.fn.readfile, path, "", 12)
	if not ok then
		return nil
	end

	local stat = vim.uv.fs_stat(path)
	return {
		path = path,
		name = vim.fs.basename(path),
		title = header_value(lines, "Title") or vim.fs.basename(path),
		adapter = header_value(lines, "Adapter") or "?",
		model = header_value(lines, "Model") or "?",
		updated = header_value(lines, "Updated") or "?",
		mtime = stat and stat.mtime and stat.mtime.sec or 0,
	}
end

function M.entries()
	local files = vim.fn.globpath(history_dir(), "*.txt", false, true)
	local entries = {}
	for _, path in ipairs(files) do
		local entry = entry_for(path)
		if entry then
			table.insert(entries, entry)
		end
	end

	table.sort(entries, function(left, right)
		if left.mtime ~= right.mtime then
			return left.mtime > right.mtime
		end
		return left.name > right.name
	end)

	return entries
end

local function close_window(winid, bufnr)
	if winid and vim.api.nvim_win_is_valid(winid) then
		pcall(vim.api.nvim_win_close, winid, true)
	end
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

function M.open_entry(entry)
	if not entry or not entry.path then
		return false
	end

	local ok, lines = pcall(vim.fn.readfile, entry.path)
	if not ok then
		vim.notify(("Failed to read ACP history: %s"):format(entry.path), vim.log.levels.ERROR, { title = "ACP" })
		return false
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, ("ACP History://%s"):format(entry.name or vim.fs.basename(entry.path)))
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].filetype = "acp"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false

	vim.cmd("tabnew")
	vim.api.nvim_win_set_buf(0, bufnr)
	return true
end

local function browser_lines(entries)
	local lines = { "ACP History", "" }
	for index, entry in ipairs(entries) do
		table.insert(lines, ("%d. %s"):format(index, entry.title))
		table.insert(lines, ("   %s  %s  %s"):format(entry.updated, entry.adapter, entry.model))
	end
	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to open, or q/<Esc> to close.")
	return lines
end

local function window_config(lines)
	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, #line)
	end
	width = math.max(58, math.min(width + 4, vim.o.columns - 4))
	local height = math.max(8, math.min(#lines, vim.o.lines - 6))

	return {
		relative = "editor",
		row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " ACP history ",
		title_pos = "left",
		zindex = 65,
	}
end

function M.open_browser()
	local entries = M.entries()
	if #entries == 0 then
		vim.notify("No ACP history found", vim.log.levels.INFO, { title = "ACP" })
		return false
	end

	local lines = browser_lines(entries)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, "ACP://history")
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].filetype = "acp-history"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false

	local winid = vim.api.nvim_open_win(bufnr, true, window_config(lines))
	vim.wo[winid].cursorline = true
	pcall(vim.api.nvim_win_set_cursor, winid, { 3, 0 })

	local function selected_entry()
		local line = vim.api.nvim_win_get_cursor(winid)[1]
		local index = math.floor((line - 3) / 2) + 1
		return entries[index]
	end

	vim.keymap.set("n", "<CR>", function()
		local entry = selected_entry()
		close_window(winid, bufnr)
		M.open_entry(entry)
	end, { buffer = bufnr, nowait = true, desc = "Open ACP history entry" })

	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, function()
			close_window(winid, bufnr)
		end, { buffer = bufnr, nowait = true, desc = "Close ACP history" })
	end

	return true
end

return M
