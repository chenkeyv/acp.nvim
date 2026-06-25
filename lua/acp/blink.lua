local M = {}

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function context_bufnr(ctx)
	if ctx and type(ctx.bufnr) == "number" and valid_buf(ctx.bufnr) then
		return ctx.bufnr
	end
	return vim.api.nvim_get_current_buf()
end

local function context_cursor(ctx, bufnr)
	if ctx and type(ctx.cursor) == "table" then
		local row = tonumber(ctx.cursor[1])
		local col = tonumber(ctx.cursor[2])
		if row and col then
			return row, col
		end
	end

	local winid = vim.fn.bufwinid(bufnr)
	if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
		local cursor = vim.api.nvim_win_get_cursor(winid)
		return cursor[1], cursor[2]
	end

	return 1, 0
end

local function context_line(ctx, bufnr, row)
	if ctx and type(ctx.line) == "string" then
		return ctx.line
	end
	if valid_buf(bufnr) then
		return vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	end
	return ""
end

local function kind_for_complete_item(item)
	local kinds = vim.lsp.protocol.CompletionItemKind
	local kind = item and item.kind
	if kind == "Function" then
		return kinds.Function
	end
	if kind == "Snippet" then
		return kinds.Snippet
	end
	return kinds.Text
end

local function edit_range(row, start_col, cursor_col)
	return {
		start = {
			line = row - 1,
			character = start_col,
		},
		["end"] = {
			line = row - 1,
			character = cursor_col,
		},
	}
end

local function completion_scope(item)
	local word = item and item.word or ""
	if word:sub(1, 1) == "@" then
		return "ACP workflow"
	end
	if word:sub(1, 1) == "/" then
		return "adapter command"
	end
	return "ACP completion"
end

local function completion_documentation(item, scope)
	local lines = {
		item.abbr or item.word or "ACP completion",
		"",
		scope,
	}
	if item.menu and item.menu ~= "" then
		table.insert(lines, ("context: %s"):format(item.menu))
	end
	if item.info and item.info ~= "" then
		table.insert(lines, "")
		table.insert(lines, item.info)
	end
	return table.concat(lines, "\n")
end

local function map_item(item, index, range, state_id)
	local label = item.abbr or item.word
	local scope = completion_scope(item)
	local mapped = {
		label = label,
		kind = kind_for_complete_item(item),
		detail = scope,
		filterText = item.word,
		sortText = ("%04d"):format(index),
		textEdit = {
			newText = item.word,
			range = range,
		},
		insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
		data = {
			acp_complete_item = item,
			acp_completion_scope = scope,
			acp_state_id = state_id,
		},
	}

	mapped.labelDetails = {
		detail = ("  %s"):format(scope),
		description = item.menu,
	}
	mapped.documentation = {
		kind = "plaintext",
		value = completion_documentation(item, scope),
	}
	return mapped
end

local function apply_text_edit(bufnr, item, new_text_override, range_override)
	local text_edit = item and item.textEdit
	local range = range_override or (text_edit and text_edit.range)
	if not (valid_buf(bufnr) and range and range.start and range["end"]) then
		return
	end

	local new_text = new_text_override
	if new_text == nil then
		new_text = text_edit.newText or item.insertText or item.label or ""
	end
	local lines = vim.split(new_text, "\n", { plain = true })
	vim.api.nvim_buf_set_text(
		bufnr,
		range.start.line,
		range.start.character,
		range["end"].line,
		range["end"].character,
		lines
	)

	local winid = vim.fn.bufwinid(bufnr)
	if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
		local row = range.start.line + #lines
		local col = #lines == 1 and range.start.character + #lines[1] or #lines[#lines]
		pcall(vim.api.nvim_win_set_cursor, winid, { row, col })
	end
end

local function clear_action_text(bufnr, item, complete_item)
	local text_edit = item and item.textEdit
	local range = vim.deepcopy(text_edit and text_edit.range)
	if not (valid_buf(bufnr) and range and range.start and range["end"]) then
		return
	end

	local word = complete_item and complete_item.word
	if type(word) == "string" and word ~= "" and range.start.line == range["end"].line then
		local row = range.start.line
		local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
		local start_col = range.start.character
		if line:sub(start_col + 1, start_col + #word) == word then
			range["end"].character = start_col + #word
		end
	end

	apply_text_edit(bufnr, item, "", range)
end

function M.provider(opts)
	return vim.tbl_deep_extend("force", {
		name = "ACP",
		module = "acp.blink",
		score_offset = 80,
		enabled = function()
			return vim.b.acp_blink_source == true
		end,
	}, opts or {})
end

function M.new()
	return setmetatable({}, { __index = M })
end

function M:get_trigger_characters()
	return { "/", "@" }
end

function M:enabled()
	return vim.b.acp_blink_source == true
end

function M:get_completions(ctx, callback)
	local bufnr = context_bufnr(ctx)
	if not (valid_buf(bufnr) and vim.b[bufnr].acp_blink_source == true) then
		callback()
		return
	end

	local row, cursor_col = context_cursor(ctx, bufnr)
	local line = context_line(ctx, bufnr, row)
	local ui = require("acp.ui")
	local start_col = ui.prompt_completion_start(line, cursor_col)
	if start_col < 0 or start_col > cursor_col then
		callback()
		return
	end

	local base = line:sub(start_col + 1, cursor_col)
	local complete_items = ui.prompt_completion_items(bufnr, base)
	local state_id = ui.prompt_completion_state_id(bufnr)
	local range = edit_range(row, start_col, cursor_col)
	local items = {}
	for index, item in ipairs(complete_items) do
		table.insert(items, map_item(item, index, range, state_id))
	end

	callback({
		is_incomplete_forward = false,
		is_incomplete_backward = false,
		items = items,
	})
end

function M:execute(ctx, item, callback, default_implementation)
	local bufnr = context_bufnr(ctx)
	local data = item and item.data or {}
	local complete_item = data.acp_complete_item
	local action_id = complete_item and require("acp.prompt_completion").action_id(complete_item)
	if action_id then
		clear_action_text(bufnr, item, complete_item)
		local state_id = data.acp_state_id or require("acp.ui").prompt_completion_state_id(bufnr)
		require("acp.ui").handle_prompt_completion_action(state_id, complete_item)
	else
		if type(default_implementation) == "function" then
			default_implementation()
		else
			apply_text_edit(bufnr, item)
		end
	end

	if type(callback) == "function" then
		callback()
	end
end

return M
