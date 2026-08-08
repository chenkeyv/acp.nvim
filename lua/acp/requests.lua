local approval = require("acp.approval")
local permission = require("acp.permission")

local M = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Codex" })
end

local function ask_text(question, callback)
	local prompt = (question.header or "Codex") .. ": "
	if question.isSecret then
		local ok, value = pcall(vim.fn.inputsecret, prompt)
		callback(ok and value ~= "" and { value } or {})
		return
	end
	vim.ui.input({
		prompt = prompt,
	}, function(value)
		callback(value and value ~= "" and { value } or {})
	end)
end

local function ask_question(question, callback)
	local choices = type(question.options) == "table" and vim.deepcopy(question.options) or {}
	if #choices == 0 then
		ask_text(question, callback)
		return
	end
	if question.isOther then
		table.insert(choices, { label = "Other…", other = true })
	end

	vim.ui.select(choices, {
		prompt = question.question or question.header or "Codex needs input",
		format_item = function(item)
			if type(item.description) == "string" and item.description ~= "" then
				return ("%s — %s"):format(item.label, item.description)
			end
			return item.label
		end,
	}, function(choice)
		if not choice then
			callback({})
		elseif choice.other then
			ask_text(question, callback)
		else
			callback({ choice.label })
		end
	end)
end

local function request_user_input(params, reply)
	local questions = params.questions or {}
	local answers = vim.empty_dict()
	local index = 0

	local function next_question()
		index = index + 1
		local question = questions[index]
		if not question then
			reply({ answers = answers })
			return
		end
		ask_question(question, function(values)
			answers[question.id] = { answers = values }
			next_question()
		end)
	end

	next_question()
	return true
end

local function inspect_permission(value)
	if value == nil or value == vim.NIL then
		return nil
	end
	return vim.inspect(value)
end

local function requested_permissions(params)
	local requested = params.permissions or {}
	local granted = vim.empty_dict()
	if requested.network and requested.network ~= vim.NIL then
		granted.network = requested.network
	end
	if requested.fileSystem and requested.fileSystem ~= vim.NIL then
		granted.fileSystem = requested.fileSystem
	end
	return granted
end

local function request_permissions(params, reply)
	local requested = params.permissions or {}
	permission.select({
		toolCall = {
			title = "Grant additional permissions",
			kind = "permission profile",
			description = params.reason,
			location = params.cwd,
		},
		details = {
			{ label = "Network", value = inspect_permission(requested.network) },
			{ label = "File system", value = inspect_permission(requested.fileSystem) },
		},
		options = {
			{ optionId = "turn", name = "Allow for this turn" },
			{ optionId = "session", name = "Allow for this session" },
			{ optionId = "decline", name = "Deny" },
		},
	}, function(option)
		local scope = option and option.optionId
		reply({
			permissions = (scope == "turn" or scope == "session") and requested_permissions(params) or vim.empty_dict(),
			scope = scope == "session" and "session" or "turn",
		})
	end)
	return true
end

local function mcp_elicitation(params, reply)
	if params.mode == "url" then
		local choices = {
			{ label = "Open and accept", action = "accept" },
			{ label = "Decline", action = "decline" },
			{ label = "Cancel", action = "cancel" },
		}
		vim.ui.select(choices, {
			prompt = params.message or ("Open request from " .. (params.serverName or "MCP server")),
			format_item = function(item)
				return item.label
			end,
		}, function(choice)
			if choice and choice.action == "accept" and vim.ui.open then
				pcall(vim.ui.open, params.url)
			end
			reply({ action = choice and choice.action or "cancel", content = vim.NIL, _meta = vim.NIL })
		end)
		return true
	end

	vim.ui.input({
		prompt = (params.message or ("Input requested by " .. (params.serverName or "MCP server"))) .. " (JSON): ",
		default = "{}",
	}, function(value)
		if not value or value == "" then
			reply({ action = "cancel", content = vim.NIL, _meta = vim.NIL })
			return
		end
		local ok, content = pcall(vim.json.decode, value)
		if not ok then
			notify("MCP form input was not valid JSON", vim.log.levels.ERROR)
			reply({ action = "cancel", content = vim.NIL, _meta = vim.NIL })
			return
		end
		reply({ action = "accept", content = content, _meta = vim.NIL })
	end)
	return true
end

function M.handle(method, params, reply)
	if approval.handle(method, params, reply) then
		return true
	end
	if method == "item/tool/requestUserInput" then
		return request_user_input(params, reply)
	end
	if method == "item/permissions/requestApproval" then
		return request_permissions(params, reply)
	end
	if method == "mcpServer/elicitation/request" then
		return mcp_elicitation(params, reply)
	end
	return false
end

return M
