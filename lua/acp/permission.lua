local M = {}
local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")

local permission_ns = vim.api.nvim_create_namespace("acp.nvim.permission")

local function clean(value)
	return tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function option_label(option)
	return clean(option.name or option.kind or option.optionId or "option")
end

local function append_field(lines, label, value, icon)
	if value == nil or value == "" or value == vim.NIL then
		return
	end
	local suffix = icon and (" " .. icon) or ""
	table.insert(lines, ("%s: %s%s"):format(label, clean(value), suffix))
end

local function append_details(lines, details)
	if type(details) ~= "table" then
		return false
	end

	local added = false
	for _, detail in ipairs(details) do
		if type(detail) == "table" and detail.value ~= nil and detail.value ~= "" and detail.value ~= vim.NIL then
			if not added then
				table.insert(lines, chrome.title(icons.inspect, "Details"))
				added = true
			end
			append_field(lines, detail.label or detail.name or "Detail", detail.value, detail.icon or icons.note)
		end
	end

	if added then
		table.insert(lines, "")
	end
	return added
end

function M.option_labels(options)
	local labels = {}
	for _, option in ipairs(options or {}) do
		table.insert(labels, option_label(option))
	end
	return labels
end

function M.define_highlights()
	vim.api.nvim_set_hl(0, "AcpPermissionHeader", { fg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPermissionField", { fg = "#7aa2f7", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPermissionOption", { fg = "#9ece6a", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPermissionKey", { fg = "#e0af68", bold = true, default = true })
	vim.api.nvim_set_hl(0, "AcpPermissionFooter", { link = "Comment", default = true })
end

local function add_line_hl(bufnr, row, group)
	pcall(vim.api.nvim_buf_set_extmark, bufnr, permission_ns, row, 0, {
		line_hl_group = group,
		priority = 75,
	})
end

local function add_hl(bufnr, row, start_col, end_col, group)
	if end_col <= start_col then
		return
	end
	pcall(vim.api.nvim_buf_set_extmark, bufnr, permission_ns, row, start_col, {
		end_col = end_col,
		hl_group = group,
		priority = 90,
	})
end

local function apply_highlights(bufnr, lines)
	vim.api.nvim_buf_clear_namespace(bufnr, permission_ns, 0, -1)
	for index, line in ipairs(lines or {}) do
		local row = index - 1
		if
			line:find("Permission request", 1, true)
			or line:find("Details", 1, true)
			or line:find("Options", 1, true)
		then
			add_line_hl(bufnr, row, "AcpPermissionHeader")
			add_hl(bufnr, row, 0, #line, "AcpPermissionHeader")
		elseif line:match("^%s*%d+%.%s+") or line:match("^%s*%-%.%s+") then
			add_line_hl(bufnr, row, "AcpPermissionOption")
			local first, last = line:find("%S+")
			if first then
				add_hl(bufnr, row, first - 1, last, "AcpPermissionKey")
			end
		elseif line:match("^%s*Press ") then
			add_line_hl(bufnr, row, "AcpPermissionFooter")
			local start_col = 1
			while true do
				local first, last = line:find("<[^>]+>", start_col)
				if not first then
					break
				end
				add_hl(bufnr, row, first - 1, last, "AcpPermissionKey")
				start_col = last + 1
			end
		else
			local first, last = line:find("^%s*[%w ]+:")
			if first then
				add_hl(bufnr, row, first - 1, last, "AcpPermissionField")
			end
		end
	end
end

function M.lines(params)
	params = params or {}
	local options = params.options or {}
	local tool = params.toolCall or {}
	local lines = {
		chrome.title(icons.warning, "Permission request"),
		"",
	}

	append_field(lines, "Tool", tool.title or tool.name, icons.tool)
	append_field(lines, "Kind", tool.kind, icons.type)
	append_field(lines, "Status", tool.status, icons.status)
	append_field(lines, "Description", tool.description, icons.note)
	append_field(lines, "Location", tool.location or tool.path, icons.location)
	append_field(lines, "Request", params.title or params.description or params.prompt, icons.prompt)

	if #lines > 2 then
		table.insert(lines, "")
	end

	append_details(lines, params.details)

	table.insert(lines, chrome.title(icons.action, "Options"))
	for index, option in ipairs(options) do
		local key = index <= 9 and tostring(index) or "-"
		table.insert(lines, ("  %s. %s %s"):format(key, option_label(option), icons.action))
		append_field(lines, "     Outcome", option.optionId, icons.status)
		append_field(lines, "     Kind", option.kind, icons.type)
		append_field(lines, "     Description", option.description, icons.note)
	end

	table.insert(lines, "")
	table.insert(lines, chrome.footer("Press 1-9 to choose, <CR> for the first option, or q/<Esc> to cancel."))
	return lines
end

local function permission_winbar(options)
	local count = #(options or {})
	local noun = count == 1 and "option" or "options"
	return (" %s ACP permission  %s %d %s  %s 1-9 choose  %s <CR> default  %s q cancel ")
		:format(icons.warning, icons.action, count, noun, icons.key, icons.key, icons.key)
		:gsub("%%", "%%%%")
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
		title = (" %s ACP permission "):format(icons.warning),
		title_pos = "left",
		zindex = 70,
	}
end

function M.select(params, callback)
	params = params or {}
	local options = params.options or {}
	local lines = M.lines(params)
	M.define_highlights()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, "ACP://permission")
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].filetype = "acp-permission"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	apply_highlights(bufnr, lines)

	local winid = vim.api.nvim_open_win(bufnr, true, window_config(lines))
	vim.wo[winid].wrap = true
	vim.wo[winid].linebreak = true
	vim.wo[winid].cursorline = true
	vim.wo[winid].winbar = permission_winbar(options)

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
