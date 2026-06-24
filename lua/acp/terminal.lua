local M = {}

local Manager = {}
Manager.__index = Manager

local function trim_to_byte_limit(text, limit)
	if not limit or limit < 0 or #text <= limit then
		return text, false
	end

	if limit == 0 then
		return "", text ~= ""
	end

	local start = #text - limit + 1
	while start <= #text do
		local candidate = text:sub(start)
		if pcall(vim.str_utfindex, candidate) then
			return candidate, true
		end
		start = start + 1
	end

	return "", true
end

local function exit_status(result)
	result = result or {}
	return {
		exitCode = result.code ~= nil and result.code or vim.NIL,
		signal = result.signal ~= nil and tostring(result.signal) or vim.NIL,
	}
end

local function command_parts(command, args)
	local parts = { command }
	for _, arg in ipairs(args or {}) do
		table.insert(parts, arg)
	end
	return parts
end

local function notify_waiters(term)
	for _, callback in ipairs(term.waiters) do
		callback(term.exit_status)
	end
	term.waiters = {}
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		next_id = 1,
		terminals = {},
		on_output = opts.on_output,
	}, Manager)
end

function Manager:append_output(term, data)
	if not term or not data or data == "" then
		return
	end

	local output, truncated = trim_to_byte_limit(term.output .. data, term.output_limit)
	term.output = output
	term.truncated = term.truncated or truncated

	if term.embedded and self.on_output then
		self.on_output({
			terminal_id = term.id,
			text = data,
			output = term.output,
			truncated = term.truncated,
		})
	end
end

function Manager:create(opts)
	opts = opts or {}
	local id = ("terminal-%d"):format(self.next_id)
	self.next_id = self.next_id + 1

	local term = {
		id = id,
		output = "",
		truncated = false,
		output_limit = opts.output_limit,
		exit_status = nil,
		waiters = {},
		embedded = false,
		handle = nil,
	}
	self.terminals[id] = term

	local ok, handle = pcall(vim.system, command_parts(opts.command, opts.args), {
		cwd = opts.cwd,
		env = opts.env,
		stdout = vim.schedule_wrap(function(_, data)
			self:append_output(term, data)
		end),
		stderr = vim.schedule_wrap(function(_, data)
			self:append_output(term, data)
		end),
	}, vim.schedule_wrap(function(result)
		term.exit_status = exit_status(result)
		term.handle = nil
		notify_waiters(term)
	end))

	if not ok then
		self.terminals[id] = nil
		return nil, handle
	end

	term.handle = handle
	return term, nil
end

function Manager:output(id)
	local term = self.terminals[id]
	if not term then
		return nil
	end

	local result = {
		output = term.output,
		truncated = term.truncated,
	}
	if term.exit_status then
		result.exitStatus = term.exit_status
	end
	return result
end

function Manager:wait(id, callback)
	local term = self.terminals[id]
	if not term then
		return false
	end
	if term.exit_status then
		callback(term.exit_status)
	else
		table.insert(term.waiters, callback)
	end
	return true
end

function Manager:kill(id)
	local term = self.terminals[id]
	if not term then
		return false
	end
	if term.handle then
		pcall(function()
			term.handle:kill(15)
		end)
	end
	return true
end

function Manager:release(id)
	local term = self.terminals[id]
	if not term then
		return false
	end
	self:kill(id)
	term.waiters = {}
	self.terminals[id] = nil
	return true
end

function Manager:release_all()
	local ids = {}
	for id in pairs(self.terminals) do
		table.insert(ids, id)
	end
	for _, id in ipairs(ids) do
		self:release(id)
	end
end

function Manager:embed(id)
	local term = self.terminals[id]
	if not term then
		return nil
	end
	term.embedded = true
	return self:output(id)
end

return M
