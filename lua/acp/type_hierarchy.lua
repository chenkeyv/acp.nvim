local context = require("acp.context")
local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")
local references = require("acp.references")
local symbols = require("acp.symbols")

local M = {}

local methods = {
	subtypes = "typeHierarchy/subtypes",
	supertypes = "typeHierarchy/supertypes",
}

local labels = {
	subtypes = {
		title = "ACP Subtypes",
		noun = "subtype",
		label = "SUBTYPE",
		relation = "Subtype",
	},
	supertypes = {
		title = "ACP Supertypes",
		noun = "supertype",
		label = "SUPERTYPE",
		relation = "Supertype",
	},
}

local function spec(direction)
	return labels[direction] or labels.supertypes
end

local function item_location(item)
	if type(item) ~= "table" or type(item.uri) ~= "string" then
		return nil
	end
	local range = item.selectionRange or item.range
	if type(range) ~= "table" then
		return nil
	end
	return {
		uri = item.uri,
		range = range,
	}
end

function M.location(item)
	return item and item.location or nil
end

function M.range(item)
	return references.range(M.location(item))
end

function M.bufnr(item)
	return references.bufnr(M.location(item))
end

function M.display_path(item)
	return references.display_path(M.location(item))
end

function M.normalize(results, direction)
	local items = {}
	for _, item in ipairs(results or {}) do
		local location = item_location(item)
		if type(item) == "table" and type(item.name) == "string" and item.name ~= "" and references.range(location) then
			table.insert(items, {
				name = item.name,
				kind = item.kind,
				detail = item.detail,
				location = location,
				direction = direction or "supertypes",
			})
		end
	end
	return items
end

function M.picker_lines(items, opts)
	opts = opts or {}
	local current = spec(opts.direction)
	local lines = { chrome.title(icons.type, opts.title or current.title), "" }
	local line_items = {}
	for index, item in ipairs(items or {}) do
		local range = M.range(item)
		local location = range and ("%s:%d"):format(M.display_path(item), range.line1) or M.display_path(item)
		table.insert(
			lines,
			chrome.row(index, icons.type, ("%s  %s  %s"):format(item.name, symbols.kind_name(item.kind), location))
		)
		line_items[#lines] = item
		if item.detail and item.detail ~= "" then
			table.insert(lines, chrome.detail(icons.note, item.detail))
			line_items[#lines] = item
		end
	end

	table.insert(lines, "")
	table.insert(lines, chrome.footer("Press <Enter> to add context, Q for quickfix, or q/<Esc> to close."))
	return lines, line_items
end

function M.quickfix_items(items, opts)
	opts = opts or {}
	local label = opts.label or spec(opts.direction).label
	local qf_items = {}
	for _, item in ipairs(items or {}) do
		local bufnr = M.bufnr(item)
		local range = M.range(item)
		if bufnr and range then
			table.insert(qf_items, {
				bufnr = bufnr,
				lnum = range.line1,
				col = range.col1 or 1,
				end_lnum = range.line2,
				end_col = range.col2 or range.col1 or 1,
				text = ("%s: %s (%s)"):format(label, item.name or "?", symbols.kind_name(item.kind)),
			})
		end
	end
	return qf_items
end

function M.prompt(item, direction)
	local bufnr, err = M.bufnr(item)
	if not bufnr then
		return nil, err
	end
	local range = M.range(item)
	if not range then
		return nil, "LSP type hierarchy item has no range"
	end

	local type_source = context.capture(bufnr, nil, range)
	if type_source then
		type_source.cursor = { range.line1, 0 }
	end
	local rendered_context = context.render(type_source, {
		treesitter_text_lines = 32,
		selection_limit = 100,
	})
	if not rendered_context then
		return nil, "Failed to render LSP type hierarchy context"
	end

	local current = spec(direction or item.direction)
	return table.concat({
		("Use this LSP %s as context: %s (%s)."):format(current.noun, item.name, symbols.kind_name(item.kind)),
		("%s: %s:%d"):format(current.relation, M.display_path(item), range.line1),
		"",
		rendered_context,
	}, "\n")
end

local function position_params(source)
	local cursor = source.cursor or { 1, 0 }
	return {
		textDocument = {
			uri = vim.uri_from_bufnr(source.bufnr),
		},
		position = {
			line = math.max(0, (cursor[1] or 1) - 1),
			character = math.max(0, cursor[2] or 0),
		},
	}
end

function M.request(source, direction, callback)
	local method = methods[direction]
	if not method then
		callback(nil, "Unknown LSP type hierarchy direction")
		return false
	end
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP type hierarchy requests are unavailable")
		return false
	end

	local ok, request_ids = pcall(
		vim.lsp.buf_request_all,
		source.bufnr,
		"textDocument/prepareTypeHierarchy",
		position_params(source),
		function(results)
			local prepared = {}
			for _, response in pairs(results or {}) do
				if type(response) == "table" and type(response.result) == "table" then
					vim.list_extend(prepared, response.result)
				end
			end
			if #prepared == 0 then
				callback({}, nil)
				return
			end

			local pending = #prepared
			local raw_items = {}
			local first_err
			local done = false
			local function finish()
				if pending == 0 and not done then
					done = true
					callback(M.normalize(raw_items, direction), first_err)
				end
			end
			for _, item in ipairs(prepared) do
				local request_ok, type_request_ids = pcall(
					vim.lsp.buf_request_all,
					source.bufnr,
					method,
					{ item = item },
					function(type_results)
						for _, response in pairs(type_results or {}) do
							if type(response) == "table" and type(response.result) == "table" then
								vim.list_extend(raw_items, response.result)
							end
						end
						pending = pending - 1
						finish()
					end
				)
				if not request_ok then
					first_err = first_err or type_request_ids
					pending = pending - 1
					finish()
				elseif type(type_request_ids) == "table" and next(type_request_ids) == nil then
					first_err = first_err or "No attached LSP client supports type hierarchy"
					pending = pending - 1
					finish()
				end
			end
		end
	)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports type hierarchy")
		return false
	end
	return true
end

return M
