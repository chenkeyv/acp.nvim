local Connection = require("acp.connection").Connection
local actions = require("acp.actions")
local changes = require("acp.changes")
local code_actions = require("acp.code_actions")
local acp_commands = require("acp.commands")
local acp_config = require("acp.config")
local context = require("acp.context")
local diagnostics = require("acp.diagnostics")
local health = require("acp.health")
local hover = require("acp.hover")
local history = require("acp.history")
local metadata = require("acp.metadata")
local output = require("acp.output")
local picker = require("acp.picker")
local prompt_view = require("acp.prompt_view")
local references = require("acp.references")
local session_view = require("acp.session_view")
local source_view = require("acp.source_view")
local symbols = require("acp.symbols")
local treesitter = require("acp.treesitter")

local M = {}
local uv = vim.uv or vim.loop

local defaults = {
	default_adapter = "codex",
	default_mode = "tab",
	layout = {
		width_ratio = 0.88,
		height_ratio = 0.86,
		input_height = 7,
		session_panel_width = 28,
	},
	adapters = {
		codex = {
			command = { "codex-acp" },
			codex_command = { "codex" },
			auth_method = "chatgpt",
			metadata = "codex",
			timeout_ms = 60000,
			model = nil,
			context_window = nil,
		},
		claude_code = {
			command = { "claude-agent-acp" },
			timeout_ms = 60000,
			model = nil,
			context_window = nil,
		},
	},
}

local config = vim.deepcopy(defaults)
local states = {}
local sessions = {}
local next_session_id = 1
local session_panel_lines = {}
local output_ns = vim.api.nvim_create_namespace("acp.nvim.output")
local prompt_ns = vim.api.nvim_create_namespace("acp.nvim.prompt")
local session_panel_ns = vim.api.nvim_create_namespace("acp.nvim.sessions")
local source_ns = vim.api.nvim_create_namespace("acp.nvim.source")

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "ACP" })
end

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function define_highlights()
	output.define_highlights()
	prompt_view.define_highlights()
	session_view.define_highlights()
	source_view.define_highlights()
end

local function refresh_output_highlights(state)
	if not valid_buf(state.output_buf) then
		return
	end

	vim.api.nvim_buf_clear_namespace(state.output_buf, output_ns, 0, -1)
	local lines = vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false)
	for index, line in ipairs(lines) do
		local style = output.line_style(line)
		if style then
			local opts = {
				priority = 80,
			}
			if style.line_hl_group then
				opts.line_hl_group = style.line_hl_group
			end
			if style.badge then
				opts.virt_text = { { style.badge, style.badge_hl or "AcpBadge" } }
				opts.virt_text_pos = "right_align"
			end
			pcall(vim.api.nvim_buf_set_extmark, state.output_buf, output_ns, index - 1, 0, opts)
		end
	end

	for _, block in ipairs(output.code_blocks(lines)) do
		for _, line_number in ipairs({ block.start_line, block.end_line }) do
			local line = lines[line_number]
			if line then
				local opts = {
					end_col = #line,
					hl_group = "AcpCodeFence",
					priority = 70,
				}
				if line_number == block.start_line then
					local prefix = state.output_language_injection and " inject:" or " lang:"
					opts.virt_text = { { ("%s%s "):format(prefix, block.language), "AcpInjectedLanguage" } }
					opts.virt_text_pos = "right_align"
				end
				pcall(vim.api.nvim_buf_set_extmark, state.output_buf, output_ns, line_number - 1, 0, opts)
			end
		end
	end

	local ghost = output.ghost_text(state, lines, state.output_animation_frame)
	if ghost and #lines > 0 then
		local row = #lines - 1
		local col = #(lines[#lines] or "")
		pcall(vim.api.nvim_buf_set_extmark, state.output_buf, output_ns, row, col, {
			virt_text = { { ghost, "AcpGhostText" } },
			virt_text_pos = "eol",
			hl_mode = "combine",
			priority = 90,
		})
	end
end

local function save_output_history(state)
	if not valid_buf(state.output_buf) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false)
	local ok, err = pcall(history.save, state, lines)
	if not ok and not state.history_error_reported then
		state.history_error_reported = true
		notify(("Failed to save ACP history: %s"):format(err), vim.log.levels.WARN)
	end
end

local function set_buf_options(bufnr, opts)
	for key, value in pairs(opts) do
		vim.bo[bufnr][key] = value
	end
end

local function enable_output_language_injection(state)
	if state.output_language_injection_tried or not valid_buf(state.output_buf) then
		return
	end

	state.output_language_injection_tried = true
	state.output_language_injection = false
	if not (vim.treesitter and vim.treesitter.start) then
		vim.b[state.output_buf].acp_language_injection = "fence-detection"
		return
	end

	local ok = pcall(vim.treesitter.start, state.output_buf, "markdown")
	state.output_language_injection = ok
	vim.b[state.output_buf].acp_language_injection = ok and "treesitter-markdown" or "fence-detection"
end

local refresh_output_dashboard

local function set_output_lines(state, start, stop, lines)
	if not valid_buf(state.output_buf) then
		return
	end

	vim.bo[state.output_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.output_buf, start, stop, false, lines)
	vim.bo[state.output_buf].modifiable = false
	refresh_output_highlights(state)
	save_output_history(state)
	if refresh_output_dashboard and not state.refreshing_output_dashboard and start ~= 0 then
		refresh_output_dashboard(state)
	end
end

local function set_panel_lines(bufnr, lines)
	if not valid_buf(bufnr) then
		return
	end

	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
end

local function refresh_session_panel_highlights(bufnr, styles)
	if not valid_buf(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, session_panel_ns, 0, -1)
	for line_number, style in pairs(styles or {}) do
		local opts = {
			priority = 80,
		}
		if style.line_hl_group then
			opts.line_hl_group = style.line_hl_group
		end
		if style.virt_text then
			opts.virt_text = style.virt_text
			opts.virt_text_pos = "right_align"
		end
		pcall(vim.api.nvim_buf_set_extmark, bufnr, session_panel_ns, line_number - 1, 0, opts)
	end
end

local function clear_source_marks(state)
	if not (state and state.source and valid_buf(state.source.bufnr)) then
		return
	end

	for _, mark_id in ipairs(state.source_mark_ids or {}) do
		pcall(vim.api.nvim_buf_del_extmark, state.source.bufnr, source_ns, mark_id)
	end
	state.source_mark_ids = {}
end

local function refresh_source_marks(state)
	clear_source_marks(state)
	if not state or not state.source or not valid_buf(state.source.bufnr) then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(state.source.bufnr)
	state.source_mark_ids = {}
	for _, mark in ipairs(source_view.marks(state)) do
		local line = math.max(1, math.min(mark.line or 1, line_count))
		local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, state.source.bufnr, source_ns, line - 1, 0, mark.opts or {})
		if ok then
			table.insert(state.source_mark_ids, mark_id)
		end
	end
end

function refresh_output_dashboard(state)
	if not valid_buf(state.output_buf) then
		return
	end

	local old_count = state.output_dashboard_lines or #output.dashboard_lines(state)
	local current_lines = vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false)
	local stats = output.transcript_stats(current_lines, {
		start_line = old_count + 1,
		cwd = state.cwd,
		change_count = changes.count(state),
	})
	local lines = output.dashboard_lines(state, { stats = stats })
	state.output_dashboard_lines = #lines
	state.refreshing_output_dashboard = true
	set_output_lines(state, 0, old_count, lines)
	state.refreshing_output_dashboard = false
end

local function refresh_output_chrome(state)
	if not valid_win(state.output_win) then
		return
	end

	local current_section
	if valid_buf(state.output_buf) and vim.api.nvim_win_get_buf(state.output_win) == state.output_buf then
		local cursor = vim.api.nvim_win_get_cursor(state.output_win)
		local lines = vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false)
		current_section = output.current_section(lines, cursor[1])
	end
	local title = output.window_title(state, {
		change_count = changes.count(state),
		current_section = current_section,
	})
	local win_config = vim.api.nvim_win_get_config(state.output_win)
	if win_config.relative ~= "" then
		win_config.title = title
		pcall(vim.api.nvim_win_set_config, state.output_win, win_config)
	else
		vim.wo[state.output_win].winbar = output.winbar(state, {
			change_count = changes.count(state),
			current_section = current_section,
		})
	end
end

local function stop_output_animation(state)
	local timer = state and state.output_animation_timer
	if not timer then
		return
	end

	state.output_animation_timer = nil
	state.output_animation_frame = 1
	local ok, closing = pcall(function()
		return timer:is_closing()
	end)
	if ok and closing then
		return
	end
	pcall(function()
		timer:stop()
	end)
	pcall(function()
		timer:close()
	end)
end

local function start_output_animation(state)
	if state.output_animation_timer or not (uv and uv.new_timer) then
		return
	end

	local timer = uv.new_timer()
	if not timer then
		return
	end

	state.output_animation_timer = timer
	state.output_animation_frame = state.output_animation_frame or 1
	timer:start(0, 160, vim.schedule_wrap(function()
		if state.closed or not state.busy or not valid_buf(state.output_buf) then
			stop_output_animation(state)
			if valid_buf(state.output_buf) then
				refresh_output_highlights(state)
			end
			return
		end

		state.output_animation_frame = (state.output_animation_frame or 0) + 1
		refresh_output_highlights(state)
	end))
end

local function jump_output_section(state, direction)
	if not state or not valid_buf(state.output_buf) then
		return
	end

	local winid = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_buf(winid) ~= state.output_buf then
		winid = vim.fn.bufwinid(state.output_buf)
	end
	if not valid_win(winid) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false)
	local current = vim.api.nvim_win_get_cursor(winid)[1]
	local target = output.next_section(lines, current, direction)
	if target then
		vim.api.nvim_win_set_cursor(winid, { target, 0 })
		refresh_output_chrome(state)
	end
end

local function open_output_outline(state)
	if not state or not valid_buf(state.output_buf) then
		notify("No ACP output buffer is available", vim.log.levels.WARN)
		return false
	end

	local sections = output.sections(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false))
	if #sections == 0 then
		notify("No ACP output sections found", vim.log.levels.WARN)
		return false
	end

	local lines, line_sections = output.outline_lines(sections)
	picker.open({
		name = ("ACP://%s/%d/output-outline"):format(state.adapter, state.id),
		filetype = "acp-output",
		lines = lines,
		title = " ACP output outline ",
		submit_desc = "Jump to ACP output section",
		close_desc = "Close ACP output outline",
		on_submit = function(row, view)
			local section = line_sections[row]
			if not section then
				return
			end

			local winid = vim.fn.bufwinid(state.output_buf)
			if not valid_win(winid) then
				notify("ACP output window is not visible", vim.log.levels.WARN)
				return
			end

			view.close()
			vim.api.nvim_set_current_win(winid)
			pcall(vim.api.nvim_win_set_cursor, winid, { section.line, 0 })
		end,
	})
	return true
