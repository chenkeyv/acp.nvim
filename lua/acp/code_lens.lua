local context = require("acp.context")
local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")

local M = {}

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lsp_range(range)
	if type(range) ~= "table" or type(range.start) ~= "table" or type(range["end"]) ~= "table" then
		return nil
	end

	local line1 = (tonumber(range.start.line) or 0) + 1
	local line2 = (tonumber(range["end"].line) or (line1 - 1)) + 1
	if line2 < line1 then
		line2 = line1
	end
	return {
		line1 = line1,
		line2 = line2,
		col1 = (tonumber(range.start.character) or 0) + 1,
		col2 = (tonumber(range["end"].character) or 0) + 1,
	}
end

local function command(lens)
	if type(lens) ~= "table" or type(lens.command) ~= "table" then
		return nil
	end
	return lens.command
end

function M.range(lens)
	return lsp_range(type(lens) == "table" and lens.range or nil)
end

function M.title(lens)
	local cmd = command(lens)
	return clean(cmd and cmd.title) or "Unresolved code lens"
end

function M.command_name(lens)
	local cmd = command(lens)
	return clean(cmd and cmd.command)
end

function M.normalize(results)
	local out = {}
	local function collect(item)
		if type(item) == "table" and M.range(item) then
			table.insert(out, item)
		elseif type(item) == "table" then
			for _, child in ipairs(item) do
				collect(child)
			end
		end
	end
	collect(results)

	table.sort(out, function(left, right)
		local left_range = M.range(left) or {}
		local right_range = M.range(right) or {}
		if (left_range.line1 or 1) ~= (right_range.line1 or 1) then
			return (left_range.line1 or 1) < (right_range.line1 or 1)
		end
		return (left_range.col1 or 1) < (right_range.col1 or 1)
	end)
	return out
end

function M.picker_lines(items)
	local lines = { chrome.title(icons.code, "ACP Code Lens"), "" }
	local line_items = {}
	for index, item in ipairs(items or {}) do
		local range = M.range(item) or {}
		local title = M.title(item)
		local command_name = M.command_name(item)
		local suffix = command_name and ("  " .. command_name .. " " .. icons.command) or ""
		table.insert(
			lines,
			chrome.row(index, icons.code, ("%d:%d  %s%s"):format(range.line1 or 1, range.col1 or 1, title, suffix))
		)
		line_items[#lines] = item
	end

	table.insert(lines, "")
	table.insert(lines, chrome.footer("Press <Enter> to add code-lens context, Q for quickfix, or q/<Esc> to close."))
	return lines, line_items
end

function M.quickfix_items(bufnr, items)
	local qf_items = {}
	for _, item in ipairs(items or {}) do
		local range = M.range(item)
		if range then
			table.insert(qf_items, {
				bufnr = bufnr,
				lnum = range.line1,
				col = range.col1 or 1,
				end_lnum = range.line2,
				end_col = range.col2 or range.col1 or 1,
				text = ("CODE LENS: %s"):format(M.title(item)),
			})
		end
	end
	return qf_items
end

function M.prompt(source, item)
	local range = M.range(item)
	if not range then
		return nil, "LSP code lens has no range"
	end

	local lens_source = context.capture(source.bufnr, source.winid, range)
	local rendered_context = context.render(lens_source, {
		include_diagnostics = false,
		treesitter_text_lines = 32,
		selection_limit = 120,
	})
	if not rendered_context then
		return nil, "Failed to render LSP code-lens context"
	end

	local lines = {
		("Use this LSP code lens as context: %s."):format(M.title(item)),
		"",
		"Code lens:",
		("- Title: %s"):format(M.title(item)),
	}
	local command_name = M.command_name(item)
	if command_name then
		table.insert(lines, ("- Command: %s"):format(command_name))
	end
	local args = command(item) and command(item).arguments
	if type(args) == "table" and #args > 0 then
		table.insert(lines, ("- Arguments: %d item(s)"):format(#args))
	end
	table.insert(lines, "")
	table.insert(lines, rendered_context)
	return table.concat(lines, "\n")
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP code-lens requests are unavailable")
		return false
	end

	local params = {
		textDocument = {
			uri = vim.uri_from_bufnr(source.bufnr),
		},
	}

	local ok, request_ids = pcall(
		vim.lsp.buf_request_all,
		source.bufnr,
		"textDocument/codeLens",
		params,
		function(results)
			local raw = {}
			for _, response in pairs(results or {}) do
				if type(response) == "table" and type(response.result) == "table" then
					vim.list_extend(raw, response.result)
				end
			end
			callback(M.normalize(raw), nil)
		end
	)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports code lens")
		return false
	end
	return true
end

return M
