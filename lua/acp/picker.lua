local M = {}
local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")

local picker_ns = vim.api.nvim_create_namespace("acp.nvim.picker")

function M.define_highlights()
	vim.api.nvim_set_hl(0, "AcpPickerHeader", { fg = "#7aa2f7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPickerIcon", { fg = "#7dcfff", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPickerIndex", { fg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPickerDetail", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpPickerFooter", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpPickerKey", { fg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPickerFilter", { fg = "#bb9af7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPickerEmpty", { link = "DiagnosticWarn", default = true })
end

local function add_hl(bufnr, row, start_col, end_col, group, priority)
	if end_col <= start_col then
		return
	end
	pcall(vim.api.nvim_buf_set_extmark, bufnr, picker_ns, row, start_col, {
		end_col = end_col,
		hl_group = group,
		priority = priority or 80,
	})
end

local function add_line_hl(bufnr, row, group)
	pcall(vim.api.nvim_buf_set_extmark, bufnr, picker_ns, row, 0, {
		line_hl_group = group,
		priority = 70,
	})
end

local function highlight_first_token(bufnr, row, line, group)
	local start_col, end_col = line:find("%S+")
	if start_col then
		add_hl(bufnr, row, start_col - 1, end_col, group)
	end
end

local function highlight_key_tokens(bufnr, row, line)
	local start_col = 1
	while true do
		local first, last = line:find("<[^>]+>", start_col)
		if not first then
			break
		end
		add_hl(bufnr, row, first - 1, last, "AcpPickerKey", 90)
		start_col = last + 1
	end

	local key_start = 1
	while true do
		local first, last = line:find("%f[%w][QKoqx/]%f[%W]", key_start)
		if not first then
			break
		end
		add_hl(bufnr, row, first - 1, last, "AcpPickerKey", 90)
		key_start = last + 1
	end
end

local function apply_highlights(bufnr, lines)
	vim.api.nvim_buf_clear_namespace(bufnr, picker_ns, 0, -1)
	for index, line in ipairs(lines or {}) do
		local row = index - 1
		if line:find(icons.search, 1, true) == 1 and line:find("filter", 1, true) then
			add_line_hl(bufnr, row, "AcpPickerFilter")
			local first, last = line:find(icons.search, 1, true)
			if first then
				add_hl(bufnr, row, first - 1, last, "AcpPickerIcon", 90)
			end
		elseif line:find("No matching picker entries", 1, true) then
			add_line_hl(bufnr, row, "AcpPickerEmpty")
			highlight_first_token(bufnr, row, line, "AcpPickerIcon")
		elseif line:match("^Press ") then
			add_line_hl(bufnr, row, "AcpPickerFooter")
			highlight_key_tokens(bufnr, row, line)
			local first, last = line:find(icons.key, 1, true)
			if first then
				add_hl(bufnr, row, first - 1, last, "AcpPickerKey", 90)
			end
		elseif index == 1 and line ~= "" then
			add_line_hl(bufnr, row, "AcpPickerHeader")
			highlight_first_token(bufnr, row, line, "AcpPickerIcon")
		else
			local _, prefix_end, prefix, token = line:find("^(%s*%d+%.%s+)(%S+)")
			if prefix_end then
				add_hl(bufnr, row, 0, #prefix, "AcpPickerIndex", 90)
				add_hl(bufnr, row, #prefix, #prefix + #token, "AcpPickerIcon", 90)
			elseif line:match("^%s+%S+") then
				add_line_hl(bufnr, row, "AcpPickerDetail")
				highlight_first_token(bufnr, row, line, "AcpPickerIcon")
			end
		end
	end
end

local function decorated_title(title, icon)
	local stripped = tostring(title or "ACP"):gsub("^%s+", ""):gsub("%s+$", "")
	if stripped == "" then
		stripped = "ACP"
	end
	local title_icon = icon or icons.acp
	if stripped:find(title_icon, 1, true) then
		return title
	end
	return (" %s %s "):format(title_icon, stripped)
end

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

local function normalize_preview(value)
	if type(value) == "string" then
		return {
			lines = vim.split(value, "\n", { plain = true }),
		}
	end
	if type(value) ~= "table" then
		return nil
	end
	if value.lines then
		return {
			lines = value.lines,
			filetype = value.filetype,
			title = value.title,
			cursor_line = value.cursor_line,
		}
	end
	return {
		lines = value,
	}
end

local function preview_syntax(bufnr, filetype)
	filetype = filetype or "text"
	if vim.b[bufnr].acp_picker_preview_filetype ~= filetype and vim.treesitter and vim.treesitter.stop then
		pcall(vim.treesitter.stop, bufnr)
	end
	vim.b[bufnr].acp_picker_preview_filetype = filetype

	if not (vim.treesitter and vim.treesitter.start) or filetype == "text" or filetype == "acp" then
		vim.b[bufnr].acp_picker_preview_syntax = "filetype"
		return "filetype"
	end

	local ok = pcall(vim.treesitter.start, bufnr, filetype)
	local syntax = ok and "treesitter" or "filetype"
	vim.b[bufnr].acp_picker_preview_syntax = syntax
	return syntax
end

local function clean_preview_title(value, fallback)
	local title = tostring(value or fallback or "ACP preview"):gsub("^%s+", ""):gsub("%s+$", "")
	if title == "" then
		return fallback or "ACP preview"
	end
	return title
end

local function preview_winbar(preview, syntax)
	local filetype = preview and preview.filetype or "text"
	local syntax_label = syntax == "treesitter" and "Tree-sitter" or "filetype"
	local syntax_icon = syntax == "treesitter" and icons.treesitter or icons.file
	return (" %s %s  %s %s  %s %s  %s q close "):format(
		icons.note,
		clean_preview_title(preview and preview.title, "ACP preview"),
		icons.code,
		filetype or "text",
		syntax_icon,
		syntax_label,
		icons.key
	)
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
		title = decorated_title(opts.title or " ACP ", opts.title_icon or icons.acp),
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
	M.define_highlights()
	local lines = opts.lines or { "" }
	local source_lines = vim.deepcopy(lines)
	local query = ""
	local display_rows = {}
	local preview_bufnr
	local preview_winid
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

		local matched = {}
		local match_count = 0
		local total_count = 0
		for index, line in ipairs(source_lines) do
			if line ~= "" then
				total_count = total_count + 1
			end
			if matches_query(line, query) then
				table.insert(matched, { line = line, row = index })
				if line ~= "" then
					match_count = match_count + 1
				end
			end
		end

		if query ~= "" then
			local noun = match_count == 1 and "result" or "results"
			table.insert(
				visible,
				("%s filter %s  %s %d/%d %s"):format(icons.search, query, icons.map, match_count, total_count, noun)
			)
			rows[#visible] = nil
			table.insert(visible, "")
			rows[#visible] = nil
		end

		for _, item in ipairs(matched) do
			table.insert(visible, item.line)
			rows[#visible] = item.row
		end

		if query ~= "" then
			if match_count == 0 then
				table.insert(visible, ("%s No matching picker entries for %s."):format(icons.search, query))
				rows[#visible] = nil
			end
			table.insert(visible, "")
			rows[#visible] = nil
			table.insert(visible, chrome.footer("Press <Enter> to select, <C-l> to clear, or q/<Esc> to close."))
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
		apply_highlights(bufnr, rendered)
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
		if valid_win(preview_winid) then
			pcall(vim.api.nvim_win_close, preview_winid, true)
		end
		if valid_buf(preview_bufnr) then
			pcall(vim.api.nvim_buf_delete, preview_bufnr, { force = true })
		end
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

	local function preview_window_config(preview)
		local picker_config = vim.api.nvim_win_get_config(winid)
		local picker_width = picker_config.width or 1
		local picker_height = picker_config.height or 1
		local picker_row = tonumber(picker_config.row) or 1
		local picker_col = tonumber(picker_config.col) or 0
		local width = 0
		for _, line in ipairs(preview.lines or {}) do
			width = math.max(width, #line)
		end
		width = math.min(math.max(40, width + 4), math.max(20, vim.o.columns - 4))
		local height = math.min(math.max(8, #(preview.lines or {})), math.max(1, vim.o.lines - 6))
		local right_col = picker_col + picker_width + 2
		local col = right_col + width + 1 < vim.o.columns and right_col or math.max(0, picker_col - width - 2)

		return {
			relative = "editor",
			row = picker_row,
			col = col,
			width = width,
			height = math.min(height, picker_height),
			style = "minimal",
			border = "rounded",
			title = decorated_title(preview.title or " ACP preview ", preview.title_icon or icons.note),
			title_pos = "left",
			zindex = (config_opts.zindex or 65) + 1,
		}
	end

	function view.update_preview()
		if not opts.preview then
			return
		end

		local preview = normalize_preview(opts.preview(view.source_row(), view))
		if not preview or not preview.lines or #preview.lines == 0 then
			if valid_win(preview_winid) then
				pcall(vim.api.nvim_win_close, preview_winid, true)
			end
			preview_winid = nil
			return
		end

		if not valid_buf(preview_bufnr) then
			preview_bufnr = vim.api.nvim_create_buf(false, true)
			view.preview_bufnr = preview_bufnr
			set_buf_options(preview_bufnr, {
				bufhidden = "wipe",
				buftype = "nofile",
				filetype = preview.filetype or "text",
				modifiable = true,
				swapfile = false,
			})
		end

		vim.bo[preview_bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(preview_bufnr, 0, -1, false, preview.lines)
		vim.bo[preview_bufnr].filetype = preview.filetype or "text"
		vim.bo[preview_bufnr].modifiable = false
		local syntax = preview_syntax(preview_bufnr, preview.filetype or "text")

		local preview_config = preview_window_config(preview)
		if valid_win(preview_winid) then
			pcall(vim.api.nvim_win_set_config, preview_winid, preview_config)
		else
			preview_winid = vim.api.nvim_open_win(preview_bufnr, false, preview_config)
			view.preview_winid = preview_winid
			vim.wo[preview_winid].cursorline = true
			vim.wo[preview_winid].number = true
			vim.wo[preview_winid].relativenumber = false
			vim.wo[preview_winid].wrap = false
		end
		vim.wo[preview_winid].winbar = preview_winbar(preview, syntax):gsub("%%", "%%%%")
		pcall(vim.api.nvim_win_set_cursor, preview_winid, { math.max(1, preview.cursor_line or 1), 0 })
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
		view.update_preview()
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

	if opts.preview then
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			buffer = bufnr,
			callback = function()
				view.update_preview()
			end,
		})
		view.update_preview()
	end

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