end

local function output_line_preview(lines, entry)
	if not entry or not entry.line then
		return nil
	end

	local line_count = #lines
	if line_count == 0 then
		return nil
	end
	local line = math.max(1, math.min(entry.line, line_count))
	local start_line = math.max(1, line - 5)
	local end_line = math.min(line_count, line + 5)
	local preview = {}
	for index = start_line, end_line do
		local marker = index == line and ">" or " "
		table.insert(preview, ("%s %4d  %s"):format(marker, index, lines[index] or ""))
	end

	return {
		lines = preview,
		filetype = "acp",
		title = (" ACP output line %d "):format(line),
		cursor_line = line - start_line + 1,
	}
end

local function open_output_search(state)
	if not state or not valid_buf(state.output_buf) then
		notify("No ACP output buffer is available", vim.log.levels.WARN)
		return false
	end

	local output_lines = vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false)
	local entries = output.transcript_entries(output_lines)
	if #entries == 0 then
		notify("No ACP output lines found", vim.log.levels.WARN)
		return false
	end

	local lines, line_entries = output.transcript_entry_lines(entries)
	picker.open({
		name = ("ACP://%s/%d/output-search"):format(state.adapter, state.id),
		filetype = "acp-output-search",
		lines = lines,
		title = " ACP output search ",
		submit_desc = "Jump to ACP output line",
		close_desc = "Close ACP output search",
		preview = function(row)
			return output_line_preview(output_lines, line_entries[row])
		end,
		on_submit = function(row, view)
			local entry = line_entries[row]
			if not entry then
				return
			end

			local winid = vim.fn.bufwinid(state.output_buf)
			if not valid_win(winid) then
				notify("ACP output window is not visible", vim.log.levels.WARN)
				return
			end

			view.close()
			vim.api.nvim_set_current_win(winid)
			pcall(vim.api.nvim_win_set_cursor, winid, { entry.line, 0 })
		end,
	})
	return true
end

local file_reference_preview
local jump_to_file_reference

local function code_block_title(block)
	return (" %s lines %d-%d "):format(block.language or "code", block.start_line or 1, block.end_line or 1)
end

local function open_output_code_block_buffer(state, block)
	if not state or not block or not block.lines then
		return false
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	pcall(
		vim.api.nvim_buf_set_name,
		bufnr,
		("ACP Code://%s/%s/%d-%d.%s"):format(
			state.adapter or "adapter",
			tostring(state.id or "?"),
			block.start_line or 1,
			block.end_line or 1,
			block.filetype or "text"
		)
	)
	set_buf_options(bufnr, {
		bufhidden = "wipe",
		buftype = "nofile",
		filetype = block.filetype or "text",
		modifiable = true,
		swapfile = false,
	})
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, block.lines)
	vim.b[bufnr].acp_output_source = state.output_buf

	vim.cmd("tabnew")
	vim.api.nvim_win_set_buf(0, bufnr)
	return true
end

local function open_output_code_blocks(state)
	if not state or not valid_buf(state.output_buf) then
		notify("No ACP output buffer is available", vim.log.levels.WARN)
		return false
	end

	local blocks = output.code_blocks(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false))
	if #blocks == 0 then
		notify("No ACP code blocks found in the output", vim.log.levels.WARN)
		return false
	end

	local lines, line_blocks = output.code_block_lines(blocks)
	picker.open({
		name = ("ACP://%s/%d/code-blocks"):format(state.adapter, state.id),
		filetype = "acp-code-blocks",
		lines = lines,
		title = " ACP code blocks ",
		submit_desc = "Open ACP code block",
		close_desc = "Close ACP code blocks",
		preview = function(row)
			local block = line_blocks[row]
			if not block then
				return nil
			end
			return {
				lines = block.lines,
				filetype = block.filetype,
				title = code_block_title(block),
			}
		end,
		on_submit = function(row, view)
			local block = line_blocks[row]
			if not block then
				return
			end

			view.close()
			open_output_code_block_buffer(state, block)
		end,
	})
	return true
end

local function open_output_locations(state)
	if not state or not valid_buf(state.output_buf) then
		notify("No ACP output buffer is available", vim.log.levels.WARN)
		return false
	end

	local references = output.file_references(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), {
		cwd = state.cwd,
	})
	if #references == 0 then
		notify("No local file references found in the ACP output", vim.log.levels.WARN)
		return false
	end

	local lines, line_references = output.file_reference_lines(references)
	picker.open({
		name = ("ACP://%s/%d/output-locations"):format(state.adapter, state.id),
		filetype = "acp-output-locations",
		lines = lines,
		title = " ACP output locations ",
		submit_desc = "Jump to ACP output location",
		close_desc = "Close ACP output locations",
		preview = function(row)
			return file_reference_preview(line_references[row])
		end,
		on_submit = function(row, view)
			local reference = line_references[row]
			if not reference then
				return
			end

			view.close()
			jump_to_file_reference(reference)
		end,
	})
	return true
end

local function follow_output(state)
	if not valid_win(state.output_win) or not valid_buf(state.output_buf) then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(state.output_buf)
	pcall(vim.api.nvim_win_set_cursor, state.output_win, { line_count, 0 })
end

local function append_lines(state, lines)
	set_output_lines(state, -1, -1, lines)
	follow_output(state)
end

local function append_text(state, text)
	if not valid_buf(state.output_buf) or not text or text == "" then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(state.output_buf)
	local last = vim.api.nvim_buf_get_lines(state.output_buf, line_count - 1, line_count, false)[1] or ""
	local parts = vim.split(text, "\n", { plain = true })

	if #parts == 1 then
		set_output_lines(state, line_count - 1, line_count, { last .. parts[1] })
		follow_output(state)
		return
	end

	local replacement = { last .. parts[1] }
	for index = 2, #parts do
		table.insert(replacement, parts[index])
	end

	set_output_lines(state, line_count - 1, line_count, replacement)
	follow_output(state)
end

local function ensure_terminal_block(state, terminal_id)
	state.rendered_terminals = state.rendered_terminals or {}
	if state.rendered_terminals[terminal_id] then
		return
	end

	state.rendered_terminals[terminal_id] = true
	append_lines(state, { "", ("Terminal: %s"):format(terminal_id), "" })
end

local function append_terminal_output(state, event)
	if not event or not event.terminal_id then
		return
	end

	ensure_terminal_block(state, event.terminal_id)
	if event.text and event.text ~= "" then
		append_text(state, event.text)
	end
	if event.truncated then
		state.truncated_terminals = state.truncated_terminals or {}
		if not state.truncated_terminals[event.terminal_id] then
			state.truncated_terminals[event.terminal_id] = true
			append_lines(state, { "", "Terminal output truncated to the configured byte limit.", "" })
		end
	end
end

local function sorted_sessions()
	local list = {}
	for _, state in pairs(sessions) do
		if not state.closed then
			table.insert(list, state)
		end
	end

	table.sort(list, function(left, right)
		return left.id < right.id
	end)
	return list
end

local function session_status(state)
	local status = state.run_status or (state.busy and "running" or "idle")
	local count = changes.count(state)
	if count > 0 then
		return ("%s  %d change(s)"):format(status, count)
	end
	return status
end

local function render_session_panel(state)
	if not valid_buf(state.session_panel_buf) then
		return
	end

	local lines, line_ids, styles = session_view.panel(sorted_sessions(), state.id, changes.count)
	session_panel_lines[state.session_panel_buf] = line_ids
	set_panel_lines(state.session_panel_buf, lines)
	refresh_session_panel_highlights(state.session_panel_buf, styles)
end

local function refresh_session_panels()
	for _, state in pairs(sessions) do
		render_session_panel(state)
	end
end

local refresh_prompt_hints

local function set_run_status(state, status)
	if not valid_buf(state.output_buf) then
		return
	end

	if state.run_status == status then
		return
	end

	local line = ("Status: %s"):format(status)
	local line_count = vim.api.nvim_buf_line_count(state.output_buf)
	if state.run_status_line and state.run_status_line < line_count then
		set_output_lines(state, state.run_status_line, state.run_status_line + 1, { line })
	else
		state.run_status_line = line_count
		set_output_lines(state, -1, -1, { line, "" })
	end

	state.run_status = status
	if state.busy then
		start_output_animation(state)
	else
		stop_output_animation(state)
	end
	refresh_output_highlights(state)
	refresh_output_chrome(state)
	refresh_prompt_hints(state)
	follow_output(state)
	refresh_session_panels()
end

local function trim(text)
	return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function format_count(value)
	local number = tonumber(value)
	if not number then
		return tostring(value)
	end

	if number >= 1000000 then
		local formatted = number / 1000000
		return formatted % 1 == 0 and ("%dM"):format(formatted) or ("%.1fM"):format(formatted)
	end
	if number >= 1000 then
		local formatted = number / 1000
		return formatted % 1 == 0 and ("%dk"):format(formatted) or ("%.1fk"):format(formatted)
	end
	return tostring(number)
end

local function prompt_title(state)
	local parts = { "Prompt" }
	local metadata = {}

	if state.model and state.model ~= "" then
		table.insert(metadata, state.model)
	end
	if state.context_window then
		table.insert(metadata, ("ctx %s"):format(format_count(state.context_window)))
	end
	if #metadata > 0 then
		table.insert(parts, table.concat(metadata, " "))
	end

	table.insert(parts, "<Enter> newline")
	table.insert(parts, "<C-Enter> send")
	table.insert(parts, "M-p/M-n history")
	table.insert(parts, "<leader>aq stop")
	return (" %s "):format(table.concat(parts, "  "))
end

local function refresh_prompt_chrome(state)
	if not valid_win(state.input_win) then
		return
	end

	local title = prompt_title(state)
	if state.mode == "window" then
		vim.wo[state.input_win].winbar = title
		return
	end

	local win_config = vim.api.nvim_win_get_config(state.input_win)
	if win_config.relative ~= "" then
		win_config.title = title
		pcall(vim.api.nvim_win_set_config, state.input_win, win_config)
	end
end

