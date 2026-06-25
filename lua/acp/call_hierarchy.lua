local context = require("acp.context")
local chrome = require("acp.picker_chrome")
local icons = require("acp.icons")
local references = require("acp.references")
local symbols = require("acp.symbols")

local M = {}

local methods = {
	incoming = "callHierarchy/incomingCalls",
	outgoing = "callHierarchy/outgoingCalls",
}

local labels = {
	incoming = {
		title = "ACP Incoming Calls",
		noun = "incoming call",
		label = "INCOMING CALL",
		relation = "caller",
	},
	outgoing = {
		title = "ACP Outgoing Calls",
		noun = "outgoing call",
		label = "OUTGOING CALL",
		relation = "callee",
	},
}

local function call_item(call, direction)
	if type(call) ~= "table" then
		return nil
	end
	if direction == "outgoing" then
		return call.to
	end
	return call.from
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

local function spec(direction)
	return labels[direction] or labels.incoming
end

function M.location(call)
	return call and call.location or nil
end

function M.range(call)
	return references.range(M.location(call))
end

function M.bufnr(call)
	return references.bufnr(M.location(call))
end

function M.display_path(call)
	return references.display_path(M.location(call))
end

function M.normalize(results, direction)
	local items = {}
	for _, call in ipairs(results or {}) do
		local item = call_item(call, direction)
		local location = item_location(item)
		if type(item) == "table" and type(item.name) == "string" and item.name ~= "" and references.range(location) then
			table.insert(items, {
				name = item.name,
				kind = item.kind,
				detail = item.detail,
				location = location,
				ranges = call.fromRanges,
				direction = direction or "incoming",
			})
		end
	end
	return items
end

function M.picker_lines(items, opts)
	opts = opts or {}
	local lines = { chrome.title(icons.call, opts.title or spec(opts.direction).title), "" }
	local line_calls = {}
	for index, call in ipairs(items or {}) do
		local range = M.range(call)
		local location = range and ("%s:%d"):format(M.display_path(call), range.line1) or M.display_path(call)
		table.insert(
			lines,
			chrome.row(index, icons.call, ("%s  %s  %s"):format(call.name, symbols.kind_name(call.kind), location))
		)
		line_calls[#lines] = call
		if call.detail and call.detail ~= "" then
			table.insert(lines, chrome.detail(icons.note, call.detail))
			line_calls[#lines] = call
		end
	end

	table.insert(lines, "")
	table.insert(lines, chrome.footer("Press <Enter> to add context, Q for quickfix, or q/<Esc> to close."))
	return lines, line_calls
end

function M.quickfix_items(items, opts)
	opts = opts or {}
	local label = opts.label or spec(opts.direction).label
	local qf_items = {}
	for _, call in ipairs(items or {}) do
		local bufnr = M.bufnr(call)
		local range = M.range(call)
		if bufnr and range then
			table.insert(qf_items, {
				bufnr = bufnr,
				lnum = range.line1,
				col = range.col1 or 1,
				end_lnum = range.line2,
				end_col = range.col2 or range.col1 or 1,
				text = ("%s: %s (%s)"):format(label, call.name or "?", symbols.kind_name(call.kind)),
			})
		end
	end
	return qf_items
end

function M.prompt(call, direction)
	local bufnr, err = M.bufnr(call)
	if not bufnr then
		return nil, err
	end
	local range = M.range(call)
	if not range then
		return nil, "LSP call hierarchy item has no range"
	end

	local call_source = context.capture(bufnr, nil, range)
	if call_source then
		call_source.cursor = { range.line1, 0 }
	end
	local rendered_context = context.render(call_source, {
		treesitter_text_lines = 32,
		selection_limit = 100,
	})
	if not rendered_context then
		return nil, "Failed to render LSP call hierarchy context"
	end

	local current = spec(direction or call.direction)
	return table.concat({
		("Use this LSP %s as context: %s (%s)."):format(current.noun, call.name, symbols.kind_name(call.kind)),
		("Call %s: %s:%d"):format(current.relation, M.display_path(call), range.line1),
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
		callback(nil, "Unknown LSP call hierarchy direction")
		return false
	end
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP call hierarchy requests are unavailable")
		return false
	end

	local ok, request_ids = pcall(
		vim.lsp.buf_request_all,
		source.bufnr,
		"textDocument/prepareCallHierarchy",
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
			local raw_calls = {}
			local first_err
			local done = false
			local function finish()
				if pending == 0 and not done then
					done = true
					callback(M.normalize(raw_calls, direction), first_err)
				end
			end
			for _, item in ipairs(prepared) do
				local request_ok, call_request_ids = pcall(
					vim.lsp.buf_request_all,
					source.bufnr,
					method,
					{ item = item },
					function(call_results)
						for _, response in pairs(call_results or {}) do
							if type(response) == "table" and type(response.result) == "table" then
								vim.list_extend(raw_calls, response.result)
							end
						end
						pending = pending - 1
						finish()
					end
				)
				if not request_ok then
					first_err = first_err or call_request_ids
					pending = pending - 1
					finish()
				elseif type(call_request_ids) == "table" and next(call_request_ids) == nil then
					first_err = first_err or "No attached LSP client supports call hierarchy"
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
		callback(nil, "No attached LSP client supports call hierarchy")
		return false
	end
	return true
end

return M
