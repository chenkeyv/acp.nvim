local M = {}

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

function M.lines(request)
	request = request or {}
	local path = request.display_path or request.path or "[No Name]"
	local before = request.before or ""
	local after = request.after or ""
	local lines = {
		"File write review",
		("File: %s"):format(path),
		("Current: %d line(s)"):format(line_count(before)),
		("Proposed: %d line(s)"):format(line_count(after)),
		"",
		"1. Apply write",
		"2. Cancel",
		"",
		("--- %s (current)"):format(path),
		("+++ %s (proposed)"):format(path),
	}

	vim.list_extend(lines, unified_diff(before, after))
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
		title = " ACP file write ",
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