refresh_prompt_hints = function(state)
	if not valid_buf(state.input_buf) then
		return
	end

	vim.api.nvim_buf_clear_namespace(state.input_buf, prompt_ns, 0, -1)
	local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
	local info = prompt_view.info(lines, {
		busy = state.busy,
	})
	if info.empty then
		pcall(vim.api.nvim_buf_set_extmark, state.input_buf, prompt_ns, 0, 0, {
			virt_text = { { info.ghost, "AcpPromptGhost" } },
			virt_text_pos = "eol",
			hl_mode = "combine",
			priority = 80,
		})
		return
	end

	local row = math.max(0, #lines - 1)
	local last = lines[#lines] or ""
	pcall(vim.api.nvim_buf_set_extmark, state.input_buf, prompt_ns, row, #last, {
		virt_text = { { info.stats, "AcpPromptStats" } },
		virt_text_pos = "eol",
		hl_mode = "combine",
		priority = 80,
	})
end

local function input_prompt(state)
	if not valid_buf(state.input_buf) then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
	local prompt = trim(table.concat(lines, "\n"))
	if prompt == "" then
		return nil
	end
	return prompt
end

local function raw_input_text(state)
	if not valid_buf(state.input_buf) then
		return ""
	end

	return table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n")
end

local function set_input_text(state, text)
	if not valid_buf(state.input_buf) then
		return
	end

	local lines = text and text ~= "" and vim.split(text, "\n", { plain = true }) or { "" }
	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, lines)
	if valid_win(state.input_win) then
		local line_count = vim.api.nvim_buf_line_count(state.input_buf)
		local last = vim.api.nvim_buf_get_lines(state.input_buf, line_count - 1, line_count, false)[1] or ""
		pcall(vim.api.nvim_win_set_cursor, state.input_win, { line_count, #last })
	end
	refresh_prompt_hints(state)
end

local function clear_input(state)
	if not valid_buf(state.input_buf) then
		return
	end

	set_input_text(state, "")
end

local function append_input_text(state, text)
	if not valid_buf(state.input_buf) or not text or text == "" then
		return
	end

	local lines = vim.split(text, "\n", { plain = true })
	local existing = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
	local empty = #existing == 0 or (#existing == 1 and existing[1] == "")
	if empty then
		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, lines)
	else
		vim.api.nvim_buf_set_lines(state.input_buf, -1, -1, false, { "", "" })
		vim.api.nvim_buf_set_lines(state.input_buf, -1, -1, false, lines)
	end

	if valid_win(state.input_win) then
		local line_count = vim.api.nvim_buf_line_count(state.input_buf)
		local last = vim.api.nvim_buf_get_lines(state.input_buf, line_count - 1, line_count, false)[1] or ""
		pcall(vim.api.nvim_win_set_cursor, state.input_win, { line_count, #last })
	end
	refresh_prompt_hints(state)
end

local function record_prompt(state, prompt)
	if not prompt or prompt == "" then
		return
	end

	state.prompt_history = state.prompt_history or {}
	if state.prompt_history[#state.prompt_history] ~= prompt then
		table.insert(state.prompt_history, prompt)
	end
	state.prompt_history_cursor = #state.prompt_history + 1
	state.prompt_history_draft = nil
end

local function recall_prompt(state, delta)
	local history = state.prompt_history or {}
	if #history == 0 then
		notify("No ACP prompt history for this session", vim.log.levels.WARN)
		return
	end

	local cursor = state.prompt_history_cursor or (#history + 1)
	if cursor > #history then
		state.prompt_history_draft = raw_input_text(state)
	end

	cursor = math.max(1, math.min(#history + 1, cursor + delta))
	state.prompt_history_cursor = cursor
	if cursor == #history + 1 then
		set_input_text(state, state.prompt_history_draft or "")
	else
		set_input_text(state, history[cursor])
	end

	if valid_win(state.input_win) then
		vim.api.nvim_set_current_win(state.input_win)
	end
end

local function adapter_names()
	local names = vim.tbl_keys(config.adapters)
	table.sort(names)
	return names
end

local function command_source_range(command)
	if not command or not command.range or command.range == 0 then
		return nil
	end
	return {
		line1 = command.line1,
		line2 = command.line2,
	}
end

local function source_preview(bufnr, range, title)
	if not valid_buf(bufnr) then
		return nil
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if line_count == 0 then
		return nil
	end
	local line1 = range and range.line1 or 1
	local line2 = range and range.line2 or line1
	line1 = math.max(1, math.min(line1, line_count))
	line2 = math.max(1, math.min(line2, line_count))
	if line2 < line1 then
		line1, line2 = line2, line1
	end
	local start_line = math.max(1, line1 - 4)
	local end_line = math.min(line_count, line2 + 4)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	local name = vim.api.nvim_buf_get_name(bufnr)
	local path = name ~= "" and vim.fn.fnamemodify(name, ":.") or "[No Name]"

	return {
		lines = #lines > 0 and lines or { "" },
		filetype = vim.bo[bufnr].filetype ~= "" and vim.bo[bufnr].filetype or "text",
		title = title or (" %s:%d "):format(path, line1),
		cursor_line = line1 - start_line + 1,
	}
end

function file_reference_preview(reference)
	if not reference or not reference.path then
		return nil
	end

	local bufnr = vim.fn.bufadd(reference.path)
	if bufnr == 0 then
		return nil
	end
	pcall(function()
		vim.bo[bufnr].swapfile = false
	end)
	local loaded = pcall(vim.fn.bufload, bufnr)
	if vim.bo[bufnr].filetype == "" and vim.filetype and vim.filetype.match then
		local filetype = vim.filetype.match({ filename = reference.path })
		if filetype then
			vim.bo[bufnr].filetype = filetype
		end
	end
	if loaded then
		return source_preview(
			bufnr,
			{ line1 = reference.line or 1, line2 = reference.line or 1 },
			(" %s:%d "):format(reference.display_path or reference.path, reference.line or 1)
		)
	end

	local ok, lines = pcall(vim.fn.readfile, reference.path)
	if not ok or #lines == 0 then
		return nil
	end
	local line = math.max(1, math.min(reference.line or 1, #lines))
	local start_line = math.max(1, line - 4)
	local end_line = math.min(#lines, line + 4)
	local preview = {}
	for index = start_line, end_line do
		table.insert(preview, lines[index])
	end
	return {
		lines = preview,
		filetype = (vim.filetype and vim.filetype.match and vim.filetype.match({ filename = reference.path })) or "text",
		title = (" %s:%d "):format(reference.display_path or reference.path, reference.line or 1),
		cursor_line = line - start_line + 1,
	}
end

function jump_to_file_reference(reference)
	if not reference or not reference.path then
		return false
	end

	vim.cmd("noswapfile edit " .. vim.fn.fnameescape(reference.path))
	local line_count = vim.api.nvim_buf_line_count(0)
	local line = math.max(1, math.min(reference.line or 1, line_count))
	local column = math.max(0, (reference.column or 1) - 1)
	pcall(vim.api.nvim_win_set_cursor, 0, { line, column })
	return true
end

local function source_range(source)
	if source and source.range then
		return source.range
	end
	if source and source.cursor then
		return {
			line1 = source.cursor[1] or 1,
			line2 = source.cursor[1] or 1,
		}
	end
	return nil
end

local function diagnostics_prompt(source)
	if not source or not source.bufnr then
		return nil
	end

	local rendered_diagnostics = diagnostics.render(source.bufnr, {
		range = source.range,
	})
	if not rendered_diagnostics then
		return nil
	end

	local lines = {
		"Fix the diagnostics below. Keep the changes focused and preserve existing behavior.",
	}
	local rendered_context = context.render(source, {
		include_diagnostics = false,
	})
	if rendered_context then
		table.insert(lines, "")
		table.insert(lines, rendered_context)
	end
	table.insert(lines, "")
	table.insert(lines, rendered_diagnostics)
	return table.concat(lines, "\n")
end

local function diagnostic_item_prompt(source, item)
	if not source or not source.bufnr then
		return nil
	end

	local range = diagnostics.range(item)
	local diagnostic_source = context.capture(source.bufnr, source.winid, range)
	local rendered_diagnostics = diagnostics.render(source.bufnr, {
		range = range,
		limit = 8,
	})
	if not rendered_diagnostics then
		return nil
	end

	local rendered_context = context.render(diagnostic_source, {
		include_diagnostics = false,
	})
	if not rendered_context then
		return nil
	end

	return table.concat({
		"Fix this diagnostic. Keep the change focused and preserve existing behavior.",
		"",
		rendered_context,
		"",
		rendered_diagnostics,
	}, "\n")
end

local function context_prompt(source, instruction)
	if not source or not source.bufnr then
		return nil
	end

	local rendered_context = context.render(source)
	if not rendered_context then
		return nil
	end

	return table.concat({
		instruction,
		"",
		rendered_context,
	}, "\n")
end

local function symbol_prompt(source, symbol)
	local line1, line2 = symbols.range_lines(symbol)
	if not line1 then
		return nil
	end

	local symbol_source = context.capture(source.bufnr, source.winid, {
		line1 = line1,
		line2 = line2,
	})
	local rendered_context = context.render(symbol_source, {
		treesitter_text_lines = 40,
		selection_limit = 120,
	})
	if not rendered_context then
		return nil
	end

	return table.concat({
		("Use this LSP symbol as context: %s (%s)."):format(symbol.name, symbols.kind_name(symbol.kind)),
		"",
		rendered_context,
	}, "\n")
end

local function code_action_prompt(source, action)
	local rendered_context = context.render(source, {
		treesitter_text_lines = 40,
		selection_limit = 120,
	})
	if not rendered_context then
		return nil
	end

	local lines = {
		("Use this LSP code action as guidance: %s."):format(action.title),
		("Kind: %s"):format(code_actions.kind_label(action)),
	}
	if action.isPreferred then
		table.insert(lines, "Preferred: yes")
	end
	local diagnostic_count = code_actions.diagnostic_count(action)
	if diagnostic_count > 0 then
		table.insert(lines, ("Action diagnostics: %d"):format(diagnostic_count))
	end
	if code_actions.has_edit(action) then
		table.insert(lines, "Workspace edit: provided by LSP")
	end
	if type(action.command) == "table" and action.command.command then
		table.insert(lines, ("Command: %s"):format(action.command.command))
	elseif type(action.command) == "string" then
		table.insert(lines, ("Command: %s"):format(action.command))
	end
	table.insert(lines, "")
	table.insert(lines, rendered_context)
	return table.concat(lines, "\n")
end

local function treesitter_prompt(source, item)
	local line1, line2 = treesitter.range_lines(item)
	if not line1 then
		return nil
	end

	local node_source = context.capture(source.bufnr, source.winid, {
		line1 = line1,
		line2 = line2,
	})
	local rendered_context = context.render(node_source, {
		treesitter_text_lines = 40,
		selection_limit = 120,
	})
	if not rendered_context then
		return nil
	end

	return table.concat({
		("Use this Tree-sitter node as context: %s."):format(item.type or "node"),
		"",
		rendered_context,
	}, "\n")
end

local function hover_prompt(source, hover_text)
	local rendered_context = context.render(source, {
		treesitter_text_lines = 24,
		selection_limit = 80,
	})
	if not rendered_context then
		return nil
	end

	return table.concat({
		"Use this LSP hover documentation as context.",
		"",
		"Hover:",
		hover_text,
		"",
		rendered_context,
	}, "\n")
end

local function reference_prompt(reference)
	local bufnr, err = references.bufnr(reference)
	if not bufnr then
		return nil, err
	end
	local range = references.range(reference)
	if not range then
		return nil, "LSP reference has no range"
	end

	local reference_source = context.capture(bufnr, nil, range)
	if reference_source then
		reference_source.cursor = { range.line1, 0 }
	end
	local rendered_context = context.render(reference_source, {
		treesitter_text_lines = 24,
		selection_limit = 80,
	})
	if not rendered_context then
		return nil, "Failed to render LSP reference context"
	end

	return table.concat({
		"Use this LSP reference as context.",
		("Reference: %s:%d"):format(references.display_path(reference), range.line1),
		"",
		rendered_context,
	}, "\n")
end

local function escape_tabline(text)
	return tostring(text):gsub("%%", "%%%%")
end

local function tab_title(tabpage)
	local ok, title = pcall(vim.api.nvim_tabpage_get_var, tabpage, "acp_title")
	if ok and title and title ~= "" then
		return title
	end

	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		if vim.api.nvim_win_get_config(winid).relative == "" then
			local bufnr = vim.api.nvim_win_get_buf(winid)
			local name = vim.api.nvim_buf_get_name(bufnr)
			return name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
		end
	end

	return "[No Name]"
end

local function set_tab_title(state, title)
	if not state.tabpage or not vim.api.nvim_tabpage_is_valid(state.tabpage) then
		return
	end

	state.title = title
	pcall(vim.api.nvim_tabpage_set_var, state.tabpage, "acp_title", title)
	refresh_session_panels()
end

local function float_layout()
	local columns = vim.o.columns
	local lines = vim.o.lines
	local width = math.max(48, math.floor(columns * config.layout.width_ratio))
	width = math.min(width, math.max(20, columns - 4))

	local total_height = math.max(12, math.floor(lines * config.layout.height_ratio))
	total_height = math.min(total_height, math.max(8, lines - 4))

	local input_height = math.min(config.layout.input_height, math.max(3, total_height - 6))
	local gap = 1
	local output_height = math.max(5, total_height - input_height - gap)
	local row = math.max(0, lines - total_height - 2)
	local col = math.max(0, math.floor((columns - width) / 2))

	return {
		width = width,
		output_height = output_height,
		input_height = input_height,
		output_row = row,
		input_row = row + output_height + gap,
		col = col,
	}
end

local function input_float_config(state)
	local output_config = valid_win(state.output_win) and vim.api.nvim_win_get_config(state.output_win) or {}
	local output_position = valid_win(state.output_win) and vim.api.nvim_win_get_position(state.output_win) or { 0, 0 }
	local columns = vim.o.columns
	local lines = vim.o.lines
	local col = output_config.relative == "" and output_position[2] or 0
	local width = valid_win(state.output_win) and vim.api.nvim_win_get_width(state.output_win)
		or math.max(48, math.floor(columns * config.layout.width_ratio))
	width = math.min(width, math.max(20, columns - col))

	local input_height = math.min(config.layout.input_height, math.max(3, lines - 6))

	return {
		relative = "editor",
		row = math.max(0, lines - input_height - 3),
		col = output_config.relative == "" and col or math.max(0, math.floor((columns - width) / 2)),
		width = width,
		height = input_height,
		style = "minimal",
		border = "rounded",
		title = prompt_title(state),
		title_pos = "left",
		zindex = 50,
	}
end

local function apply_window_options(state)
	for _, winid in ipairs({ state.session_panel_win, state.output_win, state.input_win }) do
		if valid_win(winid) then
			vim.wo[winid].wrap = true
			vim.wo[winid].linebreak = true
			vim.wo[winid].signcolumn = "no"
			vim.wo[winid].number = false
			vim.wo[winid].relativenumber = false
			vim.wo[winid].foldcolumn = "0"
			pcall(function()
				vim.wo[winid].winfixbuf = true
			end)
		end
	end

	if valid_win(state.session_panel_win) then
		vim.wo[state.session_panel_win].wrap = false
		vim.wo[state.session_panel_win].linebreak = false
		vim.wo[state.session_panel_win].cursorline = true
		pcall(function()
			vim.wo[state.session_panel_win].winfixwidth = true
		end)
	end

	if valid_win(state.output_win) then
		vim.wo[state.output_win].cursorline = true
		vim.wo[state.output_win].foldmethod = "expr"
		vim.wo[state.output_win].foldexpr = "v:lua.acp_nvim_output_foldexpr()"
		vim.wo[state.output_win].foldtext = "v:lua.acp_nvim_output_foldtext()"
		vim.wo[state.output_win].foldlevel = 99
		vim.wo[state.output_win].foldcolumn = "1"
		refresh_output_chrome(state)
	end

	if state.mode ~= "float" and state.mode == "window" and valid_win(state.input_win) then
		vim.wo[state.input_win].winbar = prompt_title(state)
	end
end

local function apply_float_layout(state)
	local dims = float_layout()

	local output_config = {
		relative = "editor",
		row = dims.output_row,
		col = dims.col,
		width = dims.width,
		height = dims.output_height,
		style = "minimal",
		border = "rounded",
		title = output.window_title(state, {
			change_count = changes.count(state),
		}),
		title_pos = "left",
		zindex = 40,
	}

	local input_config = {
		relative = "editor",
		row = dims.input_row,
		col = dims.col,
		width = dims.width,
		height = dims.input_height,
		style = "minimal",
		border = "rounded",
		title = prompt_title(state),
		title_pos = "left",
		zindex = 50,
	}

	if valid_win(state.output_win) then
		vim.api.nvim_win_set_config(state.output_win, output_config)
	else
		state.output_win = vim.api.nvim_open_win(state.output_buf, false, output_config)
	end

	if valid_win(state.input_win) then
		vim.api.nvim_win_set_config(state.input_win, input_config)
	else
		state.input_win = vim.api.nvim_open_win(state.input_buf, true, input_config)
	end
end

local function apply_window_layout(state)
	if not valid_win(state.output_win) or not valid_win(state.input_win) then
		local total_height = math.max(config.layout.input_height + 6, math.floor(vim.o.lines * 0.45))

		vim.cmd(("botright %dsplit"):format(total_height))
		state.output_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.output_win, state.output_buf)

		vim.cmd(("botright %dsplit"):format(config.layout.input_height))
		state.input_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
	end

	if valid_win(state.input_win) then
		pcall(vim.api.nvim_win_set_height, state.input_win, config.layout.input_height)
	end
end

local function register_session_panel_autocmd(state)
	if not state.group or not valid_buf(state.session_panel_buf) then
		return
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = state.group,
		buffer = state.session_panel_buf,
		callback = function()
			session_panel_lines[state.session_panel_buf] = nil
		end,
	})
end

local function create_session_panel_buffer(state)
	state.session_panel_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(state.session_panel_buf, ("ACP://%s/%d/sessions"):format(state.adapter, state.id))
	set_buf_options(state.session_panel_buf, {
		bufhidden = "wipe",
		buftype = "nofile",
		filetype = "acp-sessions",
		modifiable = true,
		swapfile = false,
	})
	set_panel_lines(state.session_panel_buf, { "Sessions", "" })
	vim.keymap.set("n", "<CR>", function()
		M.select_session()
	end, { buffer = state.session_panel_buf, desc = "Open ACP session" })
	vim.keymap.set("n", "<leader>ak", function()
		M.open_actions()
	end, { buffer = state.session_panel_buf, desc = "Open ACP actions" })
	register_session_panel_autocmd(state)
end

local function apply_tab_layout(state)
	if not valid_buf(state.session_panel_buf) then
		create_session_panel_buffer(state)
		states[state.session_panel_buf] = state
	end

	if not valid_win(state.output_win) then
		vim.cmd("tabnew")
		state.tabpage = vim.api.nvim_get_current_tabpage()
		set_tab_title(state, state.title)
		state.output_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.output_win, state.output_buf)
	end

	if not valid_win(state.session_panel_win) and valid_buf(state.session_panel_buf) then
		local output_win = state.output_win
		vim.api.nvim_set_current_win(output_win)
		vim.cmd(("topleft %dvsplit"):format(config.layout.session_panel_width))
		state.session_panel_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.session_panel_win, state.session_panel_buf)
		pcall(vim.api.nvim_win_set_width, state.session_panel_win, config.layout.session_panel_width)
		vim.api.nvim_set_current_win(output_win)
	end

	render_session_panel(state)

	if valid_win(state.input_win) then
		vim.api.nvim_win_set_config(state.input_win, input_float_config(state))
	else
		state.input_win = vim.api.nvim_open_win(state.input_buf, true, input_float_config(state))
	end
end

local function apply_layout(state)
	if not valid_buf(state.output_buf) or not valid_buf(state.input_buf) then
		return
	end

	if state.mode == "tab" then
		apply_tab_layout(state)
	elseif state.mode == "window" then
		apply_window_layout(state)
	else
		apply_float_layout(state)
	end

	apply_window_options(state)
end

local function create_buffers(state)
	create_session_panel_buffer(state)
	state.output_buf = vim.api.nvim_create_buf(false, true)
	state.input_buf = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_buf_set_name(state.output_buf, ("ACP://%s/%d/output"):format(state.adapter, state.id))
	vim.api.nvim_buf_set_name(state.input_buf, ("ACP://%s/%d/input"):format(state.adapter, state.id))

	set_buf_options(state.output_buf, {
		bufhidden = "wipe",
		buftype = "nofile",
		filetype = "acp",
		modifiable = true,
		swapfile = false,
	})
	enable_output_language_injection(state)
	set_buf_options(state.input_buf, {
		bufhidden = "wipe",
		buftype = "nofile",
		completefunc = "v:lua.acp_nvim_completefunc",
		completeopt = "menuone,noselect",
		filetype = "markdown",
		swapfile = false,
	})

	local dashboard = output.dashboard_lines(state)
	state.output_dashboard_lines = #dashboard
	set_output_lines(state, 0, -1, dashboard)
	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })
	refresh_prompt_hints(state)
end

local function unregister(state)
	if not state or state.closed then
		return
	end

	state.closed = true
	state.connection:stop()
	stop_output_animation(state)
	clear_source_marks(state)
	session_panel_lines[state.session_panel_buf] = nil
	states[state.session_panel_buf] = nil
	states[state.output_buf] = nil
	states[state.input_buf] = nil
	sessions[state.id] = nil

	for _, winid in ipairs({ state.session_panel_win, state.output_win, state.input_win }) do
		if valid_win(winid) then
			pcall(vim.api.nvim_win_close, winid, true)
		end
	end

	refresh_session_panels()
end

local function register_autocmds(state)
	local group = vim.api.nvim_create_augroup(("AcpClient%d"):format(state.id), { clear = true })
	state.group = group

	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			if not state.closed then
				apply_layout(state)
			end
		end,
	})

	register_session_panel_autocmd(state)

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = state.output_buf,
		callback = function()
			unregister(state)
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = state.input_buf,
		callback = function()
			unregister(state)
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = state.input_buf,
		callback = function()
			refresh_prompt_hints(state)
		end,
	})

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = group,
		buffer = state.output_buf,
		callback = function()
			refresh_output_chrome(state)
		end,
	})
