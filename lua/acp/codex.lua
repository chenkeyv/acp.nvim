local jsonrpc = require("acp.jsonrpc")

local M = {}

local function normalize_command(command)
	if type(command) == "string" then
		return { command, "app-server" }
	end
	if type(command) == "table" and type(command[1]) == "string" then
		return vim.deepcopy(command)
	end
	return { "codex", "app-server" }
end

local function present(value)
	return value ~= nil and value ~= vim.NIL
end

local function put(target, key, value)
	if present(value) then
		target[key] = value
	end
end

local function error_message(err, fallback)
	if type(err) == "table" then
		return err.message or fallback
	end
	if err ~= nil then
		return tostring(err)
	end
	return fallback
end

local Client = {}
Client.__index = Client

function Client.new(opts)
	opts = opts or {}
	return setmetatable({
		command = normalize_command(opts.command),
		cwd = opts.cwd,
		timeout_ms = tonumber(opts.timeout_ms) or 30000,
		client_info = vim.tbl_extend("force", {
			name = "acp_nvim",
			title = "acp.nvim",
			version = "0.2.0",
		}, opts.client_info or {}),
		capabilities = opts.capabilities,
		service_name = opts.service_name or "acp.nvim",
		spawn = opts.spawn or vim.system,
		check_executable = opts.check_executable ~= false and opts.spawn == nil,
		handle = nil,
		line_buffer = jsonrpc.LineBuffer.new(),
		next_id = 0,
		pending = {},
		initialized = false,
		initializing = false,
		initialize_waiters = {},
		initialize_result = nil,
		generation = 0,
		stopping = false,
		on_notification = opts.on_notification,
		on_request = opts.on_request,
		on_stderr = opts.on_stderr,
		on_exit = opts.on_exit,
		on_error = opts.on_error,
	}, Client)
end

function Client.adopt(instance)
	if type(instance) ~= "table" then
		return instance
	end
	setmetatable(instance, Client)
	if type(instance.line_buffer) == "table" then
		setmetatable(instance.line_buffer, jsonrpc.LineBuffer)
	end
	return instance
end

function Client:set_handlers(handlers)
	handlers = handlers or {}
	for _, name in ipairs({ "on_notification", "on_request", "on_stderr", "on_exit", "on_error" }) do
		if handlers[name] ~= nil then
			self[name] = handlers[name]
		end
	end
end

function Client:_emit(name, ...)
	local callback = self[name]
	if not callback then
		return
	end
	local ok, err = pcall(callback, ...)
	if not ok and name ~= "on_error" and self.on_error then
		pcall(self.on_error, tostring(err))
	end
end

function Client:_write(message)
	if not self.handle then
		return false, "Codex app-server is not running"
	end

	local ok, err = pcall(function()
		self.handle:write(vim.json.encode(message) .. "\n")
	end)
	if not ok then
		return false, tostring(err)
	end
	return true
end

function Client:_fail_pending(message)
	local pending = self.pending
	self.pending = {}
	for _, request in pairs(pending) do
		if request.callback then
			request.callback(nil, message)
		end
	end
end

function Client:_flush_initialize(ok, value)
	local waiters = self.initialize_waiters
	self.initialize_waiters = {}
	self.initializing = false
	for _, callback in ipairs(waiters) do
		callback(ok, value)
	end
end

function Client:_handle_exit(result, generation)
	if generation ~= self.generation then
		return
	end

	local expected = self.stopping
	self.handle = nil
	self.initialized = false
	self.initialize_result = nil
	self.line_buffer:reset()
	self.stopping = false
	local code = result and result.code or "?"
	local message = ("Codex app-server exited with code %s"):format(code)
	self:_fail_pending(message)
	if self.initializing then
		self:_flush_initialize(false, message)
	end
	if not expected then
		self:_emit("on_exit", result, message)
	end
end

function Client:start()
	if self.handle then
		return true
	end
	if self.check_executable and vim.fn.executable(self.command[1]) ~= 1 then
		return false, ("Codex executable not found: %s"):format(self.command[1])
	end

	self.generation = self.generation + 1
	local generation = self.generation
	self.stopping = false
	local options = {
		stdin = true,
		text = true,
		stdout = vim.schedule_wrap(function(err, data)
			if generation ~= self.generation then
				return
			end
			if err then
				self:_emit("on_error", ("Codex stdout error: %s"):format(err))
			elseif data then
				self.line_buffer:push(data, function(line)
					self:handle_line(line)
				end)
			end
		end),
		stderr = vim.schedule_wrap(function(_, data)
			if generation == self.generation and data and data ~= "" then
				self:_emit("on_stderr", data)
			end
		end),
	}
	if self.cwd and self.cwd ~= "" then
		options.cwd = self.cwd
	end

	local ok, handle = pcall(
		self.spawn,
		self.command,
		options,
		vim.schedule_wrap(function(result)
			self:_handle_exit(result, generation)
		end)
	)
	if not ok then
		return false, ("Failed to start Codex app-server: %s"):format(handle)
	end
	if not handle then
		return false, "Failed to start Codex app-server: no process handle returned"
	end
	self.handle = handle
	return true
