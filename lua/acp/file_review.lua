local M = {}
local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")

local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true })
end

local function line_count(text)
	if text == "" then
		return 0
	end
	return #split_lines(text)
end

local function unified_diff(before, after)
	if before == after then
		return { "No changes." }
	end

	local ok, diff = pcall(vim.diff, before, after, {
		result_type = "unified",
		ctxlen = 3,
	})
	if ok and diff and diff ~= "" then
		return split_lines(diff:gsub("\n$", ""))
	end

	return {
		"Diff preview is unavailable.",
		("Current content: %d line(s)"):format(line_count(before)),
		("Proposed content: %d line(s)"):format(line_count(after)),
	}
end

local function requests_for(request)
	if type(request) ~= "table" then
		return {}
	end
	if type(request.files) == "table" then
		return request.files
	end
	return { request }
end

local function request_path(request)
	return request.display_path or request.path or "[No Name]"
end

function M.lines(request)
	local requests = requests_for(request)
	local count = #requests
	local lines = {
		chrome.title(icons.file, "File write review"),
		("Files: %d %s"):format(count, icons.file),
		"",
		count == 1 and ("1. Apply write %s"):format(icons.edit) or ("1. Apply %d writes %s"):format(count, icons.edit),
		("2. Cancel %s"):format(icons.warning),
		"",
	}

	for index, item in ipairs(requests) do
		local path = request_path(item)
		local before = item.before or ""
		local after = item.after or ""
		if count == 1 then
			table.insert(lines, ("File: %s %s"):format(path, icons.file))
		else
			table.insert(lines, ("File %d/%d: %s %s"):format(index, count, path, icons.file))
		end
		table.insert(lines, ("Current: %d line(s) %s"):format(line_count(before), icons.history))
		table.insert(lines, ("Proposed: %d line(s) %s"):format(line_count(after), icons.edit))
		table.insert(lines, ("--- %s (current)"):format(path))
		table.insert(lines, ("+++ %s (proposed)"):format(path))
		vim.list_extend(lines, unified_diff(before, after))
		if index < count then
			table.insert(lines, "")
		end
	end

	return lines
end

local function close_window(winid, bufnr)
	if winid and vim.api.nvim_win_is_valid(winid) then
		pcall(vim.api.nvim_win_close, winid, true)
	end
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

local function window_config(lines)
	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, #line)
	end
	width = math.max(64, math.min(width + 4, vim.o.columns - 4))
	local height = math.max(12, math.min(#lines, vim.o.lines - 6))

	return {
		relative = "editor",
		row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = (" %s ACP file write "):format(icons.file),
		title_pos = "left",
		zindex = 70,
	}
end

function M.select(request, callback)
	local lines = M.lines(request)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, "ACP://file-review")
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].filetype = "diff"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false

	local winid = vim.api.nvim_open_win(bufnr, true, window_config(lines))
	vim.wo[winid].wrap = false
	vim.wo[winid].cursorline = true

	local done = false
	local finish = function(approved)
		if done then
			return
		end
		done = true
		close_window(winid, bufnr)
		callback(approved)
	end

	for _, key in ipairs({ "1", "a", "A", "<CR>" }) do
		vim.keymap.set("n", key, function()
			finish(true)
		end, { buffer = bufnr, nowait = true, desc = "Apply ACP file write" })
	end

	for _, key in ipairs({ "2", "q", "<Esc>" }) do
		vim.keymap.set("n", key, function()
			finish(false)
		end, { buffer = bufnr, nowait = true, desc = "Cancel ACP file write" })
	end

	return bufnr, winid
end

return M
