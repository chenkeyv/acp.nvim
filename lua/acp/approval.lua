local permission = require("acp.permission")

local M = {}

local labels = {
	accept = "Allow once",
	acceptForSession = "Allow for this session",
	decline = "Deny and continue",
	cancel = "Deny and stop the turn",
}

local function clean(value)
	if value == nil or value == vim.NIL then
		return ""
	end
	return tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function inspect(value)
	if value == nil or value == vim.NIL then
		return nil
	end
	return type(value) == "table" and vim.inspect(value) or tostring(value)
end

local function decision_option(decision)
	if type(decision) == "string" and labels[decision] then
		return {
			optionId = decision,
			name = labels[decision],
			description = decision == "acceptForSession" and "Remember this approval for the current Codex session"
				or nil,
		}
	end
	if type(decision) == "table" and decision.acceptWithExecpolicyAmendment then
		return {
			optionId = decision,
			name = "Allow and remember this command rule",
			description = inspect(decision.acceptWithExecpolicyAmendment.execpolicy_amendment),
		}
	end
	if type(decision) == "table" and decision.applyNetworkPolicyAmendment then
		return {
			optionId = decision,
			name = "Allow and update the network rule",
			description = inspect(decision.applyNetworkPolicyAmendment.network_policy_amendment),
		}
	end
end

local function v2_options(params)
	local decisions = params.availableDecisions
	if type(decisions) ~= "table" or #decisions == 0 then
		decisions = { "accept", "acceptForSession", "decline", "cancel" }
	end

	local options = {}
	for _, decision in ipairs(decisions) do
		local option = decision_option(decision)
		if option then
			table.insert(options, option)
		end
	end
	if #options == 0 then
		options = {
			{ optionId = "decline", name = labels.decline },
			{ optionId = "cancel", name = labels.cancel },
		}
	end
	return options
end

local function file_count(file_changes)
	local count = 0
	for _ in pairs(file_changes or {}) do
		count = count + 1
	end
	return count
end

local function select_v2(method, params, reply)
	local is_file = method == "item/fileChange/requestApproval"
	local command = clean(params.command)
	local changes = params.item and params.item.changes or {}
	local title = is_file
			and (#changes > 0 and ("Apply changes to %d file(s)"):format(#changes) or "Apply file changes")
		or (command ~= "" and command or "Run command")
	local details = {
		{ label = "Reason", value = params.reason },
		{ label = "Working directory", value = params.cwd },
		{ label = "Grant root", value = params.grantRoot },
	}
	if params.environmentId and params.environmentId ~= vim.NIL then
		table.insert(details, { label = "Environment", value = params.environmentId })
	end
	if params.networkApprovalContext and params.networkApprovalContext ~= vim.NIL then
		local network = params.networkApprovalContext
		table.insert(details, {
			label = "Network destination",
			value = ("%s (%s)"):format(network.host or "unknown", network.protocol or "network"),
		})
	end
	if params.additionalPermissions and params.additionalPermissions ~= vim.NIL then
		table.insert(details, { label = "Additional permissions", value = inspect(params.additionalPermissions) })
	end
	for index, change in ipairs(changes) do
		table.insert(details, { label = ("File %d"):format(index), value = change.path })
	end

	permission.select({
		toolCall = {
			title = title,
			kind = is_file and "file change" or "command",
			description = command ~= "" and command or params.reason,
			location = params.cwd,
		},
		details = details,
		options = v2_options(params),
	}, function(option)
		reply({ decision = option and option.optionId or "cancel" })
	end)
	return true
end

local function select_legacy(method, params, reply)
	local is_file = method == "applyPatchApproval"
	local command = type(params.command) == "table" and table.concat(params.command, " ") or params.command
	local count = file_count(params.fileChanges)
	permission.select({
		toolCall = {
			title = is_file and ("Apply changes to %d file(s)"):format(count) or clean(command),
			kind = is_file and "file change" or "command",
			description = params.reason,
			location = params.cwd,
		},
		options = {
			{ optionId = "approved", name = "Allow once" },
			{ optionId = "approved_for_session", name = "Allow for this session" },
			{ optionId = "denied", name = "Deny and continue" },
			{ optionId = "abort", name = "Deny and stop the turn" },
		},
	}, function(option)
		local decision = option and option.optionId or "abort"
		if decision == "denied" then
			decision = { denied = { rejection = "Denied in Neovim" } }
		end
		reply({ decision = decision })
	end)
	return true
end

function M.handle(method, params, reply)
	if method == "item/commandExecution/requestApproval" or method == "item/fileChange/requestApproval" then
		return select_v2(method, params, reply)
	end
	if method == "execCommandApproval" or method == "applyPatchApproval" then
		return select_legacy(method, params, reply)
	end
	return false
end

return M
