local M = {}

local function is_code_action(action)
	return type(action) == "table" and type(action.title) == "string" and action.title ~= ""
end

function M.flatten(results)
	local out = {}
	for _, action in ipairs(results or {}) do
		if is_code_action(action) then
			table.insert(out, action)
		end
	end
	return out
end

function M.kind_label(action)
	local kind = action and action.kind
	if type(kind) == "string" and kind ~= "" then
		return kind
	end
	if action and type(action.command) == "string" and action.command ~= "" then
		return "command"
	end
	if action and type(action.command) == "table" then
		return "command"
	end
	return "code_action"
end

function M.has_edit(action)
	return type(action) == "table" and type(action.edit) == "table"
end

function M.diagnostic_count(action)
	return type(action) == "table" and type(action.diagnostics) == "table" and #action.diagnostics or 0
end

function M.picker_lines(actions)
	local lines = { "ACP Code Actions", "" }
	local line_actions = {}
	for index, action in ipairs(actions or {}) do
		local markers = {}
		if action.isPreferred then
			table.insert(markers, "preferred")
		end
		if M.has_edit(action) then
			table.insert(markers, "edit")
		end
		if type(action.command) == "table" or type(action.command) == "string" then
			table.insert(markers, "command")
		end
		local marker_text = #markers > 0 and (" [" .. table.concat(markers, ", ") .. "]") or ""

		table.insert(lines, ("%d. %s  %s%s"):format(index, action.title, M.kind_label(action), marker_text))
		line_actions[#lines] = action

		local diagnostic_count = M.diagnostic_count(action)
		if diagnostic_count > 0 then
			table.insert(lines, ("   %d diagnostic(s)"):format(diagnostic_count))
			line_actions[#lines] = action
		end
		if action.disabled and action.disabled.reason and action.disabled.reason ~= "" then
			table.insert(lines, ("   disabled: %s"):format(action.disabled.reason))
			line_actions[#lines] = action
		end
	end

	table.insert(lines, "")
	table.insert(lines, "Press <Enter> to draft, or q/<Esc> to close.")
	return lines, line_actions
end

local function source_line_range(source)
	if source and source.range then
		return source.range.line1, source.range.line2
	end
	if source and source.cursor then
		return source.cursor[1], source.cursor[1]
	end
	return 1, 1
end

local function line_end_col(bufnr, line)
	local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
	return #text
end

local function lsp_range(source)
	local bufnr = source.bufnr
	local max_line = vim.api.nvim_buf_line_count(bufnr)
	local line1, line2 = source_line_range(source)
	line1 = math.max(1, math.min(line1 or 1, max_line))
	line2 = math.max(1, math.min(line2 or line1, max_line))
	if line2 < line1 then
		line1, line2 = line2, line1
	end

	return {
		start = {
			line = line1 - 1,
			character = 0,
		},
		["end"] = {
			line = line2 - 1,
			character = line_end_col(bufnr, line2),
		},
	}, line1, line2
end

local function lsp_diagnostics(bufnr, line1, line2)
	local out = {}
	for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
		local diagnostic_line = (diagnostic.lnum or 0) + 1
		if diagnostic_line >= line1 and diagnostic_line <= line2 then
			table.insert(out, {
				range = {
					start = {
						line = diagnostic.lnum or 0,
						character = diagnostic.col or 0,
					},
					["end"] = {
						line = diagnostic.end_lnum or diagnostic.lnum or 0,
						character = diagnostic.end_col or diagnostic.col or 0,
					},
				},
				severity = diagnostic.severity,
				source = diagnostic.source,
				message = diagnostic.message or "",
				code = diagnostic.code,
			})
		end
	end
	return out
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP code-action requests are unavailable")
		return false
	end

	local range, line1, line2 = lsp_range(source)
	local params = {
		textDocument = {
			uri = vim.uri_from_bufnr(source.bufnr),
		},
		range = range,
		context = {
			diagnostics = lsp_diagnostics(source.bufnr, line1, line2),
		},
	}

	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "textDocument/codeAction", params, function(results)
		local raw_actions = {}
		for _, response in pairs(results or {}) do
			if type(response) == "table" and type(response.result) == "table" then
				vim.list_extend(raw_actions, response.result)
			end
		end
		callback(M.flatten(raw_actions), nil)
	end)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports code actions")
		return false
	end
	return true
end

return M
