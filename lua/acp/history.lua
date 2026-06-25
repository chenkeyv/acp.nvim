local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")
local picker = require("acp.picker")

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

local function transcript_lines(lines)
	local start = 1
	for index, line in ipairs(lines) do
		if line == "" then
			start = index + 1
			break
		end
	end

	local transcript = {}
	for index = start, #lines do
		table.insert(transcript, lines[index])
	end
	return transcript
end

local function transcript_metrics(lines)
	local metrics = {
		lines = 0,
		sections = 0,
		code_blocks = 0,
		locations = 0,
	}
	local in_code = false

	for _, line in ipairs(transcript_lines(lines)) do
		if line ~= "" then
			metrics.lines = metrics.lines + 1
		end
		if
			line == "You"
			or line == "Agent"
			or line:match("^ACP:")
			or line:match("^Status:")
			or line:match("^Tool")
			or line:match("^Terminal:")
			or line:match("^Terminal output truncated")
			or line:match("^Wrote ")
			or line:match("^Thought:")
			or line:match("^stderr:")
		then
			metrics.sections = metrics.sections + 1
		end
		if line:match("^%s*```") then
			if not in_code then
				metrics.code_blocks = metrics.code_blocks + 1
				in_code = true
			else
				in_code = false
			end
		end
		for _ in line:gmatch("[^%s%[%]%(%){}<>,;]+:%d+:?%d*") do
			metrics.locations = metrics.locations + 1
		end
	end

	return metrics
end

local function metrics_label(metrics)
	metrics = metrics or {}
	local lines = metrics.lines or 0
	local sections = metrics.sections or 0
	local locations = metrics.locations or 0
	return ("%d line%s  %d section%s  %d code  %d loc%s"):format(
		lines,
		lines == 1 and "" or "s",
		sections,
		sections == 1 and "" or "s",
		metrics.code_blocks or 0,
		locations,
		locations == 1 and "" or "s"
	)
end

local function bounded_lines(lines, opts)
	local max_lines = opts.max_lines or 240
	local max_chars = opts.max_chars or 24000
	local out = {}
	local chars = 0
	local truncated = false

	for _, line in ipairs(lines) do
		if #out >= max_lines or chars + #line > max_chars then
			truncated = true
			break
		end
		table.insert(out, line)
		chars = chars + #line + 1
	end

	if truncated then
		table.insert(out, "... transcript truncated ...")
	end
	return out
end

local function entry_for(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil
	end

	local stat = vim.uv.fs_stat(path)
	local metrics = transcript_metrics(lines)
	return {
		path = path,
		name = vim.fs.basename(path),
		title = header_value(lines, "Title") or vim.fs.basename(path),
		adapter = header_value(lines, "Adapter") or "?",
		model = header_value(lines, "Model") or "?",
		updated = header_value(lines, "Updated") or "?",
		metrics = metrics,
		summary = metrics_label(metrics),
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

function M.replay_prompt(entry, opts)
	opts = opts or {}
	if not entry or not entry.path then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, entry.path)
	if not ok then
		return nil
	end

	local prompt = {
		"Use this saved ACP transcript as context for the next request.",
		"",
		("Transcript: %s"):format(entry.title or header_value(lines, "Title") or vim.fs.basename(entry.path)),
		("Adapter: %s"):format(entry.adapter or header_value(lines, "Adapter") or "?"),
		("Updated: %s"):format(entry.updated or header_value(lines, "Updated") or "?"),
		"",
	}
	vim.list_extend(prompt, bounded_lines(transcript_lines(lines), opts))
	return table.concat(prompt, "\n")
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

local function browser_lines(entries, opts)
	local lines = { chrome.title(icons.history, "ACP History"), "" }
	local line_entries = {}
	for index, entry in ipairs(entries) do
		table.insert(lines, chrome.row(index, icons.history, entry.title))
		line_entries[#lines] = entry
		table.insert(
			lines,
			chrome.detail(icons.model, ("%s  %s  %s"):format(entry.updated, entry.adapter, entry.model))
		)
		line_entries[#lines] = entry
		table.insert(lines, chrome.detail(icons.map, entry.summary or metrics_label(entry.metrics)))
		line_entries[#lines] = entry
	end
	table.insert(lines, "")
	if opts.open_chat then
		table.insert(
			lines,
			chrome.footer("Press <Enter> to draft a chat, o to open read-only, / to filter, or q/<Esc> to close.")
		)
	else
		table.insert(lines, chrome.footer("Press <Enter> to open, / to filter, or q/<Esc> to close."))
	end
	return lines, line_entries
end

local function entry_preview(entry)
	if not entry or not entry.path then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, entry.path, "", 80)
	if not ok then
		return nil
	end
	if #lines == 0 then
		lines = { "" }
	end

	return {
		lines = lines,
		filetype = "acp",
		title = (" %s "):format(entry.title or entry.name or "ACP history"),
	}
end

function M.open_browser(opts)
	opts = opts or {}
	local entries = M.entries()
	if #entries == 0 then
		vim.notify("No ACP history found", vim.log.levels.INFO, { title = "ACP" })
		return false
	end

	local lines, line_entries = browser_lines(entries, opts)
	local view
	view = picker.open({
		name = "ACP://history",
		filetype = "acp-history",
		lines = lines,
		title = " ACP history ",
		submit_desc = opts.open_chat and "Draft ACP chat from history" or "Open ACP history entry",
		close_desc = "Close ACP history",
		preview = function(row)
			return entry_preview(line_entries[row])
		end,
		on_submit = function(row, picker_view)
			local entry = line_entries[row]
			if not entry then
				return
			end
			picker_view.close()
			if opts.open_chat then
				opts.open_chat(entry)
			else
				M.open_entry(entry)
			end
		end,
	})

	if opts.open_chat then
		vim.keymap.set("n", "o", function()
			local entry = line_entries[view.source_row()]
			if not entry then
				return
			end
			view.close()
			M.open_entry(entry)
		end, { buffer = view.bufnr, nowait = true, desc = "Open ACP history entry" })
	end

	return true
end

return M