end

function Client:_request(method, params, callback, timeout_ms)
	local id = self.next_id
	self.next_id = id + 1
	local request = { method = method, callback = callback }
	self.pending[id] = request

	local written, write_err = self:_write(jsonrpc.request(id, method, params))
	if not written then
		self.pending[id] = nil
		if callback then
			callback(nil, write_err)
		end
		return false
	end

	vim.defer_fn(function()
		if self.pending[id] ~= request then
			return
		end
		self.pending[id] = nil
		if callback then
			callback(nil, ("Codex request timed out: %s"):format(method))
		end
	end, timeout_ms or self.timeout_ms)
	return true
end

function Client:initialize(callback)
	callback = callback or function() end
	if self.initialized then
		callback(true, self.initialize_result)
		return true
	end

	table.insert(self.initialize_waiters, callback)
	if self.initializing then
		return true
	end
	self.initializing = true

	local started, start_err = self:start()
	if not started then
		self:_flush_initialize(false, start_err)
		return false
	end

	local params = { clientInfo = self.client_info }
	if type(self.capabilities) == "table" and next(self.capabilities) ~= nil then
		params.capabilities = self.capabilities
	end

	return self:_request("initialize", params, function(result, err)
		if err or type(result) ~= "table" then
			self:_flush_initialize(false, error_message(err, "Codex initialization failed"))
			return
		end

		self.initialize_result = result
		self.initialized = true
		local sent, notify_err = self:_write(jsonrpc.notification("initialized"))
		if not sent then
			self.initialized = false
			self:_flush_initialize(false, notify_err)
			return
		end
		self:_flush_initialize(true, result)
	end)
end

function Client:request(method, params, callback, timeout_ms)
	return self:initialize(function(ok, result_or_err)
		if not ok then
			if callback then
				callback(nil, result_or_err)
			end
			return
		end
		self:_request(method, params, callback, timeout_ms)
	end)
end

function Client:_reply(id, result, err)
	if err then
		local code = type(err) == "table" and err.code or jsonrpc.errors.internal_error
		local message = type(err) == "table" and err.message or tostring(err)
		return self:_write(jsonrpc.error(id, message, code, type(err) == "table" and err.data or nil))
	end
	return self:_write(jsonrpc.result(id, result))
end

function Client:handle_message(message)
	local has_id = message.id ~= nil and message.id ~= vim.NIL
	if has_id and not message.method then
		local pending = self.pending[message.id]
		if not pending then
			return
		end
		self.pending[message.id] = nil
		if pending.callback then
			if present(message.error) then
				pending.callback(nil, error_message(message.error, "Codex request failed"), message.error)
			else
				pending.callback(message.result, nil)
			end
		end
		return
	end

	if type(message.method) ~= "string" then
		return
	end
	local params = type(message.params) == "table" and message.params or {}
	if has_id then
		if not self.on_request then
			self:_reply(message.id, nil, {
				code = jsonrpc.errors.method_not_found,
				message = ("Unsupported Codex request: %s"):format(message.method),
			})
			return
		end

		local replied = false
		local function reply(result, err)
			if replied then
				return
			end
			replied = true
			self:_reply(message.id, result, err)
		end
		local ok, handled = pcall(self.on_request, message.method, params, reply)
		if not ok then
			reply(nil, tostring(handled))
		elseif handled == false then
			reply(nil, {
				code = jsonrpc.errors.method_not_found,
				message = ("Unsupported Codex request: %s"):format(message.method),
			})
		end
		return
	end

	self:_emit("on_notification", message.method, params)
end

function Client:handle_line(line)
	local message, err = jsonrpc.decode(line)
	if not message then
		self:_emit("on_error", ("Invalid Codex JSON: %s"):format(err))
		return
	end
	self:handle_message(message)
end

function Client:start_thread(opts, callback)
	opts = opts or {}
	local params = {}
	for _, pair in ipairs({
		{ "model", opts.model },
		{ "cwd", opts.cwd },
		{ "approvalPolicy", opts.approval_policy },
		{ "sandbox", opts.sandbox },
		{ "personality", opts.personality },
		{ "serviceTier", opts.service_tier },
	}) do
		put(params, pair[1], pair[2])
	end
	params.serviceName = opts.service_name or self.service_name
	return self:request("thread/start", params, callback)
end

function Client:resume_thread(thread_id, opts, callback)
	opts = opts or {}
	local params = { threadId = thread_id }
	for _, pair in ipairs({
		{ "model", opts.model },
		{ "cwd", opts.cwd },
		{ "approvalPolicy", opts.approval_policy },
		{ "sandbox", opts.sandbox },
		{ "personality", opts.personality },
		{ "serviceTier", opts.service_tier },
	}) do
		put(params, pair[1], pair[2])
	end
	return self:request("thread/resume", params, callback)
end

