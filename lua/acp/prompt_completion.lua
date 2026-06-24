local commands = require("acp.commands")

local M = {}

local workflows = {
	{
		id = "context",
		trigger = "@context",
		menu = "source",
		info = "Insert the captured source context into the prompt.",
	},
	{
		id = "smart_context",
		trigger = "@smart-context",
		menu = "source+LSP",
		info = "Insert source context plus available LSP hover, signature, hints, and ranges.",
	},
	{
		id = "diagnostics",
		trigger = "@diagnostics",
		menu = "LSP",
		info = "Open source diagnostics as focused ACP context.",
	},
	{
		id = "workspace_diagnostics",
		trigger = "@workspace-diagnostics",
		menu = "LSP",
		info = "Open diagnostics across loaded project buffers as focused ACP context.",
	},
	{
		id = "code_actions",
		trigger = "@code-actions",
		menu = "LSP",
		info = "Open LSP code actions as focused ACP context.",
	},
	{
		id = "hover",
		trigger = "@hover",
		menu = "LSP",
		info = "Insert LSP hover documentation for the source cursor.",
	},
	{
		id = "signature",
		trigger = "@signature",
		menu = "LSP",
		info = "Insert LSP signature help for the source cursor.",
	},
	{
		id = "inlay_hints",
		trigger = "@inlay-hints",
		menu = "LSP",
		info = "Open LSP inlay hints as focused source context.",
	},
	{
		id = "selection",
		trigger = "@selection",
		menu = "LSP",
		info = "Open LSP semantic selection ranges as focused context.",
	},
	{
		id = "references",
		trigger = "@references",
		menu = "LSP",
		info = "Open source-cursor LSP references as focused context.",
	},
	{
		id = "callers",
		trigger = "@callers",
		menu = "LSP",
		info = "Open incoming LSP call hierarchy entries as focused context.",
	},
	{
		id = "callees",
		trigger = "@callees",
		menu = "LSP",
		info = "Open outgoing LSP call hierarchy entries as focused context.",
	},
	{
		id = "supertypes",
		trigger = "@supertypes",
		menu = "LSP",
		info = "Open LSP type hierarchy supertypes as focused context.",
	},
	{
		id = "subtypes",
		trigger = "@subtypes",
		menu = "LSP",
		info = "Open LSP type hierarchy subtypes as focused context.",
	},
	{
		id = "symbols",
		trigger = "@symbols",
		menu = "LSP",
		info = "Open document symbols as focused context.",
	},
	{
		id = "workspace",
		trigger = "@workspace",
		menu = "LSP",
		info = "Search workspace symbols for the source cursor word.",
	},
	{
		id = "treesitter",
		trigger = "@treesitter",
		menu = "Tree-sitter",
		info = "Open syntax-aware Tree-sitter nodes around the source cursor.",
	},
	{
		id = "output",
		trigger = "@output",
		menu = "output",
		info = "Draft from the current ACP output section.",
	},
}

local function workflow_user_data(id)
	return "acp.nvim:" .. id
end

function M.start(line, cursor_col)
	line = line or ""
	cursor_col = cursor_col or #line
	local before_cursor = line:sub(1, cursor_col)
	local slash_start = commands.completion_start(line, cursor_col)
	if slash_start >= 0 then
		return slash_start
	end

	local action_start = before_cursor:match("()@[%w_%-]*$")
	if action_start then
		return action_start - 1
	end
	return -3
end

function M.workflow_items(base)
	base = base or ""
	if base:sub(1, 1) ~= "@" then
		return {}
	end

	local prefix = base:lower()
	local items = {}
	for _, workflow in ipairs(workflows) do
		if workflow.trigger:lower():sub(1, #prefix) == prefix then
			table.insert(items, {
				word = workflow.trigger,
				abbr = workflow.trigger,
				kind = "Snippet",
				menu = workflow.menu,
				info = workflow.info,
				dup = 0,
				user_data = workflow_user_data(workflow.id),
			})
		end
	end
	return items
end

function M.items(available_commands, base)
	base = base or ""
	if base:sub(1, 1) == "/" then
		return commands.completion_items(available_commands, base)
	end
	return M.workflow_items(base)
end

function M.action_id(completed_item)
	local user_data = completed_item and completed_item.user_data
	if type(user_data) == "table" then
		user_data = user_data.user_data or user_data.action or user_data.id
	end
	if type(user_data) ~= "string" then
		return nil
	end
	return user_data:match("^acp%.nvim:(.+)$")
end

function M.remove_completed_word(bufnr, winid, word)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and winid and vim.api.nvim_win_is_valid(winid)) then
		return false
	end
	if type(word) ~= "string" or word == "" then
		return false
	end
	if vim.api.nvim_win_get_buf(winid) ~= bufnr then
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(winid)
	local row = cursor[1]
	local col = cursor[2]
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	local before = line:sub(1, col)
	if before:sub(-#word) ~= word then
		return false
	end

	local next_line = before:sub(1, #before - #word) .. line:sub(col + 1)
	vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { next_line })
	pcall(vim.api.nvim_win_set_cursor, winid, { row, #before - #word })
	return true
end

return M
