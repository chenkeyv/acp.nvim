local view = require("acp.view")

local M = {}

local function present(value)
	return value ~= nil and value ~= vim.NIL
end

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function close_window(winid)
	if valid_win(winid) then
		pcall(vim.api.nvim_win_close, winid, true)
	end
end

function M.normalize(state)
	local values = type(state.pending_instructions) == "table" and state.pending_instructions or {}
	local sequence = math.max(0, tonumber(state.instruction_sequence) or 0)
	local seen = {}
	for _, instruction in ipairs(values) do
		if not present(instruction.id) or tostring(instruction.id) == "" then
			sequence = sequence + 1
			instruction.id = ("instruction:%d"):format(sequence)
		else
			instruction.id = tostring(instruction.id)
			sequence = math.max(sequence, tonumber(instruction.id:match("^instruction:(%d+)$")) or 0)
		end
		seen[instruction.id] = true
	end
	for _, envelope in ipairs(state.queue or {}) do
		local id = present(envelope._acp_instruction_id) and tostring(envelope._acp_instruction_id) or nil
		if not id then
			sequence = sequence + 1
			id = ("instruction:%d"):format(sequence)
			envelope._acp_instruction_id = id
		else
			sequence = math.max(sequence, tonumber(id:match("^instruction:(%d+)$")) or 0)
		end
		if not seen[id] then
			seen[id] = true
			table.insert(values, {
				id = id,
				kind = "queued",
				text = envelope.text or "",
			})
		end
	end
	state.pending_instructions = values
	state.instruction_sequence = sequence
	return state
end

function M.add(state, kind, envelope)
	state.instruction_sequence = (tonumber(state.instruction_sequence) or 0) + 1
	local id = ("instruction:%d"):format(state.instruction_sequence)
	envelope._acp_instruction_id = id
	local instruction = {
		id = id,
		kind = kind,
		text = envelope.text or "",
		accepted = kind ~= "steer" and nil or false,
	}
	table.insert(state.pending_instructions, instruction)
	return instruction
end

function M.accept(state, id)
	if not state or not present(id) then
		return false
	end
	id = tostring(id)
	for _, instruction in ipairs(state.pending_instructions or {}) do
		if instruction.id == id then
			instruction.accepted = true
			return true
		end
	end
	return false
end

function M.remove(state, id)
	if not state or not present(id) then
		return false
	end
	id = tostring(id)
	for index, instruction in ipairs(state.pending_instructions or {}) do
		if instruction.id == id then
			table.remove(state.pending_instructions, index)
			return true
		end
	end
	return false
end

function M.clear(state, kind)
	if not state then
		return false
	end
	local kept = {}
	local changed = false
	for _, instruction in ipairs(state.pending_instructions or {}) do
		if kind == nil or instruction.kind == kind then
			changed = true
		else
			table.insert(kept, instruction)
		end
	end
	if changed then
		state.pending_instructions = kept
	end
	return changed
end

function M.consume_steers(state)
	if not state then
		return false
	end
	local kept = {}
	local changed = false
	for _, instruction in ipairs(state.pending_instructions or {}) do
		if instruction.kind == "steer" and instruction.accepted == true then
			changed = true
		else
			table.insert(kept, instruction)
		end
	end
	if changed then
		state.pending_instructions = kept
	end
	return changed
end

local function ensure_buffer(state)
	if valid_buf(state.instruction_buf) then
		return state.instruction_buf
	end
	state.instruction_buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, state.instruction_buf, "acp://codex/instructions")
	vim.bo[state.instruction_buf].buftype = "nofile"
	vim.bo[state.instruction_buf].bufhidden = "hide"
	vim.bo[state.instruction_buf].swapfile = false
	vim.bo[state.instruction_buf].undolevels = -1
	vim.bo[state.instruction_buf].filetype = "acp-instructions"
	vim.bo[state.instruction_buf].modifiable = false
	return state.instruction_buf
end

function M.close_window(state)
	close_window(state and state.instruction_win)
	if state then
		state.instruction_win = nil
		state.instruction_chrome_key = nil
	end
end

function M.sync_window(state, output_win, desired, lines, chrome_key)
	if not desired or type(lines) ~= "table" or #lines == 0 then
		M.close_window(state)
		return
	end
	local bufnr = ensure_buffer(state)
	if state.instruction_content_key ~= chrome_key then
		local modifiable = vim.bo[bufnr].modifiable
		vim.bo[bufnr].modifiable = true
		local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modifiable = modifiable
		if not ok then
			error(err)
		end
		state.instruction_content_key = chrome_key
	end
	local current_tab = valid_win(output_win) and vim.api.nvim_win_get_tabpage(output_win) or nil
	if valid_win(state.instruction_win) and vim.api.nvim_win_get_tabpage(state.instruction_win) ~= current_tab then
		M.close_window(state)
	end
	if not valid_win(state.instruction_win) then
		state.instruction_win = vim.api.nvim_open_win(bufnr, false, desired)
	elseif
		not view.same_prompt_geometry(vim.api.nvim_win_get_config(state.instruction_win), desired)
		or state.instruction_chrome_key ~= chrome_key
	then
		vim.api.nvim_win_set_config(state.instruction_win, desired)
	end
	vim.api.nvim_win_set_buf(state.instruction_win, bufnr)
	state.instruction_chrome_key = chrome_key
	view.configure_instruction_window(state.instruction_win)
end

return M
