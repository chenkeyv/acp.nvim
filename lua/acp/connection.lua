local jsonrpc = require("acp.jsonrpc")

local M = {}

local methods = {
	initialize = "initialize",
	authenticate = "authenticate",
	session_new = "session/new",
	session_prompt = "session/prompt",
	session_update = "session/update",
	session_request_permission = "session/request_permission",
	fs_read_text_file = "fs/read_text_file",
	fs_write_text_file = "fs/write_text_file",
}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "ACP" })
end

local function executable_exists(command)
	return vim.fn.executable(command[1]) == 1
end

local function resolve_path(path, cwd)
	if not path or path == "" then
		return nil
	end
	if vim.fs.is_absolute and vim.fs.is_absolute(path) then
		return vim.fs.normalize(path)
	end
	if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") or path:sub(1, 2) == "\\\\" then
		return vim.fs.normalize(path)
	end
	return vim.fs.normalize(vim.fs.joinpath(cwd, path))
end

local function path_is_inside(path, root)
	local normalized_path = vim.fs.normalize(path)
	local normalized_root = vim.fs.normalize(root):gsub("/$", "")
	return normalized_path == normalized_root or normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
end

local function allowed_path(path, cwd)
	local roots = { vim.fs.normalize(cwd) }
	local real_cwd = vim.uv.fs_realpath(cwd)
	if real_cwd then
		table.insert(roots, vim.fs.normalize(real_cwd))
	end

	local real_path = vim.uv.fs_realpath(path)
	local candidates = { vim.fs.normalize(path) }
	if real_path then
		table.insert(candidates, vim.fs.normalize(real_path))
	end

	for _, candidate in ipairs(candidates) do
		for _, root in ipairs(roots) do
			if path_is_inside(candidate, root) then
				return true
			end
		end
	end

	return false
end