function Client:list_threads(opts, callback)
	opts = opts or {}
	local collected = {}
	local seen = {}
	local max_threads = math.max(1, tonumber(opts.max_threads) or 200)

	local function page(cursor)
		local params = {
			limit = math.min(100, max_threads - #collected),
			sortKey = opts.sort_key or "updated_at",
			sortDirection = opts.sort_direction or "desc",
		}
		put(params, "cwd", opts.cwd)
		put(params, "sourceKinds", opts.source_kinds)
		put(params, "archived", opts.archived)
		put(params, "cursor", cursor)
		self:request("thread/list", params, function(result, err)
			if err or type(result) ~= "table" then
				callback(nil, error_message(err, "Failed to list Codex threads"))
				return
			end
			for _, thread in ipairs(result.data or {}) do
				table.insert(collected, thread)
				if #collected >= max_threads then
					break
				end
			end
			local next_cursor = result.nextCursor
			if present(next_cursor) and not seen[next_cursor] and #collected < max_threads then
				seen[next_cursor] = true
				page(next_cursor)
			else
				callback(collected)
			end
		end)
	end

	page(nil)
	return true
end

function Client:list_models(callback)
	local models = {}
	local seen = {}
	local function page(cursor)
		local params = { limit = 100, includeHidden = false }
		put(params, "cursor", cursor)
		self:request("model/list", params, function(result, err)
			if err or type(result) ~= "table" then
				callback(nil, error_message(err, "Failed to list Codex models"))
				return
			end
			vim.list_extend(models, result.data or {})
			if present(result.nextCursor) and not seen[result.nextCursor] then
				seen[result.nextCursor] = true
				page(result.nextCursor)
			else
				callback(models)
			end
		end)
	end
	page(nil)
	return true
end

function Client:list_skills(cwd, callback)
	return self:request("skills/list", { cwds = { cwd } }, callback)
end

function Client:list_apps(thread_id, callback)
	local params = { forceRefresh = false }
	put(params, "threadId", thread_id)
	return self:request("app/installed", params, function(result, err)
		if err or type(result) ~= "table" then
			callback(nil, error_message(err, "Failed to list installed Codex apps"))
			return
		end
		callback(result.apps or {})
	end)
end

function Client:search_files(query, roots, callback)
	return self:request("fuzzyFileSearch", { query = query or "", roots = roots or {} }, callback)
end

local function turn_params(thread_id, payload)
	payload = payload or {}
	local params = {
		threadId = thread_id,
		input = payload.input or {
			{ type = "text", text = payload.text or "", text_elements = {} },
		},
	}
	for _, pair in ipairs({
		{ "additionalContext", payload.additional_context },
		{ "cwd", payload.cwd },
		{ "model", payload.model },
		{ "effort", payload.effort },
		{ "personality", payload.personality },
		{ "serviceTier", payload.service_tier },
		{ "approvalPolicy", payload.approval_policy },
		{ "sandboxPolicy", payload.sandbox_policy },
	}) do
		put(params, pair[1], pair[2])
	end
	return params
end

function Client:start_turn(thread_id, payload, callback)
	return self:request("turn/start", turn_params(thread_id, payload), callback)
end

function Client:steer_turn(thread_id, turn_id, payload, callback)
	local params = turn_params(thread_id, payload)
	params.expectedTurnId = turn_id
	params.cwd = nil
	params.model = nil
	params.effort = nil
	params.personality = nil
	params.serviceTier = nil
	params.approvalPolicy = nil
	params.sandboxPolicy = nil
	return self:request("turn/steer", params, callback)
end

function Client:interrupt_turn(thread_id, turn_id, callback)
	return self:request("turn/interrupt", { threadId = thread_id, turnId = turn_id }, callback)
end

function Client:unsubscribe_thread(thread_id, callback)
	return self:request("thread/unsubscribe", { threadId = thread_id }, callback)
end

function Client:set_thread_name(thread_id, name, callback)
	return self:request("thread/name/set", { threadId = thread_id, name = name }, callback)
end

function Client:review(thread_id, target, delivery, callback)
	return self:request("review/start", {
		threadId = thread_id,
		target = target or { type = "uncommittedChanges" },
		delivery = delivery or "inline",
	}, callback)
end

function Client:compact(thread_id, callback)
	return self:request("thread/compact/start", { threadId = thread_id }, callback)
end

function Client:read_account(callback)
	return self:request("account/read", { refreshToken = false }, callback)
end

function Client:login(callback)
	return self:request("account/login/start", {
		type = "chatgpt",
		codexStreamlinedLogin = true,
		useHostedLoginSuccessPage = true,
	}, callback)
end

function Client:stop()
	if not self.handle then
		return
	end
	local handle = self.handle
	self.stopping = true
	self.handle = nil
	self.initialized = false
	self.initialize_result = nil
	self.generation = self.generation + 1
	self.line_buffer:reset()
	self:_fail_pending("Codex app-server stopped")
	if self.initializing then
		self:_flush_initialize(false, "Codex app-server stopped")
	end
	pcall(function()
		handle:kill(15)
	end)
end

M.Client = Client

return M
