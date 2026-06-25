local jsonrpc = require("acp.jsonrpc")
local file_review = require("acp.file_review")
local icons = require("acp.icons")
local permission = require("acp.permission")
local terminal = require("acp.terminal")

local M = {}

local methods = {
	initialize = "initialize",
	authenticate = "authenticate",
	session_new = "session/new",
	session_list = "session/list",
	session_load = "session/load",
	session_resume = "session/resume",
	session_set_config_option = "session/set_config_option",
	session_prompt = "session/prompt",
	session_update = "session/update",
	session_request_permission = "session/request_permission",
	fs_read_text_file = "fs/read_text_file",
	fs_write_text_file = "fs/write_text_file",
	terminal_create = "terminal/create",
	terminal_output = "terminal/output",
	terminal_wait_for_exit = "terminal/wait_for_exit",
	terminal_kill = "terminal/kill",
	terminal_release = "terminal/release",
}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = icons.title("ACP") })
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

local function read_existing_text(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return ""
	end
	return table.concat(lines, "\n")
end

local function write_text_file(path, content)
	local parent = vim.fs.dirname(path)
	if parent and parent ~= "" then
		vim.fn.mkdir(parent, "p")
	end
	vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
end

local function file_write_review_delay(adapter)
	local delay = adapter and tonumber(adapter.file_write_review_delay_ms)
	if delay ~= nil then
		return delay
	end
	return 80
end

local function env_table(env)
	if type(env) ~= "table" then
		return nil
	end

	local out = {}
	for _, item in ipairs(env) do
		if type(item) == "table" and type(item.name) == "string" then
			out[item.name] = item.value ~= nil and tostring(item.value) or ""
		end
	end

	return next(out) and out or nil
end

local function string_list(value)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" then
		return nil
	end

	local out = {}
	for _, item in ipairs(value) do
		if type(item) ~= "string" then
			return nil
		end
		table.insert(out, item)
	end
	return out
end

local function command_display(command, args)
	local parts = { command }
	for _, arg in ipairs(args or {}) do
		table.insert(parts, arg)
	end
	return table.concat(parts, " ")
end

local function compact_decimal(value)
	return ("%.1f"):format(value):gsub("%.0$", "")
end

local function byte_count_label(value)
	local number = tonumber(value)
	if number == nil then
		return nil
	end
	if number < 1024 then
		return ("%d B"):format(number)
	end
	if number < 1024 * 1024 then
		return ("%s KiB"):format(compact_decimal(number / 1024))
	end
	return ("%s MiB"):format(compact_decimal(number / (1024 * 1024)))
end

local function terminal_output_limit_label(value)
	return byte_count_label(value) or "1 MiB (default)"
end

local function env_count(env)
	if type(env) ~= "table" then
		return 0
	end

	local count = 0
	for _, item in ipairs(env) do
		if type(item) == "table" and type(item.name) == "string" then
			count = count + 1
		end
	end
	return count
end

local function terminal_review_details(params, cwd, args)
	local details = {
		{
			label = "Command",
			value = command_display(params.command, args),
			icon = icons.terminal,
		},
		{
			label = "Working directory",
			value = cwd,
			icon = icons.location,
		},
		{
			label = "Output limit",
			value = terminal_output_limit_label(params.outputByteLimit),
			icon = icons.context,
		},
	}

	local count = env_count(params.env)
	if count > 0 then
		table.insert(details, {
			label = "Environment",
			value = ("%d variable(s)"):format(count),
			icon = icons.config,
		})
	end

	return details
end

local function agent_capabilities(connection)
	return (connection.agent_info and connection.agent_info.agentCapabilities) or {}
end

local function session_capabilities(connection)
	return agent_capabilities(connection).sessionCapabilities or {}
end

local function has_session_capability(connection, name)
	return session_capabilities(connection)[name] ~= nil
end

local function session_setup_params(connection, session_id, session_info)
	local params = {
		sessionId = session_id,
		cwd = connection.cwd,
		mcpServers = connection.adapter.mcp_servers or {},
	}

	if
		session_info
		and type(session_info.additionalDirectories) == "table"
		and has_session_capability(connection, "additionalDirectories")
	then
		params.additionalDirectories = session_info.additionalDirectories
	end

	return params
end

local Connection = {}
Connection.__index = Connection

function Connection.new(config)
	local connection = setmetatable({
		adapter = config.adapter,
		cwd = config.cwd or vim.fn.getcwd(),
		handle = nil,
		line_buffer = jsonrpc.LineBuffer.new(),
		next_id = 1,
		pending = {},
		pending_file_writes = {},
		file_write_review_scheduled = false,
		file_write_review_active = false,
		session_id = nil,
		initialized = false,
		authenticated = false,
		active_handlers = nil,
		config_options = nil,
	}, Connection)
	connection.terminals = terminal.new({
		on_output = function(event)
			connection:handle_terminal_output(event)
		end,
	})
	return connection
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

function Connection:request_async(method, params, callback, timeout_ms)
	local id = self:next_request_id()
	local pending = {
		callback = callback,
		method = method,
	}
	self.pending[id] = pending

	if not self:write(jsonrpc.request(id, method, params)) then
		self.pending[id] = nil
		if callback then
			callback(nil, ("ACP request failed to send: %s"):format(method))
		end
		return false
	end

	vim.defer_fn(function()
		if self.pending[id] ~= pending then
			return
		end

		self.pending[id] = nil
		local message = ("ACP request timed out: %s"):format(method)
		notify(message, vim.log.levels.ERROR)
		if callback then
			callback(nil, message)
		end
	end, timeout_ms or self.adapter.timeout_ms or 20000)

	return true
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
			terminal = true,
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

function Connection:authenticate_async(callback)
	if self.authenticated then
		callback(true)
		return true
	end

	local auth_methods = self.agent_info and self.agent_info.authMethods or {}
	if #auth_methods == 0 then
		self.authenticated = true
		callback(true)
		return true
	end

	local selected = self.adapter.auth_method
	local selected_id
	for _, method in ipairs(auth_methods) do
		if method.id == selected then
			selected_id = method.id
			break
		end
	end
	selected_id = selected_id or auth_methods[1].id
	if not selected_id then
		self.authenticated = true
		callback(true)
		return true
	end

	return self:request_async(methods.authenticate, { methodId = selected_id }, function(result, err)
		if not result then
			callback(false, err)
			return
		end

		self.authenticated = true
		callback(true)
	end)
end

function Connection:initialize_async(callback)
	if self.initialized then
		return self:authenticate_async(callback)
	end
	if not self:start() then
		callback(false, "failed to start ACP agent")
		return false
	end

	return self:request_async(methods.initialize, {
		protocolVersion = 1,
		clientCapabilities = {
			fs = {
				readTextFile = true,
				writeTextFile = true,
			},
			terminal = true,
		},
		clientInfo = {
			name = "keyv.nvim-acp",
			version = "0.1.0",
		},
	}, function(result, err)
		if not result then
			callback(false, err)
			return
		end

		self.agent_info = result
		self.initialized = true
		self:authenticate_async(callback)
	end)
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
	self:apply_session_state(result)
	return true
end

function Connection:ensure_session_async(callback)
	if self.session_id then
		callback(true, nil, {
			configOptions = self.config_options,
		})
		return true
	end

	return self:initialize_async(function(ok, err)
		if not ok then
			callback(false, err)
			return
		end

		self:request_async(methods.session_new, {
			cwd = self.cwd,
			mcpServers = self.adapter.mcp_servers or {},
		}, function(result, request_err)
			if not result or not result.sessionId then
				local message = request_err or "ACP agent did not create a session"
				notify(message, vim.log.levels.ERROR)
				callback(false, message)
				return
			end

			self.session_id = result.sessionId
			self:apply_session_state(result)
			callback(true, nil, result)
		end)
	end)
end

function Connection:list_sessions_async(callback)
	return self:initialize_async(function(ok, err)
		if not ok then
			callback(nil, err or "failed to initialize ACP agent")
			return
		end
		if not has_session_capability(self, "list") then
			callback(nil, "ACP agent does not support session/list")
			return
		end

		local sessions = {}
		local request_page
		request_page = function(cursor)
			local params = {
				cwd = self.cwd,
			}
			if cursor then
				params.cursor = cursor
			end

			self:request_async(methods.session_list, params, function(result, request_err)
				if request_err or type(result) ~= "table" then
					callback(nil, request_err or "ACP session list failed")
					return
				end

				for _, session in ipairs(result.sessions or {}) do
					table.insert(sessions, session)
				end

				if result.nextCursor then
					request_page(result.nextCursor)
				else
					callback(sessions, nil)
				end
			end)
		end

		request_page(nil)
	end)
end

function Connection:restore_session_async(session_info, handlers, callback)
	session_info = session_info or {}
	local session_id = session_info.sessionId
	if type(session_id) ~= "string" or session_id == "" then
		callback(false, "Invalid ACP session id")
		return false
	end

	return self:initialize_async(function(ok, err)
		if not ok then
			callback(false, err or "failed to initialize ACP agent")
			return
		end

		local method
		local mode
		if agent_capabilities(self).loadSession then
			method = methods.session_load
			mode = "load"
		elseif has_session_capability(self, "resume") then
			method = methods.session_resume
			mode = "resume"
		else
			callback(false, "ACP agent does not support session/load or session/resume")
			return
		end

		self.active_handlers = handlers
		self:request_async(method, session_setup_params(self, session_id, session_info), function(result, request_err)
			if request_err then
				if self.active_handlers == handlers then
					self.active_handlers = nil
				end
				callback(false, request_err or ("ACP session %s failed"):format(mode))
				return
			end

			self.session_id = session_id
			self:apply_session_state(result, handlers)
			callback(true, mode, result)
		end)
	end)
end

function Connection:apply_session_state(result, handlers)
	if type(result) ~= "table" then
		return
	end

	if type(result.configOptions) == "table" then
		self.config_options = result.configOptions
		local active = handlers or self.active_handlers
		if active and active.config_options then
			active.config_options(result.configOptions)
		end
	end
end

function Connection:set_config_option_async(config_id, value, callback)
	if not self.session_id then
		if callback then
			callback(false, "ACP session is not started")
		end
		return false
	end

	return self:request_async(methods.session_set_config_option, {
		sessionId = self.session_id,
		configId = config_id,
		value = value,
	}, function(result, request_err)
		if request_err or type(result) ~= "table" then
			if callback then
				callback(false, request_err or "ACP config update failed")
			end
			return
		end

		self:apply_session_state(result)
		if callback then
			callback(true, result)
		end
	end)
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

function Connection:prompt_async(text, handlers)
	handlers = handlers or {}

	return self:ensure_session_async(function(ok, err, session_result)
		if not ok then
			if handlers.error then
				handlers.error(err or "failed to start session")
			end
			return
		end

		self.active_handlers = handlers
		self:apply_session_state(session_result, handlers)
		local id = self:next_request_id()
		self.pending[id] = { async = true }

		local sent = self:write(jsonrpc.request(id, methods.session_prompt, {
			sessionId = self.session_id,
			prompt = {
				{
					type = "text",
					text = text,
				},
			},
		}))

		if not sent then
			self.pending[id] = nil
			if handlers.error then
				handlers.error("failed to send prompt")
			end
			return
		end

		if handlers.started then
			handlers.started()
		end
	end)
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

function Connection:handle_terminal_output(event)
	if self.active_handlers and self.active_handlers.terminal_output then
		self.active_handlers.terminal_output(event)
	end
end

function Connection:mark_embedded_terminals(content)
	if type(content) ~= "table" then
		return
	end

	for _, item in ipairs(content) do
		if type(item) == "table" and item.type == "terminal" and type(item.terminalId) == "string" then
			local snapshot = self.terminals and self.terminals:embed(item.terminalId)
			if snapshot and self.active_handlers and self.active_handlers.terminal_attach then
				self.active_handlers.terminal_attach({
					terminal_id = item.terminalId,
					output = snapshot.output,
					truncated = snapshot.truncated,
				})
			end
		end
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
	elseif update.sessionUpdate == "user_message_chunk" then
		local text = extract_text(update.content)
		if text and text ~= "" and self.active_handlers.user_message_chunk then
			self.active_handlers.user_message_chunk(text)
		end
	elseif update.sessionUpdate == "agent_thought_chunk" then
		local text = extract_text(update.content)
		if text and text ~= "" and self.active_handlers.thought_chunk then
			self.active_handlers.thought_chunk(text)
		end
	elseif update.sessionUpdate == "tool_call" then
		if self.active_handlers.tool_call then
			self.active_handlers.tool_call(update)
		end
		self:mark_embedded_terminals(update.content)
	elseif update.sessionUpdate == "tool_call_update" then
		if self.active_handlers.tool_update then
			self.active_handlers.tool_update(update)
		end
		self:mark_embedded_terminals(update.content)
	elseif update.sessionUpdate == "session_info_update" and self.active_handlers.session_info then
		self.active_handlers.session_info(update)
	elseif update.sessionUpdate == "usage_update" and self.active_handlers.usage then
		self.active_handlers.usage(update)
	elseif update.sessionUpdate == "available_commands_update" and self.active_handlers.available_commands then
		self.active_handlers.available_commands(update.availableCommands or {})
	elseif update.sessionUpdate == "config_option_update" then
		self:apply_session_state({
			configOptions = update.configOptions or {},
		})
	end
end

function Connection:handle_permission_request(id, params)
	local options = params.options or {}
	if #options == 0 then
		return self:send_error(id, "Permission request has no options", jsonrpc.errors.invalid_params)
	end

	permission.select(params, function(option)
		if not option then
			return self:send_error(id, "Permission request cancelled", jsonrpc.errors.internal_error)
		end
		self:send_result(id, { outcome = option.optionId })
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

function Connection:apply_file_write(request)
	local ok, err = pcall(write_text_file, request.path, request.content)
	if ok then
		if self.active_handlers and self.active_handlers.file_written then
			self.active_handlers.file_written(request.path)
		end
		return self:send_result(request.id, nil)
	end

	self:send_error(request.id, ("Write failed: %s"):format(err))
end

function Connection:flush_file_write_review()
	if self.file_write_review_active or #self.pending_file_writes == 0 then
		return
	end

	local batch = self.pending_file_writes
	self.pending_file_writes = {}
	self.file_write_review_active = true

	file_review.select({
		files = batch,
	}, function(approved)
		self.file_write_review_active = false
		if not approved then
			for _, request in ipairs(batch) do
				self:send_error(request.id, "File write cancelled", jsonrpc.errors.internal_error)
			end
		else
			for _, request in ipairs(batch) do
				self:apply_file_write(request)
			end
		end

		if #self.pending_file_writes > 0 then
			self:schedule_file_write_review()
		end
	end)
end

function Connection:schedule_file_write_review()
	if self.file_write_review_active or self.file_write_review_scheduled then
		return
	end

	local delay = file_write_review_delay(self.adapter)
	if delay <= 0 then
		self:flush_file_write_review()
		return
	end

	self.file_write_review_scheduled = true
	vim.defer_fn(function()
		self.file_write_review_scheduled = false
		self:flush_file_write_review()
	end, delay)
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

	table.insert(self.pending_file_writes, {
		id = id,
		path = path,
		display_path = vim.fn.fnamemodify(path, ":."),
		before = read_existing_text(path),
		after = content,
		content = content,
	})

	self:schedule_file_write_review()
end

function Connection:terminal_cwd(params)
	local cwd = params and params.cwd
	if not cwd or cwd == "" then
		return self.cwd
	end

	local path = resolve_path(cwd, self.cwd)
	if not path or not allowed_path(path, self.cwd) then
		return nil, "Refusing to run terminal outside cwd"
	end
	if vim.fn.isdirectory(path) == 0 then
		return nil, "Terminal cwd does not exist"
	end
	return path, nil
end

function Connection:run_terminal_create(id, params, cwd, args)
	local output_limit = tonumber(params.outputByteLimit)
	if output_limit == nil then
		output_limit = 1024 * 1024
	end

	local term, err = self.terminals:create({
		command = params.command,
		args = args,
		env = env_table(params.env),
		cwd = cwd,
		output_limit = output_limit,
	})
	if not term then
		return self:send_error(id, ("Terminal failed to start: %s"):format(err))
	end

	self:send_result(id, { terminalId = term.id })
end

function Connection:handle_terminal_create(id, params)
	if type(params.command) ~= "string" or params.command == "" then
		return self:send_error(id, "Invalid terminal command", jsonrpc.errors.invalid_params)
	end

	local args = string_list(params.args)
	if not args then
		return self:send_error(id, "Invalid terminal args", jsonrpc.errors.invalid_params)
	end

	local cwd, cwd_err = self:terminal_cwd(params)
	if not cwd then
		return self:send_error(id, cwd_err, jsonrpc.errors.invalid_params)
	end

	if self.adapter.terminal_auto_approve then
		return self:run_terminal_create(id, params, cwd, args)
	end

	permission.select({
		toolCall = {
			title = ("%s Run terminal command: %s"):format(icons.terminal, params.command),
			kind = "execute",
			status = ("output %s"):format(terminal_output_limit_label(params.outputByteLimit)),
			description = command_display(params.command, args),
			location = cwd,
		},
		details = terminal_review_details(params, cwd, args),
		options = {
			{
				optionId = "run",
				name = ("%s Run command"):format(icons.terminal),
				description = command_display(params.command, args),
			},
			{
				optionId = "cancel",
				name = ("%s Cancel"):format(icons.warning),
			},
		},
	}, function(option)
		if not option or option.optionId ~= "run" then
			return self:send_error(id, "Terminal command cancelled", jsonrpc.errors.internal_error)
		end

		self:run_terminal_create(id, params, cwd, args)
	end)
end

function Connection:handle_terminal_output_request(id, params)
	local result = self.terminals:output(params.terminalId)
	if not result then
		return self:send_error(id, "Terminal not found", jsonrpc.errors.invalid_params)
	end
	self:send_result(id, result)
end

function Connection:handle_terminal_wait_for_exit(id, params)
	if not self.terminals:wait(params.terminalId, function(status)
		self:send_result(id, status)
	end) then
		return self:send_error(id, "Terminal not found", jsonrpc.errors.invalid_params)
	end
end

function Connection:handle_terminal_kill(id, params)
	if not self.terminals:kill(params.terminalId) then
		return self:send_error(id, "Terminal not found", jsonrpc.errors.invalid_params)
	end
	self:send_result(id, nil)
end

function Connection:handle_terminal_release(id, params)
	if not self.terminals:release(params.terminalId) then
		return self:send_error(id, "Terminal not found", jsonrpc.errors.invalid_params)
	end
	self:send_result(id, nil)
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
	elseif message.method == methods.terminal_create then
		return self:handle_terminal_create(message.id, message.params or {})
	elseif message.method == methods.terminal_output then
		return self:handle_terminal_output_request(message.id, message.params or {})
	elseif message.method == methods.terminal_wait_for_exit then
		return self:handle_terminal_wait_for_exit(message.id, message.params or {})
	elseif message.method == methods.terminal_kill then
		return self:handle_terminal_kill(message.id, message.params or {})
	elseif message.method == methods.terminal_release then
		return self:handle_terminal_release(message.id, message.params or {})
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
		if pending and pending.callback then
			self.pending[message.id] = nil
			if message.error then
				pending.callback(nil, message.error.message or "ACP request failed", message.error)
			else
				pending.callback(message.result, nil)
			end
			return
		end

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
	self.pending_file_writes = {}
	self.terminals:release_all()

	local message = ("ACP agent exited with code %s"):format(code)
	for id, pending in pairs(self.pending) do
		if pending.callback then
			self.pending[id] = nil
			pending.callback(nil, message)
		else
			pending.done = true
			pending.error = {
				message = message,
			}
		end
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
	self.pending_file_writes = {}
	self.terminals:release_all()
	self.handle = nil
	self.active_handlers = nil
end

M.Connection = Connection

return M
