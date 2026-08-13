local output = require("acp.output")

local M = {}

M.preview_tail_lines = 3
M.preview_limit = M.preview_tail_lines + 2
M.tool_preview_width = 80
M.command_preview_width = 80

local action_types = {
	commandExecution = "command",
	dynamicToolCall = "tool",
	mcpToolCall = "tool",
}

local failed_statuses = {
	canceled = true,
	cancelled = true,
	declined = true,
	error = true,
	failed = true,
	interrupted = true,
	rejected = true,
}

local function present(value)
	return value ~= nil and value ~= vim.NIL
end

local function normalize_status(value)
	if not present(value) then
		return "completed"
	end
	return tostring(value):gsub("(%l)(%u)", "%1 %2"):lower()
end

local function clean(value)
	return output.strip_ansi(value):gsub("\r", "")
end

local function split_lines(value)
	local text = clean(value)
	if text == "" then
		return {}
	end
	local lines = vim.split(text, "\n", { plain = true })
	if text:sub(-1) == "\n" then
		table.remove(lines)
	end
	return lines
end

local function encode(value)
	if not present(value) then
		return nil
	end
	if type(value) == "string" then
		return value
	end
	local ok, encoded = pcall(vim.json.encode, value)
	return ok and encoded or tostring(value)
end

local function merge_item(base, update)
	local merged = vim.deepcopy(type(base) == "table" and base or {})
	for key, value in pairs(type(update) == "table" and update or {}) do
		merged[key] = vim.deepcopy(value)
	end
	return merged
end

