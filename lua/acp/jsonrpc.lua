local M = {}

M.errors = {
	parse = -32700,
	invalid_request = -32600,
	method_not_found = -32601,
	invalid_params = -32602,
	internal_error = -32603,
}

local function params_or_empty(params)
	if params == nil or params == vim.NIL then
		return vim.empty_dict()
	end
	return params
end

-- Codex app-server uses JSON-RPC semantics but intentionally omits the
-- `jsonrpc = "2.0"` field on the wire.
function M.request(id, method, params)
	return {
		id = id,
		method = method,
		params = params_or_empty(params),
	}
end

function M.notification(method, params)
	local message = { method = method }
	if params ~= nil and params ~= vim.NIL then
		message.params = params
	end
	return message
end

function M.result(id, result)
	return {
		id = id,
		result = result == nil and vim.empty_dict() or result,
	}
end

function M.error(id, message, code, data)
	local err = {
		code = code or M.errors.internal_error,
		message = message,
	}
	if data ~= nil then
		err.data = data
	end
	return { id = id, error = err }
end

function M.decode(line)
	local ok, message = pcall(vim.json.decode, line)
	if not ok or type(message) ~= "table" then
		return nil, message
	end
	return message
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

function LineBuffer:reset()
	self.data = ""
end

M.LineBuffer = LineBuffer

return M
