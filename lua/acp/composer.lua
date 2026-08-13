local view = require("acp.view")

local M = {}

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

local function ensure_turn_buffer(state)
	if valid_buf(state.instruction_buf) then
		return state.instruction_buf
	end
	state.instruction_buf = vim.api.nvim_create_buf(false, true)
	state.instruction_content_key = nil
	pcall(vim.api.nvim_buf_set_name, state.instruction_buf, "acp://codex/instructions")
	vim.bo[state.instruction_buf].buftype = "nofile"
	vim.bo[state.instruction_buf].bufhidden = "hide"
	vim.bo[state.instruction_buf].swapfile = false
	vim.bo[state.instruction_buf].undolevels = -1
	vim.bo[state.instruction_buf].filetype = "acp-instructions"
	vim.bo[state.instruction_buf].modifiable = false
	return state.instruction_buf
end

local function set_turn_content(state, lines, content_key)
	local bufnr = ensure_turn_buffer(state)
	if state.instruction_content_key == content_key then
		return bufnr
	end
	local modifiable = vim.bo[bufnr].modifiable
	vim.bo[bufnr].modifiable = true
	local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = modifiable
	if not ok then
		error(err)
	end
	state.instruction_content_key = content_key
	return bufnr
end

local function close_turn(state)
	if not state then
		return
	end
	local winid = state.instruction_win
	state.instruction_win = nil
	close_window(winid)
end

local function sync_turn(state, layout, host_win)
	local desired = layout.turn
	if not desired or type(layout.turn_lines) ~= "table" or #layout.turn_lines == 0 then
		close_turn(state)
		return
	end
	local bufnr = set_turn_content(state, layout.turn_lines, layout.turn_key)
	view.refresh_instruction(bufnr, layout.turn_highlights)
	local host_tab = vim.api.nvim_win_get_tabpage(host_win)
	if valid_win(state.instruction_win) and vim.api.nvim_win_get_tabpage(state.instruction_win) ~= host_tab then
		close_turn(state)
	end
	if not valid_win(state.instruction_win) then
		state.instruction_win = vim.api.nvim_open_win(bufnr, false, desired)
	elseif not view.same_float_geometry(vim.api.nvim_win_get_config(state.instruction_win), desired) then
		vim.api.nvim_win_set_config(state.instruction_win, desired)
	end
	vim.api.nvim_win_set_buf(state.instruction_win, bufnr)
	view.configure_instruction_window(state.instruction_win)
end

local function apply(state, host_win, opts, create)
	if not state or not valid_win(host_win) or not valid_buf(state.input_buf) then
		return nil
	end
	local layout = view.stack_layout(host_win, state, opts)
	if not layout then
		return nil
	end
	local geometry_changed = false
	if not valid_win(state.input_win) then
		if not create then
			return nil
		end
		state.input_win = vim.api.nvim_open_win(state.input_buf, true, layout.prompt)
		state.prompt_chrome_key = layout.prompt_key
		geometry_changed = true
	else
		local current = vim.api.nvim_win_get_config(state.input_win)
		geometry_changed = not view.same_float_geometry(current, layout.prompt)
		if geometry_changed or state.prompt_chrome_key ~= layout.prompt_key then
			vim.api.nvim_win_set_config(state.input_win, layout.prompt)
			state.prompt_chrome_key = layout.prompt_key
		end
	end
	vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
	view.configure_prompt_window(state.input_win)
	sync_turn(state, layout, host_win)
	return {
		layout = layout,
		geometry_changed = geometry_changed,
	}
end

function M.open(state, host_win, opts)
	return apply(state, host_win, opts, true)
end

function M.sync(state, host_win, opts)
	return apply(state, host_win, opts, false)
end

function M.refresh_turn(state, host_win, opts)
	if not M.is_open(state, host_win) then
		return false
	end
	local layout = view.stack_layout(host_win, state, opts)
	if not layout or not layout.turn then
		close_turn(state)
		return false
	end
	sync_turn(state, layout, host_win)
	return true
end

function M.is_open(state, host_win)
	if not state or not valid_win(state.input_win) or not view.is_floating(state.input_win) then
		return false
	end
	return not valid_win(host_win)
		or vim.api.nvim_win_get_tabpage(state.input_win) == vim.api.nvim_win_get_tabpage(host_win)
end

function M.handle_win_closed(state, winid)
	if not state then
		return nil
	end
	winid = tonumber(winid)
	if winid == state.input_win then
		state.input_win = nil
		state.prompt_chrome_key = nil
		close_turn(state)
		return "prompt"
	elseif winid == state.instruction_win then
		state.instruction_win = nil
		return "turn"
	end
end

function M.close(state)
	if not state then
		return
	end
	local prompt_win = state.input_win
	state.input_win = nil
	state.prompt_chrome_key = nil
	close_turn(state)
	close_window(prompt_win)
end

return M
