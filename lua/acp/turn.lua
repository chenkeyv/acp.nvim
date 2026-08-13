local icons = require("acp.icons")

local M = {}

local active_kinds = {
	starting = true,
	loading = true,
	running = true,
	thinking = true,
	planning = true,
	responding = true,
	command = true,
	tool = true,
	changes = true,
	review = true,
	compacting = true,
	steering = true,
	stopping = true,
	retrying = true,
}

local presentations = {
	idle = { icon = "idle", group = "AcpTurnIdle" },
	starting = { icon = "arrow_right", group = "AcpTurnStarting" },
	loading = { icon = "model", group = "AcpTurnLoading" },
	running = { icon = "busy", group = "AcpTurnRunning" },
	thinking = { icon = "brain", group = "AcpTurnThinking" },
	planning = { icon = "hierarchy", group = "AcpTurnPlanning" },
	responding = { icon = "agent", group = "AcpTurnResponding" },
	command = { icon = "terminal", group = "AcpTurnCommand" },
	tool = { icon = "tool", group = "AcpTurnTool" },
	changes = { icon = "edit", group = "AcpTurnChanges" },
	review = { icon = "inspect", group = "AcpTurnReview" },
	compacting = { icon = "package", group = "AcpTurnCompacting" },
	steering = { icon = "send", group = "AcpTurnSteering" },
	stopping = { icon = "stop", group = "AcpTurnStopping" },
	retrying = { icon = "restore", group = "AcpTurnRetrying" },
	success = { icon = "idle", group = "AcpTurnSuccess" },
	error = { icon = "error", group = "AcpTurnError" },
}

local function now_ms()
	return vim.uv.hrtime() / 1000000
end

local function clean(value)
	return vim.trim(tostring(value or ""):gsub("%s+", " "))
end

function M.kind(status, hint)
	if presentations[hint] then
		return hint
	end
	local value = clean(status):lower()
	if value == "" or value == "ready" or value == "idle" or value == "new chat" then
		return "idle"
	elseif
		value:find("error", 1, true)
		or value:find("fail", 1, true)
		or value == "disconnected"
		or value:find("cancel", 1, true)
		or value:find("interrupt", 1, true)
	then
		return "error"
	elseif value:find("complet", 1, true) or value == "done" or value:find("success", 1, true) then
		return "success"
	elseif value:find("retry", 1, true) then
		return "retrying"
	elseif value:find("stopp", 1, true) then
		return "stopping"
	elseif value:find("think", 1, true) or value:find("reason", 1, true) then
		return "thinking"
	elseif value:find("plan", 1, true) then
		return "planning"
	elseif value:find("respond", 1, true) then
		return "responding"
	elseif value:find("command", 1, true) or value:find("shell", 1, true) then
		return "command"
	elseif value:find("tool", 1, true) or value:find("mcp", 1, true) or value:find("call", 1, true) then
		return "tool"
	elseif
		value:find("file", 1, true)
		or value:find("change", 1, true)
		or value:find("edit", 1, true)
		or value:find("apply", 1, true)
	then
		return "changes"
	elseif value:find("review", 1, true) then
		return "review"
	elseif value:find("compact", 1, true) then
		return "compacting"
	elseif value:find("steer", 1, true) then
		return "steering"
	elseif value:find("load", 1, true) or value:find("model", 1, true) then
		return "loading"
	elseif value:find("start", 1, true) or value:find("resum", 1, true) then
		return "starting"
	end
	return "running"
end

function M.is_active(state)
	if not state then
		return false
	end
	return active_kinds[M.kind(state.status, state.status_kind)] == true
end

function M.normalize(state, timestamp)
	if not state then
		return state
	end
	state.status_kind = M.kind(state.status, state.status_kind)
	if active_kinds[state.status_kind] then
		local current = tonumber(timestamp) or now_ms()
		state.status_started_at_ms = tonumber(state.status_started_at_ms) or current
		state.status_work_started_at_ms = tonumber(state.status_work_started_at_ms) or state.status_started_at_ms
	else
		state.status_started_at_ms = nil
		state.status_work_started_at_ms = nil
	end
	return state
end

function M.transition(state, status, kind, timestamp)
	if not state then
		return false
	end
	status = clean(status)
	if status == "" then
		status = (state.busy or state.starting) and "working" or "ready"
	end
	kind = M.kind(status, kind)
	if state.status == status and state.status_kind == kind then
		return false
	end

	local current = tonumber(timestamp) or now_ms()
	local was_active = active_kinds[M.kind(state.status, state.status_kind)] == true
	local status_started = tonumber(state.status_started_at_ms)
	local work_started = tonumber(state.status_work_started_at_ms)
	state.status = status
	state.status_kind = kind

	if active_kinds[kind] then
		state.status_started_at_ms = current
		state.status_work_started_at_ms = was_active and work_started or current
		state.status_elapsed_ms = nil
	else
		if (kind == "success" or kind == "error") and was_active and (work_started or status_started) then
			state.status_elapsed_ms = math.max(0, current - (work_started or status_started))
		else
			state.status_elapsed_ms = nil
		end
		state.status_started_at_ms = nil
		state.status_work_started_at_ms = nil
	end
	return true
end

function M.elapsed_ms(state, timestamp)
	if not state then
		return nil
	end
	local kind = M.kind(state.status, state.status_kind)
	if active_kinds[kind] then
		local started = tonumber(state.status_started_at_ms)
		if not started then
			return nil
		end
		return math.max(0, (tonumber(timestamp) or now_ms()) - started)
	end
	return tonumber(state.status_elapsed_ms)
end

function M.duration_label(milliseconds)
	milliseconds = tonumber(milliseconds)
	if not milliseconds then
		return nil
	end
	local seconds = math.max(0, math.floor(milliseconds / 1000))
	if seconds < 60 then
		return ("%ds"):format(seconds)
	elseif seconds < 3600 then
		return ("%dm %02ds"):format(math.floor(seconds / 60), seconds % 60)
	end
	return ("%dh %02dm"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60)
end

function M.describe(state, timestamp)
	state = state or {}
	local label = clean(state.status)
	if label == "" then
		label = (state.busy or state.starting) and "working" or "ready"
	end
	local kind = M.kind(label, state.status_kind)
	local presentation = presentations[kind] or presentations.running
	local active = active_kinds[kind] == true
	local frame = math.max(1, math.floor(tonumber(state.instruction_spinner_frame) or 1))
	return {
		label = label,
		kind = kind,
		icon = active and icons.spinner(frame) or icons.get(presentation.icon),
		group = presentation.group,
		active = active,
		duration = M.duration_label(M.elapsed_ms(state, timestamp)),
	}
end

return M
