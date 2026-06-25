local M = {}
local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")

local function cwd_for(state)
	if state and state.connection and state.connection.cwd then
		return vim.fs.normalize(state.connection.cwd)
	end
	return vim.fs.normalize(vim.fn.getcwd())
end

local function relative_path(path, cwd)
	local normalized = vim.fs.normalize(path)
	local root = cwd:gsub("/$", "")
	if normalized == root then
		return "."
	end
	if normalized:sub(1, #root + 1) == root .. "/" then
		return normalized:sub(#root + 2)
	end
	return vim.fn.fnamemodify(normalized, ":.")
end

local function filetype_for(path)
	if vim.filetype and vim.filetype.match then
		local ok, filetype = pcall(vim.filetype.match, { filename = path })
		if ok and filetype and filetype ~= "" then
			return filetype
		end
	end
	return "text"
end

local function ensure_state(state)
	state.written_files = state.written_files or {}
	state.written_file_index = state.written_file_index or {}
end

function M.record(state, path)
	if not state or not path or path == "" then
		return nil
	end

	ensure_state(state)
	local normalized = vim.fs.normalize(path)
	local existing = state.written_file_index[normalized]
	if existing then
		existing.count = existing.count + 1
		return existing
	end

	local entry = {
		path = normalized,
		display = relative_path(normalized, cwd_for(state)),
		count = 1,
	}
	state.written_file_index[normalized] = entry
	table.insert(state.written_files, entry)
	return entry
end

function M.count(state)
	return #(state and state.written_files or {})
end

function M.items(state)
	local items = {}
	for _, entry in ipairs((state and state.written_files) or {}) do
		local suffix = entry.count > 1 and (" (%d writes)"):format(entry.count) or ""
		table.insert(items, {
			filename = entry.path,
			lnum = 1,
			col = 1,
			text = ("ACP wrote %s%s"):format(entry.display, suffix),
		})
	end
	return items
end

function M.picker_lines(state)
	local lines = { chrome.title(icons.changes, "ACP Changed Files"), "" }
	local line_entries = {}

	for index, entry in ipairs((state and state.written_files) or {}) do
		local suffix = entry.count > 1 and ("  %d writes"):format(entry.count) or ""
		table.insert(lines, chrome.row(index, icons.file, ("%s%s"):format(entry.display, suffix)))
		line_entries[#lines] = entry
		table.insert(lines, chrome.detail(icons.location, entry.path))
		line_entries[#lines] = entry
	end

	table.insert(lines, "")
	table.insert(lines, chrome.footer("Press <Enter> to open, Q for quickfix, / to filter, or q/<Esc> to close."))
	return lines, line_entries
end

function M.preview(entry)
	if not entry then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, entry.path, "", 200)
	if not ok then
		lines = {
			"Unable to read changed file.",
			tostring(lines),
		}
	elseif #lines == 0 then
		lines = { "" }
	elseif #lines == 200 then
		table.insert(lines, "")
		table.insert(lines, "... preview truncated")
	end

	return {
		lines = lines,
		filetype = filetype_for(entry.path),
		title = (" ACP change %s "):format(entry.display or entry.path),
	}
end

function M.open_quickfix(state)
	local items = M.items(state)
	if #items == 0 then
		return false
	end

	vim.fn.setqflist({}, " ", {
		title = ("ACP changes #%s"):format(state.id or "?"),
		items = items,
	})
	vim.cmd("copen")
	return true
end

return M
