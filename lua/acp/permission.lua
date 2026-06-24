local M = {}

local function clean(value)
	return tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function option_label(option)
	return clean(option.name or option.kind or option.optionId or "option")
end

local function append_field(lines, label, value)
	if value == nil or value == "" or value == vim.NIL then
		return
	end
	table.insert(lines, ("%s: %s"):format(label, clean(value)))
end

function M.option_labels(options)
	local labels = {}
	for _, option in ipairs(options or {}) do
		table.insert(labels, option_label(option))
	end
	return labels
end

function M.lines(params)
	params = params or {}
	local options = params.options or {}
	local tool = params.toolCall or {}
	local lines = {
		"Permission request",
		"",
	}

	append_field(lines, "Tool", tool.title or tool.name)
	append_field(lines, "Kind", tool.kind)
	append_field(lines, "Status", tool.status)
	append_field(lines, "Description", tool.description)
	append_field(lines, "Location", tool.location or tool.path)
	append_field(lines, "Request", params.title or params.description or params.prompt)

	if #lines > 2 then
		table.insert(lines, "")
	end

	table.insert(lines, "Options")
	for index, option in ipairs(options) do
		local key = index <= 9 and tostring(index) or "-"
		table.insert(lines, ("  %s. %s"):format(key, option_label(option)))
		append_field(lines, "     Outcome", option.optionId)
		append_field(lines, "     Kind", option.kind)
		append_field(lines, "     Description", option.description)
	end

	table.insert(lines, "")
	table.insert(lines, "Press 1-9 to choose, <CR> for the first option, or q/<Esc> to cancel.")
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
	width = math.max(48, math.min(width + 4, vim.o.columns - 4))
	local height = math.max(8, math.min(#lines, vim.o.lines - 6))

	return {
		relative = "editor",
		row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " ACP permission ",
		title_pos = "left",
		zindex = 70,
	}
end

function M.select(params, callback)
	params = params or {}
	local options = params.options or {}
	local lines = M.lines(params)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, "ACP://permission")
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].filetype = "acp-permission"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false

	local winid = vim.api.nvim_open_win(bufnr, true, window_config(lines))
	vim.wo[winid].wrap = true
	vim.wo[winid].linebreak = true
	vim.wo[winid].cursorline = true

	local done = false
	local finish = function(option)
		if done then
			return
		end
		done = true
		close_window(winid, bufnr)
		callback(option)
	end

	vim.keymap.set("n", "<CR>", function()
		finish(options[1])
	end, { buffer = bufnr, nowait = true, desc = "Choose first ACP permission option" })

	for index = 1, math.min(#options, 9) do
		vim.keymap.set("n", tostring(index), function()
			finish(options[index])
		end, { buffer = bufnr, nowait = true, desc = ("Choose ACP permission option %d"):format(index) })
	end

	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, function()
			finish(nil)
		end, { buffer = bufnr, nowait = true, desc = "Cancel ACP permission request" })
	end

	return bufnr, winid
end

return M
