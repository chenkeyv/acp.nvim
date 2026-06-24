local M = {}

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function set_buf_options(bufnr, opts)
	for key, value in pairs(opts) do
		vim.bo[bufnr][key] = value
	end
end

local function matches_query(line, query)
	if query == "" then
		return true
	end

	line = line:lower()
	for term in query:lower():gmatch("%S+") do
		if not line:find(term, 1, true) then
			return false
		end
	end
	return true
end

function M.window_config(lines, opts)
	opts = opts or {}

	local width = 0
	for _, line in ipairs(lines or {}) do
		width = math.max(width, #line)
	end

	local max_width = math.max(1, vim.o.columns - 4)
	local min_width = opts.min_width or 50
	width = math.min(math.max(min_width, width + (opts.padding or 4)), max_width)

	local max_height = math.max(1, vim.o.lines - 6)
	local min_height = opts.min_height or 8
	local height = math.min(math.max(min_height, #(lines or {})), max_height)

	return {
		relative = "editor",
		row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = opts.title or " ACP ",
		title_pos = opts.title_pos or "left",
		zindex = opts.zindex or 65,
	}
end

function M.close(winid, bufnr)
	if valid_win(winid) then
		pcall(vim.api.nvim_win_close, winid, true)
	end
	if valid_buf(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

function M.open(opts)
	opts = opts or {}
	local lines = opts.lines or { "" }
	local source_lines = vim.deepcopy(lines)
	local query = ""
	local display_rows = {}
	local bufnr = vim.api.nvim_create_buf(false, true)
	if opts.name then
		vim.api.nvim_buf_set_name(bufnr, opts.name)
	end
	set_buf_options(bufnr, {
		bufhidden = "wipe",
		buftype = "nofile",
		filetype = opts.filetype or "acp",
		modifiable = true,
		swapfile = false,
	})

	local config_opts = {
		min_width = opts.min_width,
		min_height = opts.min_height,
		padding = opts.padding,
		title = opts.title,
		title_pos = opts.title_pos,
		zindex = opts.zindex,
	}

	local function filtered_lines()
		local visible = {}
		local rows = {}

		if query ~= "" then
			table.insert(visible, ("Filter: %s"):format(query))
			rows[#visible] = nil
			table.insert(visible, "")
			rows[#visible] = nil
		end

		for index, line in ipairs(source_lines) do
			if matches_query(line, query) then
				table.insert(visible, line)
				rows[#visible] = index
			end
		end

		if query ~= "" then
			if #visible == 2 then
				table.insert(visible, "No matching picker entries.")
				rows[#visible] = nil
			end
			table.insert(visible, "")
			rows[#visible] = nil
			table.insert(visible, "Press <Enter> to select, <C-l> to clear, or q/<Esc> to close.")
			rows[#visible] = nil
		end

		return visible, rows
	end

	local rendered
	local function render()
		rendered, display_rows = filtered_lines()
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, rendered)
		vim.bo[bufnr].modifiable = false
	end

	render()

	local winid = vim.api.nvim_open_win(bufnr, true, M.window_config(rendered, config_opts))
	vim.wo[winid].cursorline = true
	pcall(vim.api.nvim_win_set_cursor, winid, { opts.initial_line or 3, 0 })

	local view = {
		bufnr = bufnr,
		winid = winid,
	}

	function view.close()
		M.close(winid, bufnr)
	end

	function view.row()
		if not valid_win(winid) then
			return nil
		end
		return vim.api.nvim_win_get_cursor(winid)[1]
	end

	function view.source_row()
		local row = view.row()
		if not row then
			return nil
		end
		if query == "" then
			return row
		end
		return display_rows[row]
	end

	function view.filter(next_query)
		query = next_query or ""
		render()
		if valid_win(winid) then
			pcall(vim.api.nvim_win_set_config, winid, M.window_config(rendered, config_opts))
			local target = math.max(1, math.min(opts.initial_line or 3, #rendered))
			if query ~= "" then
				target = 1
				for row = 1, #rendered do
					if display_rows[row] then
						target = row
						break
					end
				end
			end
			pcall(vim.api.nvim_win_set_cursor, winid, { target, 0 })
		end
	end

	if opts.on_submit then
		vim.keymap.set("n", opts.submit_key or "<CR>", function()
			opts.on_submit(view.source_row(), view)
		end, { buffer = bufnr, nowait = true, desc = opts.submit_desc or "Select ACP item" })
	end

	vim.keymap.set("n", "/", function()
		local next_query = vim.fn.input("ACP filter: ", query)
		view.filter(next_query)
	end, { buffer = bufnr, nowait = true, desc = "Filter ACP picker" })

	vim.keymap.set("n", "<C-l>", function()
		view.filter("")
	end, { buffer = bufnr, nowait = true, desc = "Clear ACP picker filter" })

	for _, key in ipairs(opts.close_keys or { "q", "<Esc>" }) do
		vim.keymap.set("n", key, function()
			view.close()
			if opts.on_cancel then
				opts.on_cancel(view)
			end
		end, { buffer = bufnr, nowait = true, desc = opts.close_desc or "Close ACP picker" })
	end

	return view
end

return M