local function read_text_file(path, params)
	local lines = vim.fn.readfile(path)
	local start_line = tonumber(params.line) or 1
	local limit = tonumber(params.limit) or #lines
	local out = {}

	for line_number = start_line, math.min(#lines, start_line + limit - 1) do
		table.insert(out, lines[line_number])
	end

	return table.concat(out, "\n")
end

local function write_text_file(path, content)
	local parent = vim.fs.dirname(path)
	if parent and parent ~= "" then
		vim.fn.mkdir(parent, "p")
	end
	vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
end

local Connection = {}
Connection.__index = Connection

function Connection.new(config)
	return setmetatable({
		adapter = config.adapter,
		cwd = config.cwd or vim.fn.getcwd(),
		handle = nil,
		line_buffer = jsonrpc.LineBuffer.new(),
		next_id = 1,
		pending = {},
		session_id = nil,
		initialized = false,
		authenticated = false,
		active_handlers = nil,
	}, Connection)
end

function Connection:next_request_id()
	local id = self.next_id
	self.next_id = id + 1
	return id
end

function Connection:write(message)
	if not self.handle then
		return false
	end

	local ok, err = pcall(function()
		self.handle:write(vim.json.encode(message) .. "\n")
	end)
	if not ok then
		notify(("Failed to write ACP message: %s"):format(err), vim.log.levels.ERROR)
		return false
	end
	return true
end

function Connection:send_result(id, result)
	self:write(jsonrpc.result(id, result))
end

function Connection:send_error(id, message, code)
	self:write(jsonrpc.error(id, message, code))
end

function Connection:request(method, params, timeout_ms)
	local id = self:next_request_id()
	self.pending[id] = {}

	if not self:write(jsonrpc.request(id, method, params)) then
		self.pending[id] = nil
		return nil
	end

	local ok = vim.wait(timeout_ms or self.adapter.timeout_ms or 20000, function()
		return self.pending[id] and self.pending[id].done
	end, 10)

	local response = self.pending[id]
	self.pending[id] = nil

	if not response then
		notify(("ACP request was interrupted: %s"):format(method), vim.log.levels.ERROR)
		return nil
	end

	if not ok then
		notify(("ACP request timed out: %s"):format(method), vim.log.levels.ERROR)
		return nil
	end

	if response.error then
		notify(response.error.message or ("ACP request failed: " .. method), vim.log.levels.ERROR)
		return nil
	end

	return response.result
end

function Connection:start()
	if self.handle then
		return true
	end

	if not executable_exists(self.adapter.command) then
		notify(("Missing ACP agent command: %s"):format(table.concat(self.adapter.command, " ")), vim.log.levels.ERROR)
		return false
	end

	local ok, handle = pcall(
		vim.system,
		self.adapter.command,
		{
			cwd = self.cwd,
			stdin = true,
			stdout = vim.schedule_wrap(function(err, data)
				if err then
					notify(("ACP stdout error: %s"):format(err), vim.log.levels.ERROR)
				elseif data then
					self.line_buffer:push(data, function(line)
						self:handle_line(line)
					end)
				end
			end),
			stderr = vim.schedule_wrap(function(_, data)
				if data and data ~= "" and self.active_handlers and self.active_handlers.stderr then
					self.active_handlers.stderr(data)
				end
			end),
		},
		vim.schedule_wrap(function(result)
			self:handle_exit(result)
		end)
	)

	if not ok then
		notify(("Failed to start ACP agent: %s"):format(handle), vim.log.levels.ERROR)
		return false
	end

	self.handle = handle
	return true
end

function Connection:initialize()
	if self.initialized then
		return true
	end
	if not self:start() then
		return false
	end

	local result = self:request(methods.initialize, {
		protocolVersion = 1,
		clientCapabilities = {
			fs = {
				readTextFile = true,
				writeTextFile = true,
			},
			terminal = false,
		},
		clientInfo = {
			name = "keyv.nvim-acp",
			version = "0.1.0",
		},
	})
	if not result then
		return false
	end

	self.agent_info = result
	self.initialized = true

	return self:authenticate()
end

function Connection:authenticate()
	if self.authenticated then
		return true
	end

	local auth_methods = self.agent_info and self.agent_info.authMethods or {}
	if #auth_methods > 0 then
		local selected = self.adapter.auth_method
		local selected_id
		for _, method in ipairs(auth_methods) do
			if method.id == selected then
				selected_id = method.id
				break
			end
		end
		selected_id = selected_id or auth_methods[1].id
		if selected_id and not self:request(methods.authenticate, { methodId = selected_id }) then
			return false
		end
	end

	self.authenticated = true
	return true
end

function Connection:ensure_session()
	if self.session_id then
		return true
	end
	if not self:initialize() then
		return false
	end

	local result = self:request(methods.session_new, {
		cwd = self.cwd,
		mcpServers = self.adapter.mcp_servers or {},
	})
	if not result or not result.sessionId then
		notify("ACP agent did not create a session", vim.log.levels.ERROR)
		return false
	end

	self.session_id = result.sessionId
	return true
end

function Connection:prompt(text, handlers)
	if not self:ensure_session() then
		return false
	end

	self.active_handlers = handlers
	local id = self:next_request_id()
	self.pending[id] = { async = true }

	local ok = self:write(jsonrpc.request(id, methods.session_prompt, {
		sessionId = self.session_id,
		prompt = {
			{
				type = "text",
				text = text,
			},
		},
	}))

	if not ok then
		self.pending[id] = nil
	end

	return ok
end

local function extract_text(content)
	if type(content) ~= "table" then
		return nil
	end
	if content.type == "text" and type(content.text) == "string" then
		return content.text
	end
	if content.type == "resource_link" and type(content.uri) == "string" then
		return ("[resource: %s]"):format(content.uri)
	end
	if content.type == "image" then
		return "[image]"
	end
	if content.type == "audio" then
		return "[audio]"
	end
end

function Connection:handle_session_update(update)
	if not self.active_handlers or type(update) ~= "table" then
		return
	end

	if update.sessionUpdate == "agent_message_chunk" then
		local text = extract_text(update.content)
		if text and text ~= "" and self.active_handlers.message_chunk then
			self.active_handlers.message_chunk(text)
		end
	elseif update.sessionUpdate == "agent_thought_chunk" then
		local text = extract_text(update.content)
		if text and text ~= "" and self.active_handlers.thought_chunk then
			self.active_handlers.thought_chunk(text)
		end
	elseif update.sessionUpdate == "tool_call" and self.active_handlers.tool_call then
		self.active_handlers.tool_call(update)
	elseif update.sessionUpdate == "tool_call_update" and self.active_handlers.tool_update then
		self.active_handlers.tool_update(update)
	elseif update.sessionUpdate == "session_info_update" and self.active_handlers.session_info then
		self.active_handlers.session_info(update)
	elseif update.sessionUpdate == "usage_update" and self.active_handlers.usage then
		self.active_handlers.usage(update)
	end
end

function Connection:handle_permission_request(id, params)
	local options = params.options or {}
	if #options == 0 then
		return self:send_error(id, "Permission request has no options", jsonrpc.errors.invalid_params)
	end

	local labels = vim.tbl_map(function(option)
		return option.name or option.kind or option.optionId
	end, options)

	vim.ui.select(labels, {
		prompt = params.toolCall and params.toolCall.title or "ACP permission request",
	}, function(choice, index)
		if not choice or not index then
			return self:send_error(id, "Permission request cancelled", jsonrpc.errors.internal_error)
		end
		self:send_result(id, { outcome = options[index].optionId })
	end)
end

function Connection:handle_fs_read(id, params)
	local path = resolve_path(params and params.path, self.cwd)
	if not path then
		return self:send_error(id, "Invalid path", jsonrpc.errors.invalid_params)
	end
	if not allowed_path(path, self.cwd) then
		return self:send_error(id, "Refusing to read outside cwd", jsonrpc.errors.invalid_params)
	end

	local ok, content = pcall(read_text_file, path, params or {})
	if ok then
		return self:send_result(id, { content = content })
	end

	if tostring(content):find("ENOENT", 1, true) then
		return self:send_result(id, { content = "" })
	end

	self:send_error(id, ("Read failed: %s"):format(content))
end

function Connection:handle_fs_write(id, params)
	local path = resolve_path(params and params.path, self.cwd)
	local content = params and params.content
	if not path or type(content) ~= "string" then
		return self:send_error(id, "Invalid write request", jsonrpc.errors.invalid_params)
	end
	if not allowed_path(path, self.cwd) then
		return self:send_error(id, "Refusing to write outside cwd", jsonrpc.errors.invalid_params)
	end

	local ok, err = pcall(write_text_file, path, content)
	if ok then
		if self.active_handlers and self.active_handlers.file_written then
			self.active_handlers.file_written(path)
		end
		return self:send_result(id, nil)
	end

	self:send_error(id, ("Write failed: %s"):format(err))
end

function Connection:handle_request(message)
	if
		message.params
		and message.params.sessionId
		and self.session_id
		and message.params.sessionId ~= self.session_id
	then
		return self:send_error(message.id, "Invalid sessionId", jsonrpc.errors.invalid_params)
	end

	if message.method == methods.session_update then
		return self:handle_session_update(message.params and message.params.update)
	elseif message.method == methods.session_request_permission then
		return self:handle_permission_request(message.id, message.params or {})
	elseif message.method == methods.fs_read_text_file then
		return self:handle_fs_read(message.id, message.params or {})
	elseif message.method == methods.fs_write_text_file then
		return self:handle_fs_write(message.id, message.params or {})
	elseif message.id then
		return self:send_error(message.id, "Method not found", jsonrpc.errors.method_not_found)
	end
end

function Connection:handle_line(line)
	local message, err = jsonrpc.decode(line)
	if not message then
		notify(("Invalid ACP JSON: %s"):format(err), vim.log.levels.ERROR)
		return
	end

	if message.id and not message.method then
		local pending = self.pending[message.id]
		local async = pending and pending.async
		if pending then
			pending.done = true
			pending.result = message.result
			pending.error = message.error
		end
		if message.result and message.result.stopReason and self.active_handlers and self.active_handlers.done then
			self.active_handlers.done(message.result.stopReason)
			self.active_handlers = nil
		elseif message.error and self.active_handlers and self.active_handlers.error then
			self.active_handlers.error(message.error.message or "ACP request failed")
			self.active_handlers = nil
		end
		if async then
			self.pending[message.id] = nil
		end
	elseif message.method then
		self:handle_request(message)
	end
end

function Connection:handle_exit(result)
	local code = result and result.code or "?"
	if self.active_handlers and self.active_handlers.error then
		self.active_handlers.error(("ACP agent exited with code %s"):format(code))
	end

	for _, pending in pairs(self.pending) do
		pending.done = true
		pending.error = {
			message = ("ACP agent exited with code %s"):format(code),
		}
	end

	self.handle = nil
	self.initialized = false
	self.authenticated = false
	self.session_id = nil
	self.active_handlers = nil
end

function Connection:stop()
	if self.handle then
		self.handle:kill(15)
	end
	self.handle = nil
	self.active_handlers = nil
end

M.Connection = Connection

return M