end

local function register_keymaps(state)
	local send = function()
		M.send()
	end
	local stop = function()
		M.stop()
	end
	local add_context = function()
		M.add_context()
	end
	local open_changes = function()
		M.open_changes()
	end
	local open_output = function()
		open_output_outline(state)
	end
	local open_search = function()
		open_output_search(state)
	end
	local open_code_blocks = function()
		open_output_code_blocks(state)
	end
	local open_locations = function()
		open_output_locations(state)
	end
	local open_diagnostics = function()
		M.open_diagnostics()
	end
	local open_commands = function()
		M.open_commands()
	end
	local open_config = function()
		M.open_config()
	end
	local open_actions = function()
		M.open_actions()
	end
	local open_code_actions = function()
		M.open_code_actions()
	end
	local add_hover = function()
		M.add_hover()
	end
	local open_references = function()
		M.open_references()
	end
	local open_symbols = function()
		M.open_symbols()
	end
	local open_treesitter = function()
		M.open_treesitter()
	end
	local previous_prompt = function()
		M.prompt_previous()
	end
	local next_prompt = function()
		M.prompt_next()
	end

	for _, bufnr in ipairs({ state.output_buf, state.input_buf }) do
		vim.keymap.set("n", "<leader>as", send, { buffer = bufnr, desc = "Send ACP prompt" })
		vim.keymap.set("n", "<leader>aq", stop, { buffer = bufnr, desc = "Stop ACP agent" })
		vim.keymap.set("n", "<leader>av", open_output, { buffer = bufnr, desc = "Open ACP output outline" })
		vim.keymap.set("n", "<leader>ax", open_search, { buffer = bufnr, desc = "Search ACP output" })
		vim.keymap.set("n", "<leader>ab", open_code_blocks, { buffer = bufnr, desc = "Open ACP code blocks" })
		vim.keymap.set("n", "<leader>ag", open_locations, { buffer = bufnr, desc = "Open ACP output locations" })
		vim.keymap.set("n", "<leader>ad", open_diagnostics, { buffer = bufnr, desc = "Open ACP diagnostics" })
		vim.keymap.set("n", "<leader>af", open_changes, { buffer = bufnr, desc = "Open ACP changed files" })
		vim.keymap.set("n", "<leader>a/", open_commands, { buffer = bufnr, desc = "Open ACP slash commands" })
		vim.keymap.set("n", "<leader>ao", open_config, { buffer = bufnr, desc = "Open ACP config options" })
		vim.keymap.set("n", "<leader>ak", open_actions, { buffer = bufnr, desc = "Open ACP actions" })
		vim.keymap.set("n", "<leader>aa", open_code_actions, { buffer = bufnr, desc = "Open ACP LSP code actions" })
		vim.keymap.set("n", "<leader>ah", add_hover, { buffer = bufnr, desc = "Add ACP LSP hover context" })
		vim.keymap.set("n", "<leader>ar", open_references, { buffer = bufnr, desc = "Open ACP LSP references" })
		vim.keymap.set("n", "<leader>al", open_symbols, { buffer = bufnr, desc = "Open ACP LSP symbols" })
		vim.keymap.set("n", "<leader>at", open_treesitter, { buffer = bufnr, desc = "Open ACP Tree-sitter nodes" })
		vim.keymap.set("n", "<leader>ap", previous_prompt, { buffer = bufnr, desc = "Previous ACP prompt" })
		vim.keymap.set("n", "<leader>an", next_prompt, { buffer = bufnr, desc = "Next ACP prompt" })
	end

	vim.keymap.set("n", "<leader>ac", add_context, { buffer = state.input_buf, desc = "Add ACP editor context" })
	vim.keymap.set("n", "[[", function()
		jump_output_section(state, -1)
	end, { buffer = state.output_buf, desc = "Previous ACP output section" })
	vim.keymap.set("n", "]]", function()
		jump_output_section(state, 1)
	end, { buffer = state.output_buf, desc = "Next ACP output section" })
	vim.keymap.set("n", "<leader>az", "za", { buffer = state.output_buf, desc = "Toggle ACP output fold" })
	vim.keymap.set({ "n", "i" }, "<M-p>", previous_prompt, { buffer = state.input_buf, desc = "Previous ACP prompt" })
	vim.keymap.set({ "n", "i" }, "<M-n>", next_prompt, { buffer = state.input_buf, desc = "Next ACP prompt" })
	vim.keymap.set("i", "<CR>", "<CR>", { buffer = state.input_buf, desc = "Insert newline" })
	vim.keymap.set("i", "<C-Space>", "<C-x><C-u>", { buffer = state.input_buf, desc = "Complete ACP prompt" })
	vim.keymap.set({ "n", "i" }, "<C-CR>", send, { buffer = state.input_buf, desc = "Send ACP prompt" })
	vim.keymap.set({ "n", "i" }, "<C-s>", send, { buffer = state.input_buf, desc = "Send ACP prompt" })
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	define_highlights()

	if vim.o.tabline == "" then
		vim.o.tabline = "%!v:lua.require'acp.ui'.tabline()"
	end

	vim.api.nvim_create_user_command("AcpChat", function(command)
		M.open(command.args ~= "" and command.args or nil, {
			mode = config.default_mode,
			source_range = command_source_range(command),
		})
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpChatContext", function(command)
		M.open(command.args ~= "" and command.args or nil, {
			mode = config.default_mode,
			source_range = command_source_range(command),
			draft = "context",
		})
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpReview", function(command)
		M.open(command.args ~= "" and command.args or nil, {
			mode = config.default_mode,
			source_range = command_source_range(command),
			draft = "review",
		})
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpChatFloat", function(command)
		M.open(command.args ~= "" and command.args or nil, {
			mode = "float",
			source_range = command_source_range(command),
		})
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpChatWindow", function(command)
		M.open(command.args ~= "" and command.args or nil, {
			mode = "window",
			source_range = command_source_range(command),
		})
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpChatBuffer", function(command)
		M.open(command.args ~= "" and command.args or nil, {
			mode = "window",
			source_range = command_source_range(command),
		})
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpChatTab", function(command)
		M.open(command.args ~= "" and command.args or nil, {
			mode = "tab",
			source_range = command_source_range(command),
		})
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpSend", function()
		M.send()
	end, {})

	vim.api.nvim_create_user_command("AcpPromptPrev", function()
		M.prompt_previous()
	end, {})

	vim.api.nvim_create_user_command("AcpPromptNext", function()
		M.prompt_next()
	end, {})

	vim.api.nvim_create_user_command("AcpStop", function()
		M.stop()
	end, {})

	vim.api.nvim_create_user_command("AcpSessions", function()
		M.focus_sessions()
	end, {})

	vim.api.nvim_create_user_command("AcpActions", function()
		M.open_actions()
	end, {})

	vim.api.nvim_create_user_command("AcpChanges", function()
		M.open_changes()
	end, {})

	vim.api.nvim_create_user_command("AcpOutput", function()
		M.open_output()
	end, {})

	vim.api.nvim_create_user_command("AcpOutputSearch", function()
		M.open_output_search()
	end, {})

	vim.api.nvim_create_user_command("AcpCodeBlocks", function()
		M.open_code_blocks()
	end, {})

	vim.api.nvim_create_user_command("AcpOutputLocations", function()
		M.open_output_locations()
	end, {})

	vim.api.nvim_create_user_command("AcpDiagnostics", function()
		M.open_diagnostics()
	end, {})

	vim.api.nvim_create_user_command("AcpCommands", function()
		M.open_commands()
	end, {})

	vim.api.nvim_create_user_command("AcpConfig", function()
		M.open_config()
	end, {})

	vim.api.nvim_create_user_command("AcpCodeActions", function()
		M.open_code_actions()
	end, {})

	vim.api.nvim_create_user_command("AcpHover", function()
		M.add_hover()
	end, {})

	vim.api.nvim_create_user_command("AcpReferences", function()
		M.open_references()
	end, {})

	vim.api.nvim_create_user_command("AcpSymbols", function()
		M.open_symbols()
	end, {})

	vim.api.nvim_create_user_command("AcpTreeSitter", function()
		M.open_treesitter()
	end, {})

	vim.api.nvim_create_user_command("AcpHistory", function()
		history.open_browser()
	end, {})

	vim.api.nvim_create_user_command("AcpRestore", function(command)
		M.restore(command.args ~= "" and command.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpHistoryDraft", function(command)
		local adapter_name = command.args ~= "" and command.args or nil
		history.open_browser({
			open_chat = function(entry)
				local prompt = history.replay_prompt(entry)
				if not prompt then
					notify("Failed to read ACP history entry", vim.log.levels.ERROR)
					return
				end
				M.open(adapter_name, {
					mode = config.default_mode,
					initial_prompt = prompt,
				})
			end,
		})
	end, {
		nargs = "?",
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpAddContext", function()
		M.add_context()
	end, {})

	vim.api.nvim_create_user_command("AcpFixDiagnostics", function(command)
		local source_range = command_source_range(command)
		local bufnr = vim.api.nvim_get_current_buf()
		if diagnostics.count(bufnr, { range = source_range }) == 0 then
			notify("No diagnostics found in the current buffer or range", vim.log.levels.WARN)
			return
		end

		M.open(command.args ~= "" and command.args or nil, {
			mode = config.default_mode,
			source_range = source_range,
			draft = "diagnostics",
		})
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return adapter_names()
		end,
	})

	vim.api.nvim_create_user_command("AcpHealth", function(command)
		M.health(command.args ~= "" and command.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return adapter_names()
		end,
	})
end

function M.get_config()
	return vim.deepcopy(config)
end

local function append_role_text(state, role, text)
	if not text or text == "" then
		return
	end
	if state.stream_role ~= role then
		append_lines(state, { "", role, "" })
		state.stream_role = role
	end
	append_text(state, text)
end

local function chat_handlers(state, opts)
	opts = opts or {}
	return {
		started = function()
			if opts.started then
				opts.started()
			else
				set_run_status(state, "running")
			end
		end,
		user_message_chunk = function(text)
			append_role_text(state, "You", text)
		end,
		message_chunk = function(text)
			if not state.streaming then
				state.streaming = true
				set_run_status(state, "streaming")
			end
			append_role_text(state, "Agent", text)
		end,
		thought_chunk = function(text)
			state.stream_role = nil
			set_run_status(state, "thinking")
			append_lines(state, { "", ("Thought: %s"):format(text), "" })
		end,
		tool_call = function(update)
			state.stream_role = nil
			set_run_status(state, ("tool: %s"):format(update.title or update.kind or "tool call"))
			append_lines(state, { "", ("Tool: %s"):format(update.title or update.kind or "tool call"), "" })
		end,
		tool_update = function(update)
			state.stream_role = nil
			set_run_status(state, ("tool: %s"):format(update.status or update.title or "updated"))
			append_lines(state, { "", ("Tool update: %s"):format(update.status or update.title or "updated"), "" })
		end,
		terminal_attach = function(event)
			state.stream_role = nil
			ensure_terminal_block(state, event.terminal_id)
			if event.output and event.output ~= "" then
				append_terminal_output(state, {
					terminal_id = event.terminal_id,
					text = event.output,
					truncated = event.truncated,
				})
			end
		end,
		terminal_output = function(event)
			state.stream_role = nil
			set_run_status(state, ("terminal: %s"):format(event.terminal_id))
			append_terminal_output(state, event)
		end,
		file_written = function(path)
			state.stream_role = nil
			local entry = changes.record(state, path)
			local display = entry and entry.display or vim.fn.fnamemodify(path, ":.")
			set_run_status(state, ("wrote %s"):format(display))
			append_lines(state, { "", ("Wrote %s"):format(display), "Use :AcpChanges to review changed files.", "" })
			refresh_output_chrome(state)
			refresh_session_panels()
		end,
		session_info = function(update)
			if update.title and update.title ~= "" then
				set_tab_title(state, update.title)
			end
			if metadata.apply_session(state, update) then
				refresh_output_dashboard(state)
				refresh_output_chrome(state)
				refresh_prompt_chrome(state)
			end
		end,
		usage = function(update)
			if metadata.apply_session(state, update) then
				refresh_output_dashboard(state)
				refresh_output_chrome(state)
				refresh_prompt_chrome(state)
			end
		end,
		available_commands = function(commands)
			state.available_commands = commands
			set_run_status(state, ("%d command(s) available"):format(#commands))
			refresh_session_panels()
		end,
		config_options = function(options)
			state.config_options = options
			if not state.busy then
				set_run_status(state, ("%d config option(s) available"):format(#acp_config.select_options(options)))
			else
				refresh_session_panels()
			end
		end,
		stderr = function(text)
			state.stream_role = nil
			append_lines(state, { "", "stderr:" })
			append_lines(state, vim.split(text:gsub("%s+$", ""), "\n", { plain = true }))
			append_lines(state, { "" })
		end,
		done = function(stop_reason)
			state.busy = false
			set_run_status(state, ("stopped: %s"):format(stop_reason or "done"))
			if valid_win(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
		end,
		error = function(message)
			state.busy = false
			set_run_status(state, ("error: %s"):format(message))
			if valid_win(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
		end,
	}
end

local function start_restore(state, session_info)
	local title = session_info.title or session_info.sessionId
	state.restored_session_id = session_info.sessionId
	state.busy = true
	state.streaming = false
	state.stream_role = nil
	set_tab_title(state, title and ("ACP %s"):format(title) or state.title)
	append_lines(state, { ("Restoring session: %s"):format(title or "[unknown]"), "" })
	set_run_status(state, "restoring")

	local ok = state.connection:restore_session_async(session_info, chat_handlers(state), function(success, mode_or_err)
		state.busy = false
		if not success then
			set_run_status(state, ("error: %s"):format(mode_or_err))
			return
		end

		if mode_or_err == "resume" then
			append_lines(state, { "", "Session resumed without replayed transcript.", "" })
		end
		set_run_status(state, ("restored: %s"):format(mode_or_err or "done"))
		if valid_win(state.input_win) then
			vim.api.nvim_set_current_win(state.input_win)
		end
	end)

	if not ok then
		state.busy = false
		set_run_status(state, "error: failed to restore session")
	end
end

function M.open(adapter_name, opts)
	opts = opts or {}
	adapter_name = adapter_name or config.default_adapter
	local adapter = config.adapters[adapter_name]
	if not adapter then
		notify(("Unknown ACP adapter: %s"):format(adapter_name), vim.log.levels.ERROR)
		return
	end

	local id = next_session_id
	next_session_id = next_session_id + 1
	local resolved_metadata = metadata.resolve_adapter(adapter)
	local source = context.capture(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), opts.source_range)
	local cwd = vim.fn.getcwd()

	local state = {
		id = id,
		adapter = adapter_name,
		mode = opts.mode or config.default_mode,
		title = ("ACP %s #%d"):format(adapter_name, id),
		cwd = cwd,
		model = resolved_metadata.model,
		context_window = resolved_metadata.context_window,
		connection = opts.connection or Connection.new({
			adapter = adapter,
			cwd = cwd,
		}),
		source = source,
		busy = false,
	}

	create_buffers(state)
	sessions[id] = state
	states[state.session_panel_buf] = state
	states[state.output_buf] = state
	states[state.input_buf] = state
	if opts.draft == "diagnostics" then
		append_input_text(state, diagnostics_prompt(state.source))
	elseif opts.draft == "context" then
		append_input_text(state, context_prompt(state.source, "Use this editor context for the next request."))
	elseif opts.draft == "review" then
		append_input_text(state, context_prompt(
			state.source,
			"Review this code. Prioritize correctness, edge cases, and maintainability."
		))
	elseif opts.initial_prompt then
		append_input_text(state, opts.initial_prompt)
	end
	register_keymaps(state)
	register_autocmds(state)
	apply_layout(state)
	refresh_source_marks(state)
	refresh_session_panels()

	if opts.restore_session then
		start_restore(state, opts.restore_session)
	elseif valid_win(state.input_win) then
		vim.api.nvim_set_current_win(state.input_win)
	end
end

local function current_state()
	local bufnr = vim.api.nvim_get_current_buf()
	local state = states[bufnr]
	if not state then
		notify("Current buffer is not an ACP chat", vim.log.levels.WARN)
		return nil
	end
	return state
end

local function state_for_current_buffer()
	return states[vim.api.nvim_get_current_buf()]
end

local function add_action(items, label, detail, key, scope, run)
	table.insert(items, {
		label = label,
		detail = detail,
		key = key,
		scope = scope,
		run = run,
	})
end

local function action_palette_items(state)
	local items = {}

	if state then
		add_action(items, "Send prompt", "Submit the current prompt buffer", "<C-s>", "session", function()
			M.send()
		end)
		add_action(items, "Stop agent", "Stop the active ACP adapter process", "<leader>aq", "session", function()
			M.stop()
		end)
		add_action(items, "Add context", "Insert captured editor context into the prompt", "<leader>ac", "session", function()
			M.add_context()
		end)
		add_action(items, "Output outline", "Jump across transcript sections", "<leader>av", "session", function()
			M.open_output()
		end)
		add_action(items, "Search output", "Search every non-empty transcript line with context preview", "<leader>ax", "session", function()
			M.open_output_search()
		end)
		add_action(items, "Code blocks", "Preview and open fenced code from the output", "<leader>ab", "session", function()
			M.open_code_blocks()
		end)
		add_action(items, "Output locations", "Preview and jump to file references in the transcript", "<leader>ag", "session", function()
			M.open_output_locations()
		end)
		add_action(items, "Changed files", "Open files changed by this session in quickfix", "<leader>af", "session", function()
			M.open_changes()
		end)
		add_action(items, "Diagnostics", "Draft a focused fix from source diagnostics", "<leader>ad", "LSP", function()
			M.open_diagnostics()
		end)
		add_action(items, "Code actions", "Draft from source-buffer LSP code actions", "<leader>aa", "LSP", function()
			M.open_code_actions()
		end)
		add_action(items, "Hover context", "Insert LSP hover documentation into the prompt", "<leader>ah", "LSP", function()
			M.add_hover()
		end)
		add_action(items, "References", "Pick LSP references as focused context", "<leader>ar", "LSP", function()
			M.open_references()
		end)
		add_action(items, "Symbols", "Pick LSP document symbols as focused context", "<leader>al", "LSP", function()
			M.open_symbols()
		end)
		add_action(items, "Tree-sitter nodes", "Pick syntax-aware source context", "<leader>at", "Tree-sitter", function()
			M.open_treesitter()
		end)
		add_action(items, "Slash commands", "Draft an adapter-advertised slash command", "<leader>a/", "session", function()
			M.open_commands()
		end)
		add_action(items, "Config options", "Pick adapter-advertised session config", "<leader>ao", "session", function()
			M.open_config()
		end)
	else
		add_action(items, "New chat", "Open the default ACP chat layout", ":AcpChat", "global", function()
			M.open(config.default_adapter, { mode = config.default_mode })
		end)
		add_action(items, "Chat with context", "Open chat with source context prefilled", ":AcpChatContext", "global", function()
			M.open(config.default_adapter, { mode = config.default_mode, draft = "context" })
		end)
		add_action(items, "Review source", "Open a review-focused chat draft", ":AcpReview", "global", function()
			M.open(config.default_adapter, { mode = config.default_mode, draft = "review" })
		end)
	end

	add_action(items, "Sessions", "Focus or pick an open ACP session", ":AcpSessions", "global", function()
		M.focus_sessions()
	end)
	add_action(items, "Restore session", "Restore an adapter-backed ACP session", ":AcpRestore", "global", function()
		M.restore(config.default_adapter)
	end)
	add_action(items, "History", "Browse saved plain-text transcripts", ":AcpHistory", "global", function()
		history.open_browser()
	end)

	return items
end

local function open_action_palette(state, origin_win)
	local action_items = action_palette_items(state)
	local lines, line_actions = actions.picker_lines(action_items)
	picker.open({
		name = "ACP://actions",
		filetype = "acp-actions",
		lines = lines,
		title = " ACP actions ",
		submit_desc = "Run ACP action",
		close_desc = "Close ACP actions",
		on_submit = function(row, view)
			local action = line_actions[row]
			if not action then
				return
			end

			view.close()
			if valid_win(origin_win) then
				vim.api.nvim_set_current_win(origin_win)
			end
			action.run()
		end,
	})
end

local function focus_session(state)
	if not state or state.closed then
		notify("ACP session is no longer available", vim.log.levels.WARN)
		return
	end

	if state.mode == "tab" and state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage) then
		vim.api.nvim_set_current_tabpage(state.tabpage)
	end

	apply_layout(state)

	if valid_win(state.input_win) then
		vim.api.nvim_set_current_win(state.input_win)
	elseif valid_win(state.output_win) then
		vim.api.nvim_set_current_win(state.output_win)
	end

	refresh_session_panels()
end

local function session_picker_lines(list)
	local lines = { "ACP Sessions", "" }
	local line_ids = {}
	for index, session in ipairs(list) do
		local model = session.model and session.model ~= "" and (" " .. session.model) or ""
		table.insert(lines, ("%d. #%d %s%s"):format(index, session.id, session.adapter, model))
		line_ids[#lines] = session.id
		table.insert(lines, ("   %s"):format(session_status(session)))
		line_ids[#lines] = session.id
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to focus, or q/<Esc> to close.")
	return lines, line_ids
end

local function open_session_picker()
	local list = sorted_sessions()
	if #list == 0 then
		notify("No ACP sessions open", vim.log.levels.WARN)
		return false
	end

	local lines, line_ids = session_picker_lines(list)
	picker.open({
		name = "ACP://sessions",
		filetype = "acp-sessions",
		lines = lines,
		title = " ACP sessions ",
		submit_desc = "Focus ACP session",
		close_desc = "Close ACP sessions",
		on_submit = function(row, view)
			local id = line_ids[row]
			view.close()
			focus_session(sessions[id])
		end,
	})

	return true
end

local function restore_picker_lines(list)
	local lines = { "ACP Adapter Sessions", "" }
	local line_sessions = {}
	for index, session in ipairs(list) do
		local title = session.title or session.sessionId or "[untitled]"
		local updated = session.updatedAt and session.updatedAt ~= "" and ("  " .. session.updatedAt) or ""
		local cwd = session.cwd and session.cwd ~= "" and session.cwd or "[unknown cwd]"
		table.insert(lines, ("%d. %s%s"):format(index, title, updated))
		line_sessions[#lines] = session
		table.insert(lines, ("   %s"):format(cwd))
		line_sessions[#lines] = session
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to restore, or q/<Esc> to close.")
	return lines, line_sessions
end

local function open_restore_picker(adapter_name, connection, list)
	local lines, line_sessions = restore_picker_lines(list)
	picker.open({
		name = ("ACP://%s/restore"):format(adapter_name),
		filetype = "acp-sessions",
		lines = lines,
		title = " ACP restore ",
		submit_desc = "Restore ACP adapter session",
		close_desc = "Close ACP restore sessions",
		on_submit = function(row, view)
			local session = line_sessions[row]
			if not session then
				return
			end
			view.close()
			M.open(adapter_name, {
				mode = config.default_mode,
				connection = connection,
				restore_session = session,
			})
		end,
		on_cancel = function()
			connection:stop()
		end,
	})

	return true
end

local function open_command_picker(state)
	local available_commands = state.available_commands or {}
	if #available_commands == 0 then
		notify("No ACP commands advertised for this session", vim.log.levels.WARN)
		return false
	end

	local lines, line_commands = acp_commands.picker_lines(available_commands)
	picker.open({
		name = ("ACP://%s/%d/commands"):format(state.adapter, state.id),
		filetype = "acp-sessions",
		lines = lines,
		title = " ACP commands ",
		submit_desc = "Draft ACP slash command",
		close_desc = "Close ACP commands",
		on_submit = function(row, view)
			local command = line_commands[row]
			local text = acp_commands.slash_text(command)
			if not text then
				return
			end
			view.close()
			set_input_text(state, text)
			if valid_win(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
		end,
	})

	return true
end

local function open_diagnostic_picker(state)
	local items = diagnostics.items(state.source and state.source.bufnr, {
		range = state.source and state.source.range,
	})
	if #items == 0 then
		notify("No diagnostics found for the source buffer or range", vim.log.levels.WARN)
		return false
	end

	local lines, line_items = diagnostics.picker_lines(items)
	picker.open({
		name = ("ACP://%s/%d/diagnostics"):format(state.adapter, state.id),
		filetype = "acp-diagnostics",
		lines = lines,
		title = " ACP diagnostics ",
		submit_desc = "Draft ACP diagnostic fix",
		close_desc = "Close ACP diagnostics",
		preview = function(row)
			local item = line_items[row]
			if not item then
				return nil
			end
			return source_preview(
				state.source.bufnr,
				diagnostics.range(item),
				(" Diagnostic %s "):format(diagnostics.severity_name(item.severity))
			)
		end,
		on_submit = function(row, view)
			local item = line_items[row]
			if not item then
				return
			end
			local prompt = diagnostic_item_prompt(state.source, item)
			if not prompt then
				notify("Failed to render diagnostic context", vim.log.levels.ERROR)
				return
			end
			view.close()
			append_input_text(state, prompt)
			if not state.busy then
				set_run_status(state, ("diagnostic: %s"):format(diagnostics.severity_name(item.severity)))
			end
			if valid_win(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
		end,
	})

	return true
end

local function open_config_value_picker(state, option)
	local lines, line_values = acp_config.value_lines(option)
	picker.open({
		name = ("ACP://%s/%d/config/%s"):format(state.adapter, state.id, option.id),
		filetype = "acp-sessions",
		lines = lines,
		title = " ACP config value ",
		submit_desc = "Set ACP config option",
		close_desc = "Close ACP config values",
		on_submit = function(row, view)
			local choice = line_values[row]
			if not choice then
				return
			end

			view.close()
			local option_name = acp_config.option_label(option)
			local value_name = acp_config.value_label(option, choice.value)
			set_run_status(state, ("setting config: %s"):format(option_name))
			local ok = state.connection:set_config_option_async(option.id, choice.value, function(success, result_or_err)
				if not success then
					set_run_status(state, ("error: %s"):format(result_or_err))
					return
				end

				if type(result_or_err) == "table" and type(result_or_err.configOptions) == "table" then
					state.config_options = result_or_err.configOptions
				end
				set_run_status(state, ("config: %s = %s"):format(option_name, value_name))
				refresh_session_panels()
			end)

			if not ok then
				set_run_status(state, "error: failed to set config option")
			end
		end,
	})

	return true
end

local function open_config_picker(state)
	if #acp_config.select_options(state.config_options) == 0 then
		if not state.connection.session_id then
			set_run_status(state, "loading config")
			local ok = state.connection:ensure_session_async(function(success, result_or_err, session_result)
				if not success then
					set_run_status(state, ("error: %s"):format(result_or_err or "failed to load config"))
					return
				end
				if type(session_result) == "table" and type(session_result.configOptions) == "table" then
					state.config_options = session_result.configOptions
				end
				open_config_picker(state)
			end)
			if not ok then
				set_run_status(state, "error: failed to load config")
			end
			return ok
		end

		notify("No ACP config options advertised for this session", vim.log.levels.WARN)
		return false
	end

	local lines, line_options = acp_config.picker_lines(state.config_options)
	picker.open({
		name = ("ACP://%s/%d/config"):format(state.adapter, state.id),
		filetype = "acp-sessions",
		lines = lines,
		title = " ACP config ",
		submit_desc = "Open ACP config values",
		close_desc = "Close ACP config",
		on_submit = function(row, view)
			local option = line_options[row]
			if not option then
				return
			end
			view.close()
			open_config_value_picker(state, option)
		end,
	})

	return true
end

local function open_code_action_picker(state, action_list)
	if not action_list or #action_list == 0 then
		notify("No LSP code actions found for the source range", vim.log.levels.WARN)
		return false
	end

	local lines, line_actions = code_actions.picker_lines(action_list)
	picker.open({
		name = ("ACP://%s/%d/code-actions"):format(state.adapter, state.id),
		filetype = "acp-code-actions",
		lines = lines,
		title = " ACP code actions ",
		submit_desc = "Draft ACP code action",
		close_desc = "Close ACP code actions",
		preview = function(row)
			local action = line_actions[row]
			if not action then
				return nil
			end
			return source_preview(
				state.source.bufnr,
				source_range(state.source),
				(" Code action %s "):format(action.title)
			)
		end,
		on_submit = function(row, view)
			local action = line_actions[row]
			if not action then
				return
			end
			local prompt = code_action_prompt(state.source, action)
			if not prompt then
				notify("Failed to render LSP code action context", vim.log.levels.ERROR)
				return
			end
			view.close()
			append_input_text(state, prompt)
			if not state.busy then
				set_run_status(state, ("code action: %s"):format(action.title))
			end
			if valid_win(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
		end,
	})

	return true
end

local function request_lsp_symbols(bufnr, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP document-symbol requests are unavailable")
		return false
	end

	local params = {
		textDocument = {
			uri = vim.uri_from_bufnr(bufnr),
		},
	}
	local ok, request_ids = pcall(vim.lsp.buf_request_all, bufnr, "textDocument/documentSymbol", params, function(results)
		local raw_symbols = {}
		for _, response in pairs(results or {}) do
			if type(response) == "table" and type(response.result) == "table" then
				vim.list_extend(raw_symbols, response.result)
			end
		end
		callback(symbols.flatten(raw_symbols), nil)
	end)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports document symbols")
		return false
	end
	return true
end

local function open_symbol_picker(state, symbol_list)
	if not symbol_list or #symbol_list == 0 then
		notify("No LSP symbols found for the source buffer", vim.log.levels.WARN)
		return false
	end

	local lines, line_symbols = symbols.picker_lines(symbol_list)
	picker.open({
		name = ("ACP://%s/%d/symbols"):format(state.adapter, state.id),
		filetype = "acp-symbols",
		lines = lines,
		title = " ACP symbols ",
		submit_desc = "Add ACP symbol context",
		close_desc = "Close ACP symbols",
		preview = function(row)
			local symbol = line_symbols[row]
			if not symbol then
				return nil
			end
			local line1, line2 = symbols.range_lines(symbol)
			if not line1 then
				return nil
			end
			return source_preview(
				state.source.bufnr,
				{ line1 = line1, line2 = line2 },
				(" Symbol %s "):format(symbol.name)
			)
		end,
		on_submit = function(row, view)
			local symbol = line_symbols[row]
			if not symbol then
				return
			end
			local prompt = symbol_prompt(state.source, symbol)
			if not prompt then
				notify("Failed to render LSP symbol context", vim.log.levels.ERROR)
				return
			end
			view.close()
			append_input_text(state, prompt)
			if not state.busy then
				set_run_status(state, ("symbol context: %s"):format(symbol.name))
			end
			if valid_win(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
		end,
	})

	return true
end

local function open_treesitter_picker(state, node_list)
	if not node_list or #node_list == 0 then
		notify("No Tree-sitter nodes found for the source cursor", vim.log.levels.WARN)
		return false
	end

	local lines, line_nodes = treesitter.picker_lines(node_list)
	picker.open({
		name = ("ACP://%s/%d/treesitter"):format(state.adapter, state.id),
		filetype = "acp-treesitter",
		lines = lines,
		title = " ACP Tree-sitter ",
		submit_desc = "Add ACP Tree-sitter context",
		close_desc = "Close ACP Tree-sitter nodes",
		preview = function(row)
			local item = line_nodes[row]
			if not item then
				return nil
			end
			local line1, line2 = treesitter.range_lines(item)
			if not line1 then
				return nil
			end
			return source_preview(
				state.source.bufnr,
				{ line1 = line1, line2 = line2 },
				(" Tree-sitter %s "):format(item.type or "node")
			)
		end,
		on_submit = function(row, view)
			local item = line_nodes[row]
			if not item then
				return
			end
			local prompt = treesitter_prompt(state.source, item)
			if not prompt then
				notify("Failed to render Tree-sitter node context", vim.log.levels.ERROR)
				return
			end
			view.close()
			append_input_text(state, prompt)
			if not state.busy then
				set_run_status(state, ("tree-sitter context: %s"):format(item.type or "node"))
			end
			if valid_win(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
		end,
	})

	return true
end

local function open_reference_picker(state, reference_list)
	if not reference_list or #reference_list == 0 then
		notify("No LSP references found for the source cursor", vim.log.levels.WARN)
		return false
	end

	local lines, line_references = references.picker_lines(reference_list)
	picker.open({
		name = ("ACP://%s/%d/references"):format(state.adapter, state.id),
		filetype = "acp-references",
		lines = lines,
		title = " ACP references ",
		submit_desc = "Add ACP reference context",
		close_desc = "Close ACP references",
		preview = function(row)
			local reference = line_references[row]
			if not reference then
				return nil
			end
			local bufnr = references.bufnr(reference)
			return source_preview(
				bufnr,
				references.range(reference),
				(" Reference %s "):format(references.display_path(reference))
			)
		end,
		on_submit = function(row, view)
			local reference = line_references[row]
			if not reference then
				return
			end
			local prompt, err = reference_prompt(reference)
			if not prompt then
				notify(err or "Failed to render LSP reference context", vim.log.levels.ERROR)
				return
			end
			view.close()
			append_input_text(state, prompt)
			if not state.busy then
				set_run_status(state, "reference context added")
			end
			if valid_win(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
		end,
	})

	return true
end

function M.select_session()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local id = session_panel_lines[bufnr] and session_panel_lines[bufnr][line]
	if not id then
		return
	end

	focus_session(sessions[id])
end

function M.focus_sessions()
	local state = states[vim.api.nvim_get_current_buf()]

	if state and (state.mode ~= "tab" or not valid_win(state.session_panel_win)) then
		if state.mode == "tab" then
			apply_layout(state)
		end
	end

	if state and state.mode == "tab" and valid_win(state.session_panel_win) then
		vim.api.nvim_set_current_win(state.session_panel_win)
		return
	end

	open_session_picker()
end

function M.open_actions()
	open_action_palette(state_for_current_buffer(), vim.api.nvim_get_current_win())
end

function M.restore(adapter_name)
	adapter_name = adapter_name or config.default_adapter
	local adapter = config.adapters[adapter_name]
	if not adapter then
		notify(("Unknown ACP adapter: %s"):format(adapter_name), vim.log.levels.ERROR)
		return
	end

	local connection = Connection.new({
		adapter = adapter,
		cwd = vim.fn.getcwd(),
	})
	notify(("Listing %s ACP sessions"):format(adapter_name))
	connection:list_sessions_async(function(list, err)
		if err then
			connection:stop()
			notify(err, vim.log.levels.WARN)
			return
		end
		if not list or #list == 0 then
			connection:stop()
			notify("No adapter-backed ACP sessions found for this workspace", vim.log.levels.WARN)
			return
		end

		open_restore_picker(adapter_name, connection, list)
	end)
end

function M.add_context()
	local state = current_state()
	if not state then
		return
	end

	local rendered = context.render(state.source)
	if not rendered then
		notify("No editor context is available for this ACP session", vim.log.levels.WARN)
		return
	end

	append_input_text(state, rendered)
	if valid_win(state.input_win) then
		vim.api.nvim_set_current_win(state.input_win)
	end
end

function M.open_changes()
	local state = current_state()
	if not state then
		return
	end

	if not changes.open_quickfix(state) then
		notify("No ACP file changes recorded for this session", vim.log.levels.WARN)
		return
	end
end

function M.open_output()
	local state = current_state()
	if not state then
		return
	end

	open_output_outline(state)
end

function M.open_output_search()
	local state = current_state()
	if not state then
		return
	end

	open_output_search(state)
end

function M.open_code_blocks()
	local state = current_state()
	if not state then
		return
	end

	open_output_code_blocks(state)
end

function M.open_output_locations()
	local state = current_state()
	if not state then
		return
	end

	open_output_locations(state)
end

function M.open_diagnostics()
	local state = current_state()
	if not state then
		return
	end
	if not state.source or not valid_buf(state.source.bufnr) then
		notify("No source buffer is available for this ACP session", vim.log.levels.WARN)
		return
	end

	open_diagnostic_picker(state)
end

function M.open_commands()
	local state = current_state()
	if not state then
		return
	end

	open_command_picker(state)
end

function M.open_config()
	local state = current_state()
	if not state then
		return
	end

	open_config_picker(state)
end

function M.open_code_actions()
	local state = current_state()
	if not state then
		return
	end
	if not state.source or not valid_buf(state.source.bufnr) then
		notify("No source buffer is available for this ACP session", vim.log.levels.WARN)
		return
	end

	if not state.busy then
		set_run_status(state, "loading code actions")
	end
	code_actions.request(state.source, function(action_list, err)
		if err then
			if not state.busy then
				set_run_status(state, ("error: %s"):format(err))
			end
			notify(err, vim.log.levels.WARN)
			return
		end
		open_code_action_picker(state, action_list)
	end)
end

function M.add_hover()
	local state = current_state()
	if not state then
		return
	end
	if not state.source or not valid_buf(state.source.bufnr) then
		notify("No source buffer is available for this ACP session", vim.log.levels.WARN)
		return
	end

	if not state.busy then
		set_run_status(state, "loading hover")
	end
	hover.request(state.source, function(hover_text, err)
		if err then
			if not state.busy then
				set_run_status(state, ("error: %s"):format(err))
			end
			notify(err, vim.log.levels.WARN)
			return
		end
		if not hover_text or hover_text == "" then
			notify("No LSP hover documentation found for the source cursor", vim.log.levels.WARN)
			return
		end

		local prompt = hover_prompt(state.source, hover_text)
		if not prompt then
			notify("Failed to render LSP hover context", vim.log.levels.ERROR)
			return
		end
		append_input_text(state, prompt)
		if not state.busy then
			set_run_status(state, "hover context added")
		end
		if valid_win(state.input_win) then
			vim.api.nvim_set_current_win(state.input_win)
		end
	end)
end

function M.open_references()
	local state = current_state()
	if not state then
		return
	end
	if not state.source or not valid_buf(state.source.bufnr) then
		notify("No source buffer is available for this ACP session", vim.log.levels.WARN)
		return
	end

	if not state.busy then
		set_run_status(state, "loading references")
	end
	references.request(state.source, function(reference_list, err)
		if err then
			if not state.busy then
				set_run_status(state, ("error: %s"):format(err))
			end
			notify(err, vim.log.levels.WARN)
			return
		end
		open_reference_picker(state, reference_list)
	end)
end

function M.open_symbols()
	local state = current_state()
	if not state then
		return
	end
	if not state.source or not valid_buf(state.source.bufnr) then
		notify("No source buffer is available for this ACP session", vim.log.levels.WARN)
		return
	end

	if not state.busy then
		set_run_status(state, "loading symbols")
	end
	request_lsp_symbols(state.source.bufnr, function(symbol_list, err)
		if err then
			if not state.busy then
				set_run_status(state, ("error: %s"):format(err))
			end
			notify(err, vim.log.levels.WARN)
			return
		end
		open_symbol_picker(state, symbol_list)
	end)
end

function M.open_treesitter()
	local state = current_state()
	if not state then
		return
	end
	if not state.source or not valid_buf(state.source.bufnr) then
		notify("No source buffer is available for this ACP session", vim.log.levels.WARN)
		return
	end

	local node_list, err = treesitter.nodes(state.source.bufnr, state.source.cursor or { 1, 0 })
	if err then
		notify(err, vim.log.levels.WARN)
		return
	end
	open_treesitter_picker(state, node_list)
end

function M.completefunc(findstart, base)
	if tonumber(findstart) == 1 then
		return acp_commands.completion_start(vim.fn.getline("."), vim.fn.col(".") - 1)
	end

	local state = states[vim.api.nvim_get_current_buf()]
	if not state then
		return {}
	end

	return acp_commands.completion_items(state.available_commands, base)
end

function M.prompt_previous()
	local state = current_state()
	if not state then
		return
	end

	recall_prompt(state, -1)
end

function M.prompt_next()
	local state = current_state()
	if not state then
		return
	end

	recall_prompt(state, 1)
end

function M.send()
	local state = current_state()
	if not state then
		return
	end
	if state.busy then
		notify("ACP agent is still responding", vim.log.levels.WARN)
		return
	end

	local prompt = input_prompt(state)
	if not prompt then
		notify("Prompt is empty", vim.log.levels.WARN)
		return
	end

	record_prompt(state, prompt)
	state.busy = true
	state.streaming = false
	state.run_status = nil
	state.run_status_line = nil

	clear_input(state)
	append_lines(state, { "", "You", "" })
	append_lines(state, vim.split(prompt, "\n", { plain = true }))
	append_lines(state, { "", "Agent", "" })
	state.stream_role = "Agent"
	set_run_status(state, "connecting")
	pcall(vim.cmd, "redraw")

	local ok = state.connection:prompt_async(prompt, chat_handlers(state))

	if not ok then
		state.busy = false
		set_run_status(state, "error: failed to start session")
	end
end

function M.health(adapter_name)
	health.notify(config, adapter_name or config.default_adapter, notify)
end

function M.stop()
	local state = current_state()
	if not state then
		return
	end
	state.connection:stop()
	state.busy = false
	set_run_status(state, "stopped")
	notify("Stopped ACP agent")
end

function M.tabline()
	local parts = {}
	local current = vim.api.nvim_get_current_tabpage()

	for index, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
		local highlight = tabpage == current and "%#TabLineSel#" or "%#TabLine#"
		local title = escape_tabline(tab_title(tabpage))
		table.insert(parts, ("%s%%%dT %d:%s "):format(highlight, index, index, title))
	end

	table.insert(parts, "%#TabLineFill#%T")
	return table.concat(parts)
end

function _G.acp_nvim_completefunc(findstart, base)
	return require("acp.ui").completefunc(findstart, base)
end

function _G.acp_nvim_output_foldexpr()
	local ok, lines = pcall(vim.api.nvim_buf_get_lines, 0, 0, -1, false)
	if not ok then
		return "0"
	end
	return require("acp.output").fold_level(lines, vim.v.lnum)
end

function _G.acp_nvim_output_foldtext()
	local ok, lines = pcall(vim.api.nvim_buf_get_lines, 0, 0, -1, false)
	if not ok then
		return ""
	end
	return require("acp.output").fold_text(lines, vim.v.foldstart, vim.v.foldend)
end

return M