local function preview(lines)
	local visible_lines = M.preview_tail_lines + 1
	if #lines <= visible_lines then
		return vim.deepcopy(lines)
	end

	local values = { lines[1], ("... +%d lines"):format(#lines - visible_lines) }
	for index = #lines - M.preview_tail_lines + 1, #lines do
		table.insert(values, lines[index])
	end
	return values
end

local function truncate_display(value, width)
	value = tostring(value or "")
	width = math.max(1, math.floor(tonumber(width) or 1))
	if vim.fn.strdisplaywidth(value) <= width then
		return value
	end

	local suffix = "..."
	local target = math.max(0, width - vim.fn.strdisplaywidth(suffix))
	local low = 0
	local high = vim.fn.strchars(value)
	while low < high do
		local middle = math.ceil((low + high) / 2)
		if vim.fn.strdisplaywidth(vim.fn.strcharpart(value, 0, middle)) <= target then
			low = middle
		else
			high = middle - 1
		end
	end
	return vim.fn.strcharpart(value, 0, low) .. suffix
end

local function row(text, role, opts)
	return vim.tbl_extend("force", {
		text = tostring(text or ""),
		role = role,
	}, opts or {})
end

local function row_lines(rows)
	return vim.tbl_map(function(value)
		return value.text
	end, rows or {})
end

local function duration_label(value)
	local milliseconds = tonumber(value)
	if not milliseconds then
		return nil
	end
	if milliseconds < 1000 then
		return ("%dms"):format(math.max(0, math.floor(milliseconds)))
	end
	return ("%.1fs"):format(milliseconds / 1000):gsub("%.0s$", "s")
end

local function command_output(child)
	if present(child.output) then
		return tostring(child.output)
	end
	local item = child.item or {}
	return present(item.aggregatedOutput) and tostring(item.aggregatedOutput) or ""
end

local function content_block_lines(block)
	if type(block) ~= "table" then
		return split_lines(encode(block) or "")
	end
	if block.type == "text" or block.type == "inputText" then
		return split_lines(block.text)
	elseif block.type == "image" or block.type == "inputImage" then
		return { "<image content>" }
	elseif block.type == "audio" or block.type == "inputAudio" then
		return { "<audio content>" }
	elseif block.type == "resource_link" then
		return { ("link: %s"):format(block.uri or "resource") }
	elseif block.type == "resource" then
		local resource = block.resource or {}
		return { ("embedded resource: %s"):format(resource.uri or "resource") }
	end
	return split_lines(encode(block) or "")
end

local function tool_result_lines(child)
	local item = child.item or {}
	local values = {}
	if type(item.error) == "table" and present(item.error.message) then
		return split_lines("Error: " .. tostring(item.error.message))
	elseif present(item.error) then
		return split_lines("Error: " .. tostring(item.error))
	end

	if item.type == "mcpToolCall" and type(item.result) == "table" then
		for _, block in ipairs(item.result.content or {}) do
			vim.list_extend(values, content_block_lines(block))
		end
		if #values == 0 and present(item.result.structuredContent) then
			vim.list_extend(values, split_lines(encode(item.result.structuredContent) or ""))
		end
	elseif item.type == "dynamicToolCall" then
		for _, block in ipairs(item.contentItems or {}) do
			vim.list_extend(values, content_block_lines(block))
		end
	end

	if #values == 0 and M.is_active(child) and present(child.progress) then
		return split_lines(child.progress)
	end
	return values
end

local function tool_invocation(item, max_width)
	item = item or {}
	local name = tostring(item.tool or "tool")
	if present(item.server) and tostring(item.server) ~= "" then
		name = tostring(item.server) .. "." .. name
	elseif present(item.namespace) and tostring(item.namespace) ~= "" then
		name = tostring(item.namespace) .. "." .. name
	end
	local arguments = encode(item.arguments)
	local invocation = arguments and (name .. "(" .. arguments .. ")") or name
	if max_width and arguments and vim.fn.strdisplaywidth(invocation) > max_width then
		invocation = name .. "(...)"
	end
	return max_width and truncate_display(invocation, max_width) or invocation
end

local tool_action_kinds = {
	{
		kind = "edit",
		words = { "apply", "create", "delete", "edit", "move", "patch", "remove", "rename", "replace", "write" },
	},
	{ kind = "search", words = { "find", "grep", "lookup", "query", "search" } },
	{ kind = "read", words = { "fetch", "get", "inspect", "open", "read", "view" } },
	{ kind = "list", words = { "glob", "list", "scan" } },
}

local function tool_action_kind(item)
	local name = tostring(item and item.tool or ""):gsub("(%l)(%u)", "%1_%2"):lower()
	local name_words = {}
	for word in name:gmatch("[%w]+") do
		name_words[word] = true
	end
	for _, candidate in ipairs(tool_action_kinds) do
		for _, word in ipairs(candidate.words) do
			if name_words[word] then
				return candidate.kind
			end
		end
	end
	return "tool"
end

function M.kind(item)
	return type(item) == "table" and action_types[item.type] or nil
end

function M.is_active(child)
	local item = type(child) == "table" and (child.item or child) or {}
	local status = normalize_status(child.status or item.status)
	return status == "in progress" or status == "running" or status == "pending"
end

function M.failed(child)
	local item = type(child) == "table" and (child.item or child) or {}
	local status = normalize_status(child.status or item.status)
	if failed_statuses[status] then
		return true
	end
	if item.type == "commandExecution" and present(item.exitCode) and tonumber(item.exitCode) ~= 0 then
		return true
	end
	if item.type == "dynamicToolCall" and item.success == false then
		return true
	end
	return item.type == "mcpToolCall"
		and (present(item.error) or (type(item.result) == "table" and item.result.isError == true))
end

function M.is_exploration(item)
	if type(item) ~= "table" or item.type ~= "commandExecution" or #(item.commandActions or {}) == 0 then
		return false
	end
	for _, action in ipairs(item.commandActions) do
		if action.type ~= "read" and action.type ~= "listFiles" and action.type ~= "search" then
			return false
		end
	end
	return true
end

function M.new_child(item)
	item = vim.deepcopy(type(item) == "table" and item or {})
	local child = {
		id = present(item.id) and tostring(item.id) or nil,
		kind = M.kind(item),
		status = normalize_status(item.status),
		item = item,
		progress = nil,
	}
	if item.type == "commandExecution" then
		child.output = present(item.aggregatedOutput) and tostring(item.aggregatedOutput) or ""
	end
	return child
end

function M.update_child(child, item)
	if type(child) ~= "table" or type(item) ~= "table" then
		return child
	end
	local output_text = child.output
	child.item = merge_item(child.item, item)
	child.kind = M.kind(child.item) or child.kind
	child.status = normalize_status(child.item.status)
	if child.item.type == "commandExecution" then
		child.output = present(item.aggregatedOutput) and tostring(item.aggregatedOutput) or output_text or ""
	end
	if not M.is_active(child) then
		child.progress = nil
	end
	return child
end

function M.append_output(child, delta)
	if type(child) ~= "table" or child.kind ~= "command" or not present(delta) or delta == "" then
		return false
	end
	child.output = (child.output or "") .. tostring(delta)
	return true
end

function M.set_progress(child, message)
	if type(child) ~= "table" or child.kind ~= "tool" then
		return false
	end
	child.progress = present(message) and tostring(message) or nil
	return true
end

local function command_rows(child)
	local item = child.item or {}
	local command = split_lines(item.command or "command")
	if #command == 0 then
		command = { "command" }
	end
	local title = M.is_active(child) and "Running" or (item.source == "userShell" and "You ran" or "Ran")
	local header_prefix = ("• %s "):format(title)
	local visible_command = preview(command)
	local rows = {
		row(
			header_prefix
				.. truncate_display(visible_command[1], M.command_preview_width - vim.fn.strdisplaywidth(header_prefix)),
			"action_header",
			{
				title = title,
				title_col = #"• ",
				detail_col = #"• " + #title + 1,
				detail_kind = "command",
				syntax = "bash",
			}
		),
	}

	for index = 2, #visible_command do
		local prefix = "  │ "
		local line = truncate_display(visible_command[index], M.command_preview_width - vim.fn.strdisplaywidth(prefix))
		table.insert(
			rows,
			row(prefix .. line, "action_command", {
				is_meta = line:match("^%.%.%. %+%d+ lines$") ~= nil,
				syntax = "bash",
				tree_width = #prefix,
			})
		)
	end

	local output_lines = split_lines(command_output(child))
	if #output_lines == 0 then
		if not M.is_active(child) then
			table.insert(rows, row("  └ (no output)", "action_output", { tree_width = #"  └ " }))
		end
		return rows
	end
	local visible = preview(output_lines)
	for index, line in ipairs(visible) do
		local prefix = index == 1 and "  └ " or "    "
		line = truncate_display(line, M.command_preview_width - vim.fn.strdisplaywidth(prefix))
		table.insert(
			rows,
			row(prefix .. line, "action_output", {
				is_meta = line:match("^%.%.%. %+%d+ lines$") ~= nil,
				tree_width = #prefix,
			})
		)
	end
	return rows
end

local function tool_rows(child)
	local title = M.is_active(child) and "Calling" or "Called"
	local header_prefix = ("• %s "):format(title)
	local action_kind = tool_action_kind(child.item)
	local rows = {
		row(
			header_prefix .. tool_invocation(child.item, M.tool_preview_width - vim.fn.strdisplaywidth(header_prefix)),
			"action_header",
			{
				action_kind = action_kind,
				title = title,
				title_col = #"• ",
				detail_col = #"• " + #title + 1,
				detail_kind = "tool",
			}
		),
	}
	local details = tool_result_lines(child)
	local visible = preview(details)
	for index, line in ipairs(visible) do
		local prefix = index == 1 and "  └ " or "    "
		line = truncate_display(line, M.tool_preview_width - vim.fn.strdisplaywidth(prefix))
		table.insert(
			rows,
			row(prefix .. line, "action_output", {
				is_meta = line:match("^%.%.%. %+%d+ lines$") ~= nil,
				tree_width = #prefix,
			})
		)
	end
	return rows
end

local function exploration_actions(children)
	local rows = {}
	local function append_read(name)
		local row = rows[#rows]
		if not row or row.kind ~= "read" then
			row = { kind = "read", values = {}, seen = {} }
			table.insert(rows, row)
		end
		name = tostring(name or "file")
		if not row.seen[name] then
			row.seen[name] = true
			table.insert(row.values, name)
		end
	end

	for _, child in ipairs(children or {}) do
		for _, command_action in ipairs((child.item and child.item.commandActions) or {}) do
			if command_action.type == "read" then
				append_read(command_action.name or command_action.path or command_action.command)
			elseif command_action.type == "listFiles" then
				table.insert(rows, {
					kind = "list",
					text = "List " .. tostring(command_action.path or command_action.command or "files"),
				})
			elseif command_action.type == "search" then
				local text = tostring(command_action.query or command_action.command or "search")
				if present(command_action.path) and tostring(command_action.path) ~= "" then
					text = text .. " in " .. tostring(command_action.path)
				end
				table.insert(rows, { kind = "search", text = "Search " .. text })
			end
		end
	end

	for _, row in ipairs(rows) do
		if row.kind == "read" then
			row.text = "Read " .. table.concat(row.values, ", ")
		end
	end
	return rows
end

local function exploration_rows(block)
	local active = false
	for _, child in ipairs(block.children or {}) do
		active = active or M.is_active(child)
	end
	local title = active and "Exploring" or "Explored"
	local rows = {
		row("• " .. title, "action_header", {
			title = title,
			title_col = #"• ",
			detail_kind = "command",
		}),
	}
	for index, action_row in ipairs(exploration_actions(block.children)) do
		local prefix = index == 1 and "  └ " or "    "
		table.insert(
			rows,
			row(prefix .. action_row.text, "action_command", {
				action_kind = action_row.kind,
				tree_width = #prefix,
			})
		)
	end
	return rows
end

function M.render_rows(block)
	if type(block) ~= "table" then
		return {}
	end
	if block.metadata and block.metadata.presentation == "explore" then
		return exploration_rows(block)
	end
	local child = block.children and block.children[1]
	if not child then
		return {}
	elseif child.kind == "command" then
		return command_rows(child)
	elseif child.kind == "tool" then
		return tool_rows(child)
	end
	return vim.tbl_map(function(line)
		return row(line, "action_output")
	end, child.lines or {})
end

function M.render_block(block)
	return row_lines(M.render_rows(block))
end

local function command_detail(child)
	local item = child.item or {}
	local lines = { "$ " .. clean(item.command or "command") }
	local details = split_lines(command_output(child))
	if #details == 0 then
		table.insert(lines, "(no output)")
	else
		vim.list_extend(lines, details)
	end
	if not M.is_active(child) then
		local success = not M.failed(child)
		local result = success and "✓" or ("✗ (%s)"):format(item.exitCode or "failed")
		local duration = duration_label(item.durationMs)
		table.insert(lines, duration and (result .. " • " .. duration) or result)
	end
	return lines
end

local function tool_detail(child)
	local lines = { (M.is_active(child) and "Calling " or "Called ") .. tool_invocation(child.item) }
	vim.list_extend(lines, tool_result_lines(child))
	local duration = duration_label(child.item and child.item.durationMs)
	if duration then
		table.insert(lines, (M.failed(child) and "✗" or "✓") .. " • " .. duration)
	end
	return lines
end

function M.detail_lines(block)
	if type(block) ~= "table" then
		return nil
	end
	local lines = {}
	for index, child in ipairs(block.children or {}) do
		if index > 1 then
			table.insert(lines, "")
		end
		if child.kind == "command" then
			vim.list_extend(lines, command_detail(child))
		elseif child.kind == "tool" then
			vim.list_extend(lines, tool_detail(child))
		else
			vim.list_extend(lines, vim.deepcopy(child.lines or {}))
		end
	end
	return lines
end

return M
