local context = require("acp.context")
local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")

local M = {}

local kind_names = {
	[1] = "TYPE",
	[2] = "PARAM",
}

local function clean(value)
	if value == nil or value == "" or value == vim.NIL then
		return nil
	end
	return tostring(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function line_text(bufnr, line)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		return nil
	end
	local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
	text = clean(text)
	if text and #text > 72 then
		text = text:sub(1, 69) .. "..."
	end
	return text
end

local function label_text(label)
	if type(label) == "string" then
		return clean(label)
	end
	if type(label) ~= "table" then
		return nil
	end

	local parts = {}
	for _, part in ipairs(label) do
		if type(part) == "string" then
			table.insert(parts, part)
		elseif type(part) == "table" and type(part.value) == "string" then
			table.insert(parts, part.value)
		end
	end
	return clean(table.concat(parts, ""))
end

local function range_key(item)
	return ("%d:%d:%s:%s"):format(item.line or 1, item.col or 1, item.kind or "HINT", item.label or "")
end

function M.kind_name(kind)
	if type(kind) == "string" and kind ~= "" then
		return kind:upper()
	end
	return kind_names[kind] or "HINT"
end

function M.source_range(source)
	if not source or not source.bufnr or not vim.api.nvim_buf_is_valid(source.bufnr) then
		return nil
	end

	local max_line = vim.api.nvim_buf_line_count(source.bufnr)
	local line1 = source.cursor and source.cursor[1] or 1
	local line2 = line1
	if source.range then
		line1 = source.range.line1 or line1
		line2 = source.range.line2 or line2
	end
	line1 = math.max(1, math.min(tonumber(line1) or 1, max_line))
	line2 = math.max(1, math.min(tonumber(line2) or line1, max_line))
	if line2 < line1 then
		line1, line2 = line2, line1
	end
	return {
		line1 = line1,
		line2 = line2,
	}
end

function M.range(item)
	if not item then
		return nil
	end
	if item.range then
		return item.range
	end
	if item.line then
		return {
			line1 = item.line,
			line2 = item.line,
		}
	end
	return nil
end

function M.normalize(hint)
	if type(hint) ~= "table" or type(hint.position) ~= "table" then
		return nil
	end

	local label = label_text(hint.label)
	if not label then
		return nil
	end

	return {
		line = (tonumber(hint.position.line) or 0) + 1,
		col = (tonumber(hint.position.character) or 0) + 1,
		kind = M.kind_name(hint.kind),
		label = label,
		padding_left = hint.paddingLeft == true,
		padding_right = hint.paddingRight == true,
	}
end

function M.flatten(results)
	local out = {}
	local seen = {}
	local function collect(items)
		for _, hint in ipairs(items or {}) do
			local item = M.normalize(hint)
			if item then
				local key = range_key(item)
				if not seen[key] then
					seen[key] = true
					table.insert(out, item)
				end
			end
		end
	end

	if type(results) ~= "table" then
		return out
	end
	if results.result ~= nil then
		collect(results.result)
	else
		for _, response in pairs(results) do
			if type(response) == "table" and response.result ~= nil then
				collect(response.result)
			end
		end
		if #out == 0 then
			collect(results)
		end
	end

	table.sort(out, function(left, right)
		if left.line ~= right.line then
			return left.line < right.line
		end
		if left.col ~= right.col then
			return left.col < right.col
		end
		return left.label < right.label
	end)
	for index, item in ipairs(out) do
		item.index = index
	end
	return out
end

local function hint_line(item)
	return ("- %d:%d %s %s"):format(item.line or 1, item.col or 1, item.kind or "HINT", item.label or "?")
end

function M.picker_lines(items, opts)
	opts = opts or {}
	items = items or {}
	local lines = { chrome.title(icons.hint, "ACP Inlay Hints"), "" }
	local line_items = {}
	if #items > 1 then
		local range = opts.range
		local label = ("All inlay hints (%d)"):format(#items)
		if range then
			label = ("%s lines %d-%d"):format(label, range.line1 or 1, range.line2 or range.line1 or 1)
		end
		table.insert(lines, chrome.row(1, icons.hint, label))
		line_items[#lines] = {
			all = true,
			hints = items,
			range = range,
		}
	end

	for index, item in ipairs(items) do
		local preview = line_text(opts.bufnr, item.line or 1)
		local line = chrome.row(
			index + (#items > 1 and 1 or 0),
			icons.hint,
			("%-5s %d:%d  %s"):format(item.kind or "HINT", item.line or 1, item.col or 1, item.label or "?")
		)
		if preview then
			line = ("%s  %s"):format(line, preview)
		end
		table.insert(lines, line)
		line_items[#lines] = item
	end

	table.insert(lines, "")
	table.insert(lines, chrome.footer("Press <Enter> to add inlay-hint context, or q/<Esc> to close."))
	return lines, line_items
end

function M.prompt(source, target)
	local hints
	local range
	if target and target.all then
		hints = target.hints or {}
		range = target.range
	elseif target then
		hints = { target }
		range = M.range(target)
	else
		hints = {}
	end
	if #hints == 0 then
		return nil
	end
	range = range or M.source_range(source)

	local hint_source = context.capture(source.bufnr, source.winid, range)
	if hint_source and range then
		local hint = #hints == 1 and hints[1] or nil
		hint_source.cursor = {
			hint and hint.line or range.line1,
			hint and math.max(0, (hint.col or 1) - 1) or 0,
		}
	end
	local rendered_context = context.render(hint_source or source, {
		treesitter_text_lines = 40,
		selection_limit = 160,
	})
	if not rendered_context then
		return nil
	end

	local lines = {
		#hints == 1 and "Use this LSP inlay hint as context." or "Use these LSP inlay hints as context.",
		"",
		"Inlay hints:",
	}
	for _, hint in ipairs(hints) do
		table.insert(lines, hint_line(hint))
	end
	table.insert(lines, "")
	table.insert(lines, rendered_context)
	return table.concat(lines, "\n")
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP inlay-hint requests are unavailable")
		return false
	end

	local range = M.source_range(source)
	if not range then
		callback(nil, "No source range is available for inlay hints")
		return false
	end
	local end_line = vim.api.nvim_buf_get_lines(source.bufnr, range.line2 - 1, range.line2, false)[1] or ""
	local params = {
		textDocument = {
			uri = vim.uri_from_bufnr(source.bufnr),
		},
		range = {
			start = {
				line = range.line1 - 1,
				character = 0,
			},
			["end"] = {
				line = range.line2 - 1,
				character = #end_line,
			},
		},
	}

	local ok, request_ids = pcall(
		vim.lsp.buf_request_all,
		source.bufnr,
		"textDocument/inlayHint",
		params,
		function(results)
			callback(M.flatten(results), nil, range)
		end
	)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports inlay hints")
		return false
	end
	return true
end

return M
