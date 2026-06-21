local M = {}

M.errors = {
	parse = -32700,
	invalid_request = -32600,
	method_not_found = -32601,
	invalid_params = -32602,
	internal_error = -32603,
}

local function normalize_params(params)
	if not params or vim.tbl_isempty(params) then
		return vim.empty_dict()
	end
	return params
end

function M.request(id, method, params)
	return {
		jsonrpc = "2.0",
		id = id,
		method = method,
		params = normalize_params(params),
	}
end

function M.result(id, result)
	return {
		jsonrpc = "2.0",
		id = id,
		result = result == nil and vim.NIL or result,
	}
end

function M.error(id, message, code)
	return {
		jsonrpc = "2.0",
		id = id,
		error = {
			code = code or M.errors.internal_error,
			message = message,
		},
	}
end

function M.decode(line)
	local ok, message = pcall(vim.json.decode, line)
	if not ok or type(message) ~= "table" then
		return nil, message
	end
	return message, nil
end

local LineBuffer = {}
LineBuffer.__index = LineBuffer

function LineBuffer.new()
	return setmetatable({ data = "" }, LineBuffer)
end

function LineBuffer:push(data, callback)
	if not data or data == "" then
		return
	end

	self.data = self.data .. data

	while true do
		local newline = self.data:find("\n", 1, true)
		if not newline then
			break
		end

		local line = self.data:sub(1, newline - 1):gsub("\r$", "")
		self.data = self.data:sub(newline + 1)

		if line ~= "" then
			callback(line)
		end
	end
end

M.LineBuffer = LineBuffer

return M
