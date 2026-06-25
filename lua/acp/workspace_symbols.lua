local context = require("acp.context")
local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")
local references = require("acp.references")
local symbols = require("acp.symbols")

local M = {}

local function symbol_location(symbol)
	if type(symbol) ~= "table" or type(symbol.location) ~= "table" then
		return nil
	end
	if type(symbol.location.uri) == "string" then
		return symbol.location
	end
	if type(symbol.location.targetUri) == "string" then
		return {
			uri = symbol.location.targetUri,
			range = symbol.location.targetSelectionRange or symbol.location.targetRange,
		}
	end
	return nil
end

local function source_word(source)
	if not source or not source.bufnr or not vim.api.nvim_buf_is_valid(source.bufnr) then
		return nil
	end

	local cursor = source.cursor or { 1, 0 }
	local line = vim.api.nvim_buf_get_lines(source.bufnr, (cursor[1] or 1) - 1, cursor[1] or 1, false)[1] or ""
	local col = math.max(1, math.min(#line + 1, (cursor[2] or 0) + 1))
	local start_col = col
	while start_col > 1 and line:sub(start_col - 1, start_col - 1):match("[%w_]") do
		start_col = start_col - 1
	end
	local end_col = col
	while end_col <= #line and line:sub(end_col, end_col):match("[%w_]") do
		end_col = end_col + 1
	end
	local word = line:sub(start_col, end_col - 1)
	if word == "" then
		return nil
	end
	return word
end

function M.default_query(source, query)
	if type(query) == "string" and query:match("%S") then
		return vim.trim(query)
	end
	return source_word(source)
end

function M.location(symbol)
	return symbol_location(symbol)
end

function M.range(symbol)
	return references.range(symbol_location(symbol))
end

function M.bufnr(symbol)
	return references.bufnr(symbol_location(symbol))
end

function M.display_path(symbol)
	return references.display_path(symbol_location(symbol))
end

function M.normalize(results)
	local items = {}
	for _, symbol in ipairs(results or {}) do
		local location = symbol_location(symbol)
		if
			type(symbol) == "table"
			and type(symbol.name) == "string"
			and symbol.name ~= ""
			and references.range(location)
		then
			table.insert(items, {
				name = symbol.name,
				kind = symbol.kind,
				containerName = symbol.containerName,
				location = location,
			})
		end
	end
	return items
end

function M.picker_lines(items, opts)
	opts = opts or {}
	local lines = { chrome.title(icons.symbol, opts.title or "ACP Workspace Symbols"), "" }
	local line_symbols = {}
	for index, symbol in ipairs(items or {}) do
		local range = M.range(symbol)
		local location = range and ("%s:%d"):format(M.display_path(symbol), range.line1) or M.display_path(symbol)
		local container = symbol.containerName and symbol.containerName ~= "" and ("  " .. symbol.containerName) or ""
		table.insert(
			lines,
			chrome.row(
				index,
				icons.symbol,
				("%s  %s  %s%s"):format(symbol.name, symbols.kind_name(symbol.kind), location, container)
			)
		)
		line_symbols[#lines] = symbol
	end

	table.insert(lines, "")
	table.insert(lines, chrome.footer("Press <Enter> to add context, Q for quickfix, or q/<Esc> to close."))
	return lines, line_symbols
end

function M.quickfix_items(items)
	local qf_items = {}
	for _, symbol in ipairs(items or {}) do
		local bufnr = M.bufnr(symbol)
		local range = M.range(symbol)
		if bufnr and range then
			table.insert(qf_items, {
				bufnr = bufnr,
				lnum = range.line1,
				col = range.col1 or 1,
				end_lnum = range.line2,
				end_col = range.col2 or range.col1 or 1,
				text = ("WORKSPACE SYMBOL: %s (%s)"):format(symbol.name or "?", symbols.kind_name(symbol.kind)),
			})
		end
	end
	return qf_items
end

function M.prompt(symbol)
	local bufnr, err = M.bufnr(symbol)
	if not bufnr then
		return nil, err
	end
	local range = M.range(symbol)
	if not range then
		return nil, "LSP workspace symbol has no range"
	end

	local symbol_source = context.capture(bufnr, nil, range)
	if symbol_source then
		symbol_source.cursor = { range.line1, 0 }
	end
	local rendered_context = context.render(symbol_source, {
		treesitter_text_lines = 32,
		selection_limit = 100,
	})
	if not rendered_context then
		return nil, "Failed to render LSP workspace symbol context"
	end

	return table.concat({
		("Use this LSP workspace symbol as context: %s (%s)."):format(symbol.name, symbols.kind_name(symbol.kind)),
		("Symbol: %s:%d"):format(M.display_path(symbol), range.line1),
		"",
		rendered_context,
	}, "\n")
end

function M.request(source, query, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP workspace-symbol requests are unavailable")
		return false
	end

	local params = {
		query = query or "",
	}
	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "workspace/symbol", params, function(results)
		local raw_symbols = {}
		for _, response in pairs(results or {}) do
			if type(response) == "table" and type(response.result) == "table" then
				vim.list_extend(raw_symbols, response.result)
			end
		end
		callback(M.normalize(raw_symbols), nil)
	end)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports workspace symbols")
		return false
	end
	return true
end

return M
