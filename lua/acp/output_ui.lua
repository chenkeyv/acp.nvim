local chat_blocks = require("acp.blocks")
local icons = require("acp.icons")
local output = require("acp.output")
local treesitter = require("acp.treesitter")

local M = {}

local visual_ns = vim.api.nvim_create_namespace("acp.nvim.output.visual")
local current_ns = vim.api.nvim_create_namespace("acp.nvim.output.current")
local pulse_ns = vim.api.nvim_create_namespace("acp.nvim.output.pulse")

M.namespaces = {
	visual = visual_ns,
	current = current_ns,
	pulse = pulse_ns,
}

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Codex output" })
end

local function transcript_lines(state)
	if not state or not valid_buf(state.output_buf) then
		return {}
	end
	return vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false)
end

local function output_cursor(state)
	if not state or not valid_win(state.output_win) then
		return { 1, 0 }
	end
	return vim.api.nvim_win_get_cursor(state.output_win)
end

local function cache_is_current(state)
	local cache = state and state.output_cache
	return cache
		and valid_buf(state.output_buf)
		and cache.bufnr == state.output_buf
		and cache.changedtick == vim.api.nvim_buf_get_changedtick(state.output_buf)
		and cache.cwd == state.cwd
		and cache.model == state.chat
		and cache.model_revision == (state.chat and state.chat.revision or nil)
end

local function structured_semantics(state)
	local chat = state and state.chat
	if chat and chat.semantic_data then
		return chat:semantic_data(state.cwd)
	end
end

local function items_for_state(state)
	if cache_is_current(state) then
		return state.output_cache.items or {}
	end
	local semantic = structured_semantics(state)
	if semantic then
		return output.output_items({
			total_lines = semantic.total_lines,
			references = semantic.references,
			blocks = semantic.code_blocks,
			diagnostics = semantic.diagnostics,
			activities = semantic.activities,
		})
	end
	return {}
end

local function code_blocks_for_state(state)
	if state and state.chat and state.chat.code_blocks then
		return state.chat:code_blocks()
	end
	return {}
end

local function code_block_at_state(state, line)
	if state and state.chat and state.chat.code_block_at then
		return state.chat:code_block_at(line)
	end
end

local function references_for_state(state)
	if state and state.chat and state.chat.references then
		return state.chat:references(state.cwd)
	end
	return {}
end

local function diagnostics_for_state(state)
	if state and state.chat and state.chat.diagnostics then
		return state.chat:diagnostics()
	end
	return {}
end

local function cached_item_at(state, line, col, prefer_activity)
	local cache = state and state.output_cache
	if not cache then
		return nil
	end
	line = tonumber(line) or 1
	col = (tonumber(col) or 0) + 1
	local total = #(cache.items or {})
	local index = cache.item_index or {}
	local references = (index.references or {})[line] or {}
	local function result(entry)
		return entry and vim.tbl_extend("force", {}, entry.item, { index = entry.index, total = total }) or nil
	end
	if prefer_activity then
		local activity = result((index.activity or {})[line])
		if activity then
			return activity
		end
	end

	for _, entry in ipairs(references) do
		local item = entry.item
		if col >= (item.col or 1) and col <= (item.end_col or item.col or 1) + 1 then
			return result(entry)
		end
	end
	return result((index.activity or {})[line])
		or result(references[1])
		or result((index.code or {})[line])
		or result((index.problem or {})[line])
end

