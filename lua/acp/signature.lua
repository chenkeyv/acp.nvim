local context = require("acp.context")

local M = {}

local function append_lines(out, text)
	if type(text) ~= "string" or text == "" then
		return
	end
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		table.insert(out, line)
	end
end

local function doc_lines(value)
	local out = {}
	if type(value) == "string" then
		append_lines(out, value)
	elseif type(value) == "table" and type(value.value) == "string" then
		append_lines(out, value.value)
	end
	return out
end

local function active_index(value, count)
	local index = tonumber(value) or 0
	index = index + 1
	if count and count > 0 then
		index = math.max(1, math.min(index, count))
	else
		index = math.max(1, index)
	end
	return index
end

local function parameter_label(parameter)
	if type(parameter) ~= "table" then
		return nil
	end
	if type(parameter.label) == "string" then
		return parameter.label
	end
	if type(parameter.label) == "table" then
		return ("%s-%s"):format(tostring(parameter.label[1] or "?"), tostring(parameter.label[2] or "?"))
	end
	return nil
end

function M.lines(result)
	if type(result) ~= "table" or type(result.signatures) ~= "table" or #result.signatures == 0 then
		return {}
	end

	local signature = result.signatures[active_index(result.activeSignature, #result.signatures)]
	if type(signature) ~= "table" or type(signature.label) ~= "string" or signature.label == "" then
		return {}
	end

	local lines = {
		("Signature: %s"):format(signature.label),
	}

	local docs = doc_lines(signature.documentation)
	if #docs > 0 then
		table.insert(lines, "Documentation:")
		vim.list_extend(lines, docs)
	end

	local parameters = signature.parameters or {}
	if #parameters > 0 then
		local active = active_index(signature.activeParameter or result.activeParameter, #parameters)
		table.insert(lines, "Parameters:")
		for index, parameter in ipairs(parameters) do
			local label = parameter_label(parameter) or ("parameter " .. index)
			local prefix = index == active and "* " or "- "
			table.insert(lines, prefix .. label)
			local parameter_docs = doc_lines(parameter.documentation)
			for _, doc in ipairs(parameter_docs) do
				table.insert(lines, ("  %s"):format(doc))
			end
		end
	end

	return lines
end

function M.text(result)
	local lines = M.lines(result)
	return #lines > 0 and table.concat(lines, "\n") or nil
end

function M.prompt(source, signature_text)
	local rendered_context = context.render(source, {
		treesitter_text_lines = 24,
		selection_limit = 80,
	})
	if not rendered_context then
		return nil
	end

	return table.concat({
		"Use this LSP signature help as context.",
		"",
		"Signature help:",
		signature_text,
		"",
		rendered_context,
	}, "\n")
end

function M.request(source, callback)
	if not vim.lsp or not vim.lsp.buf_request_all then
		callback(nil, "Neovim LSP signature-help requests are unavailable")
		return false
	end

	local cursor = source.cursor or { 1, 0 }
	local params = {
		textDocument = {
			uri = vim.uri_from_bufnr(source.bufnr),
		},
		position = {
			line = math.max(0, (cursor[1] or 1) - 1),
			character = math.max(0, cursor[2] or 0),
		},
	}

	local ok, request_ids = pcall(vim.lsp.buf_request_all, source.bufnr, "textDocument/signatureHelp", params, function(results)
		local docs = {}
		for _, response in pairs(results or {}) do
			if type(response) == "table" then
				local text = M.text(response.result)
				if text and text ~= "" then
					table.insert(docs, text)
				end
			end
		end
		callback(#docs > 0 and table.concat(docs, "\n\n") or nil, nil)
	end)

	if not ok then
		callback(nil, request_ids)
		return false
	end
	if type(request_ids) == "table" and next(request_ids) == nil then
		callback(nil, "No attached LSP client supports signature help")
		return false
	end
	return true
end

return M
