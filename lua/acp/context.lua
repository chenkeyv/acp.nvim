local M = {}

local function valid_buffer(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == ""
end

local function absolute_path(bufnr)
	if not valid_buffer(bufnr) then
		return nil
	end
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return nil
	end
	return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function display_path(path, cwd)
	if cwd and cwd ~= "" then
		local normalized = vim.fs.normalize(cwd):gsub("/$", "")
		if path == normalized then
			return "."
		end
		if path:sub(1, #normalized + 1) == normalized .. "/" then
			return path:sub(#normalized + 2)
		end
	end
	return vim.fn.fnamemodify(path, ":~")
end

function M.file(bufnr, cwd)
	local path = absolute_path(bufnr)
	if not path then
		return nil
	end
	return {
		kind = "file",
		path = path,
		name = vim.fs.basename(path),
		label = display_path(path, cwd),
		key = "file:" .. path,
	}
end

function M.cursor(bufnr, winid, cwd)
	local file = M.file(bufnr, cwd)
	if not file then
		return nil
	end
	local cursor = { 1, 0 }
	if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
		cursor = vim.api.nvim_win_get_cursor(winid)
	end
	return {
		kind = "cursor",
		path = file.path,
		label = ("%s:%d"):format(file.label, cursor[1]),
		key = ("cursor:%s:%d"):format(file.path, cursor[1]),
		value = ("Active editor: %s\nCursor: line %d, column %d"):format(file.path, cursor[1], cursor[2] + 1),
	}
end

function M.selection(bufnr, range, cwd, opts)
	opts = opts or {}
	local file = M.file(bufnr, cwd)
	if not file or type(range) ~= "table" then
		return nil
	end
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local line1 = math.max(1, math.min(line_count, tonumber(range.line1) or 1))
	local line2 = math.max(1, math.min(line_count, tonumber(range.line2) or line1))
	if line2 < line1 then
		line1, line2 = line2, line1
	end
	local max_lines = tonumber(opts.max_lines) or 200
	local stop = math.min(line2, line1 + max_lines - 1)
	local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, stop, false)
	local text = table.concat(lines, "\n")
	local max_chars = tonumber(opts.max_chars) or 16000
	local truncated = stop < line2 or #text > max_chars
	if #text > max_chars then
		text = text:sub(1, max_chars)
	end
	if truncated then
		text = text .. "\n... selection truncated ..."
	end

	return {
		kind = "selection",
		path = file.path,
		line1 = line1,
		line2 = line2,
		label = ("%s:%d-%d"):format(file.label, line1, line2),
		key = ("selection:%s:%d:%d"):format(file.path, line1, line2),
		value = ("Editor selection from %s (lines %d-%d):\n%s"):format(file.path, line1, line2, text),
	}
end

function M.add(contexts, item)
	if not item then
		return false
	end
	for index, current in ipairs(contexts) do
		if current.key == item.key then
			contexts[index] = item
			return false
		end
	end
	table.insert(contexts, item)
	return true
end

function M.turn_payload(contexts)
	local input = {}
	local additional = {}
	local labels = {}
	for index, item in ipairs(contexts or {}) do
		table.insert(labels, item.label)
		if item.kind == "file" then
			table.insert(input, { type = "mention", name = item.name, path = item.path })
		elseif item.value then
			additional[("nvim:%d"):format(index)] = {
				kind = "application",
				value = item.value,
			}
		end
	end
	return input, next(additional) and additional or nil, labels
end

return M