local function item_at(items, line, col, prefer_activity)
	line = tonumber(line) or 1
	col = (tonumber(col) or 0) + 1
	local activity
	local code
	local problem
	local reference
	local exact_reference
	for index, item in ipairs(items or {}) do
		local line1 = item.line or 1
		local line2 = item.line2 or line1
		if line >= line1 and line <= line2 then
			local value = vim.tbl_extend("force", {}, item, { index = index, total = #items })
			if item.kind == "activity" then
				activity = activity or value
			elseif item.kind == "code" then
				code = code or value
			elseif item.kind == "problem" and line == line1 then
				problem = problem or value
			elseif item.kind == "reference" and line == line1 then
				reference = reference or value
				if col >= (item.col or 1) and col <= (item.end_col or item.col or 1) + 1 then
					exact_reference = value
				end
			end
		end
	end
	return prefer_activity and activity or exact_reference or activity or reference or code or problem
end

local function jump_output(state, line, col)
	if not state or not valid_win(state.output_win) or not valid_buf(state.output_buf) then
		notify("The Codex output window is not visible", vim.log.levels.WARN)
		return false
	end
	vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(state.output_win))
	vim.api.nvim_set_current_win(state.output_win)
	local count = vim.api.nvim_buf_line_count(state.output_buf)
	line = math.max(1, math.min(tonumber(line) or 1, count))
	local text = vim.api.nvim_buf_get_lines(state.output_buf, line - 1, line, false)[1] or ""
	col = math.max(0, math.min((tonumber(col) or 1) - 1, #text))
	vim.api.nvim_win_set_cursor(state.output_win, { line, col })
	pcall(vim.cmd, "normal! zz")
	M.cursor_moved(state)
	return true
end

local function select_items(items, prompt, format_item, callback)
	if #(items or {}) == 0 then
		notify((prompt or "Codex output") .. " has no entries", vim.log.levels.WARN)
		return false
	end
	vim.ui.select(items, {
		prompt = prompt,
		format_item = format_item,
	}, function(choice)
		if choice then
			callback(choice)
		end
	end)
	return true
end

local function item_label(item)
	return ("%s %4d  %-9s  %s"):format(
		item.kind == "problem" and icons.error
			or item.kind == "reference" and icons.reference
			or item.kind == "code" and icons.code
			or item.kind == "activity" and icons.command
			or icons.section,
		item.line or 1,
		(item.kind or "item"):upper(),
		item.label or ""
	)
end

local function reference_at_item(state, item)
	if cache_is_current(state) then
		for _, reference in ipairs(state.output_cache.references or {}) do
			if reference.source_line == item.line and reference.source_col == item.col then
				return reference
			end
		end
	end
	for _, reference in ipairs(references_for_state(state)) do
		if reference.source_line == item.line and reference.source_col == item.col then
			return reference
		end
	end
end

local function block_at_item(state, item)
	if cache_is_current(state) then
		for _, block in ipairs(state.output_cache.blocks or {}) do
			if block.start_line == item.line then
				return block
			end
		end
	end
	return code_block_at_state(state, item.line or output_cursor(state)[1])
end

local function preview_file(reference)
	if not reference or not reference.path then
		return nil
	end
	local target = math.max(1, tonumber(reference.line) or 1)
	local first = math.max(1, target - 5)
	local last = target + 5
	local file_lines = vim.fn.readfile(reference.path, "", last)
	local lines = {}
	for index = first, math.min(last, #file_lines) do
		local marker = index == target and icons.location or " "
		table.insert(lines, ("%s %4d  %s"):format(marker, index, file_lines[index] or ""))
	end
	return {
		lines = lines,
		filetype = vim.filetype.match({ filename = reference.path }) or "text",
		title = (" %s %s:%d "):format(icons.reference, reference.display_path or reference.path, target),
		cursor_line = math.max(1, target - first + 1),
	}
end

local function preview_output_line(state, item)
	local lines = transcript_lines(state)
	if #lines == 0 then
		return nil
	end
	local line = math.max(1, math.min(tonumber(item and item.line) or 1, #lines))
	local line1 = math.max(1, line - 5)
	local line2 = math.min(#lines, line + 5)
	local preview = {}
	for index = line1, line2 do
		local marker = index == line and icons.location or icons.pulse_empty
		table.insert(preview, ("%s %4d  %s"):format(marker, index, lines[index] or ""))
	end
	return {
		lines = preview,
		filetype = "acp",
		title = (" %s Codex output line %d "):format(icons.map, line),
		cursor_line = line - line1 + 1,
	}
end

local function preview_for_item(state, item)
	if item.kind == "reference" then
		return preview_file(reference_at_item(state, item))
	elseif item.kind == "code" then
		local block = block_at_item(state, item)
		if block then
			return {
				lines = block.lines,
				filetype = block.filetype or "text",
				title = (" %s %s code lines %d-%d "):format(
					icons.code,
					block.language or "text",
					block.start_line or 1,
					block.end_line or 1
				),
				cursor_line = 1,
			}
		end
	elseif item.kind == "activity" and state.chat and state.chat.section_lines then
		local lines = state.chat.activity_detail_lines and state.chat:activity_detail_lines(item.line)
			or state.chat:section_lines(item.line, { trim_blank = false })
		if lines then
			return {
				lines = lines,
				filetype = "acp",
				title = (" %s Activity · %d completed "):format(icons.command, item.count or #lines),
				cursor_line = 1,
			}
		end
	elseif item.kind == "section" and state.chat and state.chat.section_lines then
		local lines = state.chat:section_lines(item.line, { trim_blank = false })
		local section = state.chat:section_at(item.line)
		if lines and section then
			return {
				lines = lines,
				filetype = "acp",
				title = (" %s %s "):format(icons.section, section.title or section.kind or "Output"),
				cursor_line = 1,
			}
		end
	end
	return preview_output_line(state, item)
end

local function open_preview(preview)
	if not preview or #(preview.lines or {}) == 0 then
		notify("No output preview is available", vim.log.levels.WARN)
		return false
	end
	local bufnr, winid = vim.lsp.util.open_floating_preview(preview.lines, preview.filetype or "acp", {
		border = "rounded",
		focusable = true,
		max_height = math.max(6, math.floor(vim.o.lines * 0.55)),
		max_width = math.max(48, math.floor(vim.o.columns * 0.68)),
		title = preview.title,
	})
	if valid_win(winid) then
		vim.wo[winid].cursorline = true
		pcall(vim.api.nvim_win_set_cursor, winid, { math.max(1, preview.cursor_line or 1), 0 })
	end
	if valid_buf(bufnr) then
		vim.keymap.set("n", "q", function()
			if valid_win(winid) then
				vim.api.nvim_win_close(winid, true)
			end
		end, { buffer = bufnr, silent = true, desc = "Close Codex output preview" })
	end
	return true
end

local function open_reference(reference)
	if not reference or not reference.path then
		notify("No local file reference is under the cursor", vim.log.levels.WARN)
		return false
	end
	vim.cmd("tabedit " .. vim.fn.fnameescape(reference.path))
	pcall(vim.api.nvim_win_set_cursor, 0, { reference.line or 1, math.max(0, (reference.column or 1) - 1) })
	pcall(vim.cmd, "normal! zz")
	return true
end

local function close_scratch(tabpage, return_tab, return_win)
	if vim.api.nvim_tabpage_is_valid(tabpage) and #vim.api.nvim_list_tabpages() > 1 then
		vim.api.nvim_set_current_tabpage(tabpage)
		vim.cmd("tabclose")
	end
	if return_tab and vim.api.nvim_tabpage_is_valid(return_tab) then
		vim.api.nvim_set_current_tabpage(return_tab)
	end
	if valid_win(return_win) then
		vim.api.nvim_set_current_win(return_win)
	end
end

local function yank_text(text, label)
	if not text or text == "" then
		notify("There is no output text to yank", vim.log.levels.WARN)
		return false
	end
	vim.fn.setreg('"', text)
	notify(("Yanked %s"):format(label or "Codex output"))
	return true
end

local function pulse_range(state, range, badge)
	if not state or not valid_buf(state.output_buf) or not range then
		return
	end
	state.output_pulse_id = (state.output_pulse_id or 0) + 1
	local pulse_id = state.output_pulse_id
	local frames = { "AcpOutputPulseSoft", "AcpOutputPulse", "AcpOutputPulseSoft" }
	local function draw(frame)
		if state.output_pulse_id ~= pulse_id or not valid_buf(state.output_buf) then
			return
		end
		vim.api.nvim_buf_clear_namespace(state.output_buf, pulse_ns, 0, -1)
		local highlight = frames[frame]
		if not highlight then
			return
		end
		for line = range.line1, range.line2 do
			local opts = { line_hl_group = highlight, priority = 95 }
			if line == range.line1 then
				opts.virt_text = { { (" %s %s "):format(icons.yank, badge or "YANKED"), "AcpBadge" } }
				opts.virt_text_pos = "right_align"
			end
			pcall(vim.api.nvim_buf_set_extmark, state.output_buf, pulse_ns, line - 1, 0, opts)
		end
		vim.defer_fn(function()
			draw(frame + 1)
		end, 90)
	end
	draw(1)
end

local append_prompt

local function open_code_block(state, block)
	if not block then
		notify("No fenced code block is under the cursor", vim.log.levels.WARN)
		return false
	end
	local return_tab = valid_win(state.output_win) and vim.api.nvim_win_get_tabpage(state.output_win) or nil
	local return_win = state.output_win
	vim.cmd("tabnew")
	local tabpage = vim.api.nvim_get_current_tabpage()
	local winid = vim.api.nvim_get_current_win()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(winid, bufnr)
	pcall(vim.api.nvim_buf_set_name, bufnr, ("acp://codex/code/%s"):format(tostring(vim.uv.hrtime())))
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = block.filetype or "text"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, block.lines or { "" })
	vim.bo[bufnr].modifiable = false
	vim.wo[winid].number = true
	vim.wo[winid].cursorline = true
	vim.wo[winid].winbar = (" %s %s code · <leader>ai draft scope · <leader>aY yank · gO output · q close ")
		:format(icons.code, block.language or "text")
		:gsub("%%", "%%%%")
	pcall(vim.treesitter.start, bufnr, block.filetype or "text")
	local function close()
		close_scratch(tabpage, return_tab, return_win)
	end
	vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true, desc = "Close Codex code block" })
	vim.keymap.set("n", "gO", close, { buffer = bufnr, silent = true, desc = "Return to Codex output" })
	vim.keymap.set("n", "<leader>aY", function()
		yank_text(output.code_block_text(block), "code block")
	end, { buffer = bufnr, silent = true, desc = "Yank Codex code block" })
	vim.keymap.set("n", "<leader>ai", function()
		local text = output.code_block_text(block) or ""
		local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr })
		if ok and node then
			local node_ok, node_text = pcall(vim.treesitter.get_node_text, node, bufnr)
			if node_ok and type(node_text) == "string" and node_text ~= "" then
				text = node_text
			end
		end
		local drafted = append_prompt(
			state,
			("Use this %s scope as follow-up context:\n\n```%s\n%s\n```"):format(
				block.language or "code",
				block.language or "",
				text
			)
		)
		if drafted then
			close()
		end
	end, { buffer = bufnr, silent = true, desc = "Draft Codex code scope" })
	return true
end

append_prompt = function(state, text)
	if not state or not valid_buf(state.input_buf) or not text or text == "" then
		return false
	end
	local additions = vim.split(text, "\n", { plain = true })
	local current = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
	if #current == 1 and current[1] == "" then
		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, additions)
	else
		vim.api.nvim_buf_set_lines(state.input_buf, -1, -1, false, vim.list_extend({ "" }, additions))
	end
	if valid_win(state.input_win) then
		vim.api.nvim_set_current_win(state.input_win)
		local count = vim.api.nvim_buf_line_count(state.input_buf)
		local line = vim.api.nvim_buf_get_lines(state.input_buf, count - 1, count, false)[1] or ""
		vim.api.nvim_win_set_cursor(state.input_win, { count, #line })
	end
	return true
end

local function set_quickfix(items, title)
	if #(items or {}) == 0 then
		notify((title or "Codex output") .. " has no entries", vim.log.levels.WARN)
		return false
	end
	vim.fn.setqflist({}, " ", { title = title or "Codex output", items = items })
	vim.cmd("copen")
	return true
end

function M.jump_section(state, direction)
	local cursor = output_cursor(state)
	local line
	local sections = state.chat and state.chat.sections and state.chat:sections() or {}
	if direction < 0 then
		for index = #sections, 1, -1 do
			if sections[index].line < cursor[1] then
				line = sections[index].line
				break
			end
		end
	else
		for _, section in ipairs(sections) do
			if section.line > cursor[1] then
				line = section.line
				break
			end
		end
	end
	if not line then
		notify(direction < 0 and "No previous output section" or "No next output section")
		return false
	end
	return jump_output(state, line, 1)
end

function M.jump_item(state, direction)
	local cursor = output_cursor(state)
	direction = tonumber(direction) or 1
	local item
	local items = items_for_state(state)
	if direction < 0 then
		for index = #items, 1, -1 do
			if (items[index].line or 1) < cursor[1] then
				item = items[index]
				break
			end
		end
	else
		for _, candidate in ipairs(items) do
			if (candidate.line or 1) > cursor[1] then
				item = candidate
				break
			end
		end
	end
	if not item then
		notify(direction < 0 and "No previous output item" or "No next output item")
		return false
	end
	return jump_output(state, item.line, item.col)
end

function M.current_item(state)
	local cursor = output_cursor(state)
	local prefer_activity = false
	if valid_win(state and state.output_win) then
		local ok, fold_start = pcall(vim.api.nvim_win_call, state.output_win, function()
			return vim.fn.foldclosed(cursor[1])
		end)
		prefer_activity = ok and fold_start ~= -1
	end
	if cache_is_current(state) then
		return cached_item_at(state, cursor[1], cursor[2], prefer_activity)
	end
	return item_at(items_for_state(state), cursor[1], cursor[2], prefer_activity)
end

function M.open_current(state)
	local item = M.current_item(state)
	if not item then
		return M.inspect(state)
	elseif item.kind == "reference" then
		return open_reference(reference_at_item(state, item))
	elseif item.kind == "code" then
		return open_code_block(state, block_at_item(state, item))
	end
	return open_preview(preview_for_item(state, item))
end

function M.open_reference(state)
	local cursor = output_cursor(state)
	local reference
	for _, candidate in ipairs(references_for_state(state)) do
		if candidate.source_line == cursor[1] then
			reference = reference or candidate
			local col = cursor[2] + 1
			if
				col >= (candidate.source_col or 1)
				and col <= (candidate.source_end_col or candidate.source_col or 1) + 1
			then
				reference = candidate
				break
			end
		end
	end
	return open_reference(reference)
end

function M.inspect(state, item)
	item = item or M.current_item(state)
	if item then
		return open_preview(preview_for_item(state, item))
	end
	local cursor = output_cursor(state)
	if state.chat and state.chat.section_lines then
		local lines = state.chat:section_lines(cursor[1])
		local section = state.chat:section_at(cursor[1])
		if lines and section then
			return open_preview({
				lines = lines,
				filetype = "acp",
				title = (" %s %s "):format(icons.section, section.title or section.kind or "Output"),
				cursor_line = 1,
			})
		end
		notify("No output item or section is under the cursor", vim.log.levels.WARN)
		return false
	end
	notify("No output item or section is under the cursor", vim.log.levels.WARN)
	return false
end

function M.open_outline(state)
	local sections = state.chat and state.chat.sections and state.chat:sections() or {}
	return select_items(sections, "Codex output outline", function(section)
		return ("%s %4d  %-9s  %s"):format(icons.section, section.line, section.kind, section.title)
	end, function(section)
		jump_output(state, section.line, 1)
	end)
end

function M.search(state)
	local entries = state.chat and state.chat.entries and state.chat:entries() or {}
	return select_items(entries, "Search Codex output", function(entry)
		return ("%4d  %-9s  %s"):format(entry.line or 1, entry.kind or "TEXT", entry.text or "")
	end, function(entry)
		jump_output(state, entry.line, 1)
	end)
end

function M.open_items(state)
	local items = items_for_state(state)
	return select_items(items, "Codex output items", item_label, function(item)
		jump_output(state, item.line, item.col)
	end)
end

function M.items_quickfix(state)
	local items = items_for_state(state)
	return set_quickfix(output.output_item_quickfix_items(items, state.output_buf), "Codex output items")
end

function M.open_code_blocks(state)
	local blocks = code_blocks_for_state(state)
	return select_items(blocks, "Codex code blocks", function(block)
		return ("%s %4d-%-4d  %-12s  %d lines"):format(
			icons.code,
			block.start_line or 1,
			block.end_line or 1,
			block.language or "text",
			block.line_count or 0
		)
	end, function(block)
		open_code_block(state, block)
	end)
end

function M.code_blocks_quickfix(state)
	local blocks = code_blocks_for_state(state)
	return set_quickfix(output.code_block_quickfix_items(blocks, state.output_buf), "Codex code blocks")
end

function M.yank_code_block(state)
	local block = code_block_at_state(state, output_cursor(state)[1])
	local yanked = yank_text(output.code_block_text(block), "code block")
	if yanked and block then
		pulse_range(state, { line1 = block.start_line, line2 = block.end_line }, "CODE YANKED")
	end
	return yanked
end

function M.draft_code_block(state)
	local block = code_block_at_state(state, output_cursor(state)[1])
	if not block then
		notify("No fenced code block is under the cursor", vim.log.levels.WARN)
		return false
	end
	local text = ("Use this code block as follow-up context:\n\n```%s\n%s\n```"):format(
		block.language or "",
		output.code_block_text(block) or ""
	)
	return append_prompt(state, text)
end

function M.open_locations(state)
	local references = references_for_state(state)
	return select_items(references, "Codex output locations", function(reference)
		return ("%s %s:%d:%d"):format(
			icons.reference,
			reference.display_path or reference.path,
			reference.line or 1,
			reference.column or 1
		)
	end, open_reference)
end

function M.locations_quickfix(state)
	local references = references_for_state(state)
	return set_quickfix(output.file_reference_quickfix_items(references), "Codex output locations")
end

function M.open_problems(state)
	local diagnostics = diagnostics_for_state(state)
	local items = {}
	for _, diagnostic in ipairs(diagnostics) do
		table.insert(items, {
			bufnr = state.output_buf,
			lnum = (diagnostic.lnum or 0) + 1,
			col = (diagnostic.col or 0) + 1,
			text = diagnostic.message,
			type = diagnostic.severity == vim.diagnostic.severity.WARN and "W" or "E",
		})
	end
	if #items == 0 then
		notify("Codex output has no problems", vim.log.levels.WARN)
		return false
	end
	vim.fn.setloclist(state.output_win or 0, {}, " ", { title = "Codex output problems", items = items })
	if valid_win(state.output_win) then
		vim.api.nvim_set_current_win(state.output_win)
	end
	vim.cmd("lopen")
	return true
end

function M.yank_section(state)
	local line = output_cursor(state)[1]
	local text, range = state.chat and state.chat.section_text and state.chat:section_text(line)
	local yanked = yank_text(text, "output section")
	if yanked then
		pulse_range(state, range, "SECTION YANKED")
	end
	return yanked
end

function M.draft_section(state)
	local line = output_cursor(state)[1]
	local text = state.chat and state.chat.section_text and state.chat:section_text(line)
	if not text then
		notify("No output section is under the cursor", vim.log.levels.WARN)
		return false
	end
	return append_prompt(state, "Use this transcript section as follow-up context:\n\n" .. text)
end

local function close_map(state)
	if valid_win(state.output_map_win) then
		vim.api.nvim_win_close(state.output_map_win, true)
	end
	state.output_map_win = nil
	pcall(vim.cmd, "redraw")
	if type(state._sync_composer) == "function" then
		state._sync_composer()
	end
end

local function map_entry(state)
	if not valid_win(state.output_map_win) then
		return nil
	end
	local row = vim.api.nvim_win_get_cursor(state.output_map_win)[1]
	return state.output_map_rows and state.output_map_rows[row] or nil
end

function M.refresh_map(state, force)
	if not state or not valid_buf(state.output_map_buf) or (not force and not valid_win(state.output_map_win)) then
		return
	end
	local cursor = output_cursor(state)
	local cache = state.output_cache
	local entries
	local total_lines
	if cache then
		entries = cache.entries or {}
		total_lines = cache.total_lines or 0
	else
		total_lines = state.chat.line_count or 0
		entries = output.output_map_entries({
			total_lines = total_lines,
			sections = state.chat:sections(),
			items = items_for_state(state),
		})
	end
	local map_lines, rows = output.output_map_lines(entries, {
		current_line = cursor[1],
		total_lines = total_lines,
		bar_width = 8,
	})
	state.output_map_rows = rows
	vim.bo[state.output_map_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.output_map_buf, 0, -1, false, map_lines)
	vim.bo[state.output_map_buf].modifiable = false
end

function M.open_map(state)
	if not state or not valid_win(state.output_win) then
		notify("The Codex output window is not visible", vim.log.levels.WARN)
		return false
	end
	if not valid_buf(state.output_map_buf) then
		state.output_map_buf = vim.api.nvim_create_buf(false, true)
		pcall(vim.api.nvim_buf_set_name, state.output_map_buf, "acp://codex/output-map")
		vim.bo[state.output_map_buf].buftype = "nofile"
		vim.bo[state.output_map_buf].bufhidden = "hide"
		vim.bo[state.output_map_buf].swapfile = false
		vim.bo[state.output_map_buf].filetype = "acp-output-map"
		vim.bo[state.output_map_buf].modifiable = false
		local opts = { buffer = state.output_map_buf, silent = true }
		vim.keymap.set("n", "q", function()
			close_map(state)
		end, vim.tbl_extend("force", opts, { desc = "Close Codex output map" }))
		vim.keymap.set("n", "<Esc>", function()
			close_map(state)
		end, vim.tbl_extend("force", opts, { desc = "Close Codex output map" }))
		vim.keymap.set("n", "<CR>", function()
			local entry = map_entry(state)
			if entry then
				jump_output(state, entry.line, entry.col)
			end
		end, vim.tbl_extend("force", opts, { desc = "Jump to Codex output map entry" }))
		vim.keymap.set("n", "K", function()
			local entry = map_entry(state)
			if entry then
				open_preview(preview_for_item(state, entry))
			end
		end, vim.tbl_extend("force", opts, { desc = "Preview Codex output map entry" }))
		vim.keymap.set("n", "Q", function()
			local entries = state.output_cache and state.output_cache.entries
			if not entries then
				entries = output.output_map_entries({
					total_lines = state.chat.line_count,
					sections = state.chat:sections(),
					items = items_for_state(state),
				})
			end
			set_quickfix(output.output_map_quickfix_items(entries, state.output_buf), "Codex output map")
		end, vim.tbl_extend("force", opts, { desc = "Send Codex output map to quickfix" }))
	end
	if not cache_is_current(state) then
		M.flush_refresh(state)
	end
	M.refresh_map(state, true)
	if valid_win(state.output_map_win) then
		vim.api.nvim_set_current_win(state.output_map_win)
		return true
	end
	local output_width = vim.api.nvim_win_get_width(state.output_win)
	local width = math.min(math.max(3, output_width - 2), math.min(64, math.max(28, math.floor(output_width * 0.62))))
	local height = math.min(24, math.max(6, vim.api.nvim_buf_line_count(state.output_map_buf)))
	height = math.min(height, math.max(3, vim.api.nvim_win_get_height(state.output_win) - 2))
	state.output_map_win = vim.api.nvim_open_win(state.output_map_buf, true, {
		relative = "win",
		win = state.output_win,
		anchor = "NE",
		row = 1,
		col = output_width - 1,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = (" %s Output map "):format(icons.map),
		title_pos = "left",
		zindex = 60,
	})
	vim.wo[state.output_map_win].cursorline = true
	vim.wo[state.output_map_win].wrap = false
	pcall(vim.cmd, "redraw")
	if type(state._sync_composer) == "function" then
		state._sync_composer()
	end
	return true
end

function M.actions(state)
	local item = M.current_item(state)
	local cache = state.output_cache
	local semantic = not cache and structured_semantics(state) or nil
	local stats = cache
			and {
				sections = #(cache.sections or {}),
				code_blocks = #(cache.blocks or {}),
				locations = #(cache.references or {}),
			}
		or semantic and {
			sections = #(semantic.sections or {}),
			code_blocks = #(semantic.code_blocks or {}),
			locations = #(semantic.references or {}),
		}
		or { sections = 0, code_blocks = 0, locations = 0 }
	local actions = {
		{ label = "Search transcript", run = M.search },
		{ label = "Open output map", run = M.open_map },
		{ label = "Open output outline", run = M.open_outline },
		{ label = "Open output items", run = M.open_items },
		{ label = "Yank current section", run = M.yank_section },
		{ label = "Draft current section", run = M.draft_section },
		{ label = "Open code blocks", run = M.open_code_blocks },
		{ label = "Open file references", run = M.open_locations },
		{ label = "Open output problems", run = M.open_problems },
	}
	if item then
		table.insert(actions, 1, { label = "Inspect current " .. item.kind, run = M.inspect })
		table.insert(actions, 2, { label = "Open current " .. item.kind, run = M.open_current })
		if item.kind == "code" then
			table.insert(actions, 3, { label = "Yank current code block", run = M.yank_code_block })
			table.insert(actions, 4, { label = "Draft current code block", run = M.draft_code_block })
		end
	end
	local prompt = ("Codex output · %d sections · %d code · %d refs"):format(
		stats.sections or 0,
		stats.code_blocks or 0,
		stats.locations or 0
	)
	return select_items(actions, prompt, function(action)
		return ("%s %s"):format(icons.action, action.label)
	end, function(action)
		action.run(state)
	end)
end

function M.help(state)
	return M.actions(state)
end

local function stop_refresh_timer(state, close)
	local timer = state and state.output_refresh_timer
	if not timer then
		return
	end
	pcall(timer.stop, timer)
	if close then
		local closing = false
		pcall(function()
			closing = timer:is_closing()
		end)
		if not closing then
			pcall(timer.close, timer)
		end
		state.output_refresh_timer = nil
	end
end

function M.pause_language_injection(state)
	if not state or not valid_buf(state.output_buf) or not state.output_language_injection then
		return
	end
	treesitter.stop(state.output_buf)
	state.output_language_injection = false
	state.output_language_injection_tried = false
	vim.b[state.output_buf].acp_language_injection = "paused"
end

function M.schedule_refresh(state, delay_ms)
	if not state or not valid_buf(state.output_buf) then
		return
	end
	local uv = vim.uv or vim.loop
	if not uv or not uv.new_timer then
		vim.schedule(function()
			if not state.busy then
				M.refresh(state)
			end
		end)
		return
	end
	local timer = state.output_refresh_timer
	if not timer then
		timer = uv.new_timer()
		state.output_refresh_timer = timer
	end
	state.output_refresh_pending = true
	pcall(timer.stop, timer)
	timer:start(
		math.max(1, tonumber(delay_ms) or 200),
		0,
		vim.schedule_wrap(function()
			if state.output_refresh_timer ~= timer or not state.output_refresh_pending then
				return
			end
			if state.busy then
				return
			end
			state.output_refresh_pending = false
			M.refresh(state)
		end)
	)
end

function M.flush_refresh(state)
	if not state or not valid_buf(state.output_buf) then
		return
	end
	stop_refresh_timer(state, false)
	state.output_refresh_pending = false
	M.refresh(state)
end

local function refresh_current(state)
	if not state or not valid_buf(state.output_buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(state.output_buf, current_ns, 0, -1)
	if not valid_win(state.output_win) then
		return
	end
	local cursor = output_cursor(state)
	local item = cached_item_at(state, cursor[1], cursor[2])
	if item then
		local line1 = item.kind == "activity" and cursor[1] or item.line or cursor[1]
		local line2 = item.kind == "activity" and line1 or item.line2 or item.line or cursor[1]
		for line = line1, line2 do
			pcall(vim.api.nvim_buf_set_extmark, state.output_buf, current_ns, line - 1, 0, {
				line_hl_group = "AcpCurrentItem",
				priority = 20,
			})
		end
	end
end

local function build_item_index(items)
	local index = { references = {}, activity = {}, code = {}, problem = {} }
	for item_index, item in ipairs(items or {}) do
		local entry = { item = item, index = item_index }
		if item.kind == "reference" then
			local line = item.line or 1
			index.references[line] = index.references[line] or {}
			table.insert(index.references[line], entry)
		elseif item.kind == "activity" or item.kind == "code" then
			for line = item.line or 1, item.line2 or item.line or 1 do
				index[item.kind][line] = entry
			end
		elseif item.kind == "problem" then
			index.problem[item.line or 1] = entry
		end
	end
	return index
end

function M.refresh(state)
	if not state or not valid_buf(state.output_buf) then
		return
	end
	stop_refresh_timer(state, false)
	state.output_refresh_pending = false
	local bufnr = state.output_buf
	vim.b[bufnr].acp_cwd = state.cwd
	if not state.busy and not state.output_language_injection_tried then
		state.output_language_injection_tried = true
		local active, mode = treesitter.start(bufnr)
		state.output_language_injection = active
		vim.b[bufnr].acp_language_injection = mode
	end
	if cache_is_current(state) then
		refresh_current(state)
		M.refresh_map(state)
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, visual_ns, 0, -1)

	local semantic = structured_semantics(state)
	if not semantic then
		state.output_cache = nil
		return
	end
	local references = semantic.references
	local blocks = semantic.code_blocks
	local diagnostics = semantic.diagnostics
	local sections = semantic.sections
	local activities = semantic.activities
	local total_lines = semantic.total_lines
	local items = output.output_items({
		total_lines = total_lines,
		references = references,
		blocks = blocks,
		diagnostics = diagnostics,
		activities = activities,
	})
	local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
	state.output_cache = {
		bufnr = bufnr,
		changedtick = changedtick,
		cwd = state.cwd,
		model = state.chat,
		model_revision = state.chat and state.chat.revision or nil,
		total_lines = total_lines,
		references = references,
		blocks = blocks,
		diagnostics = diagnostics,
		sections = sections,
		activities = activities,
		chat_blocks = state.chat.blocks,
		items = items,
		item_index = build_item_index(items),
		entries = output.output_map_entries({
			total_lines = total_lines,
			sections = sections,
			items = items,
		}),
	}
	for _, reference in ipairs(references) do
		local row = (reference.source_line or 1) - 1
		pcall(vim.api.nvim_buf_set_extmark, bufnr, visual_ns, row, math.max(0, (reference.source_col or 1) - 1), {
			end_col = math.max(reference.source_col or 1, reference.source_end_col or reference.source_col or 1),
			hl_group = "AcpOutputReference",
			priority = 82,
		})
	end

	for _, block in ipairs(blocks) do
		local first = block.start_line + 1
		local last = block.closed and block.end_line - 1 or block.end_line
		for line = first, last do
			pcall(vim.api.nvim_buf_set_extmark, bufnr, visual_ns, line - 1, 0, {
				line_hl_group = "AcpInjectedCode",
				priority = 8,
			})
		end
	end

	refresh_current(state)
	M.refresh_map(state)
end

function M.cursor_moved(state)
	refresh_current(state)
	M.refresh_map(state)
end

function M.close(state)
	if not state then
		return
	end
	stop_refresh_timer(state, true)
	state.output_refresh_pending = false
	M.pause_language_injection(state)
	close_map(state)
	if valid_buf(state.output_map_buf) then
		vim.api.nvim_buf_delete(state.output_map_buf, { force = true })
	end
	state.output_map_buf = nil
	state.output_map_rows = nil
	state.output_cache = nil
	if valid_buf(state.output_buf) then
		vim.api.nvim_buf_clear_namespace(state.output_buf, visual_ns, 0, -1)
		vim.api.nvim_buf_clear_namespace(state.output_buf, current_ns, 0, -1)
		vim.api.nvim_buf_clear_namespace(state.output_buf, pulse_ns, 0, -1)
	end
	if type(state._sync_composer) == "function" then
		state._sync_composer()
	end
end

_G.acp_nvim_output_foldexpr = function()
	local lnum = vim.v.lnum
	local chat = chat_blocks.for_buffer(vim.api.nvim_get_current_buf())
	local structural = chat and chat.fold_level and chat:fold_level(lnum) or nil
	return structural or "0"
end

_G.acp_nvim_output_foldtext = function()
	local bufnr = vim.api.nvim_get_current_buf()
	local chat = chat_blocks.for_buffer(bufnr)
	local structural = chat and chat.fold_text and chat:fold_text(vim.v.foldstart, vim.v.foldend) or nil
	return structural or ""
end

return M
