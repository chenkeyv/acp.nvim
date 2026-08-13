local M = {}

local function present(value)
	return value ~= nil and value ~= vim.NIL
end

function M.normalize(state)
	local values = type(state.pending_instructions) == "table" and state.pending_instructions or {}
	local sequence = math.max(0, tonumber(state.instruction_sequence) or 0)
	local seen = {}
	for _, instruction in ipairs(values) do
		if not present(instruction.id) or tostring(instruction.id) == "" then
			sequence = sequence + 1
			instruction.id = ("instruction:%d"):format(sequence)
		else
			instruction.id = tostring(instruction.id)
			sequence = math.max(sequence, tonumber(instruction.id:match("^instruction:(%d+)$")) or 0)
		end
		seen[instruction.id] = true
	end
	for _, envelope in ipairs(state.queue or {}) do
		local id = present(envelope._acp_instruction_id) and tostring(envelope._acp_instruction_id) or nil
		if not id then
			sequence = sequence + 1
			id = ("instruction:%d"):format(sequence)
			envelope._acp_instruction_id = id
		else
			sequence = math.max(sequence, tonumber(id:match("^instruction:(%d+)$")) or 0)
		end
		if not seen[id] then
			seen[id] = true
			table.insert(values, {
				id = id,
				kind = "queued",
				text = envelope.text or "",
			})
		end
	end
	state.pending_instructions = values
	state.instruction_sequence = sequence
	return state
end

function M.add(state, kind, envelope)
	state.instruction_sequence = (tonumber(state.instruction_sequence) or 0) + 1
	local id = ("instruction:%d"):format(state.instruction_sequence)
	envelope._acp_instruction_id = id
	local instruction = {
		id = id,
		kind = kind,
		text = envelope.text or "",
		accepted = kind ~= "steer" and nil or false,
	}
	table.insert(state.pending_instructions, instruction)
	return instruction
end

function M.accept(state, id)
	if not state or not present(id) then
		return false
	end
	id = tostring(id)
	for _, instruction in ipairs(state.pending_instructions or {}) do
		if instruction.id == id then
			instruction.accepted = true
			return true
		end
	end
	return false
end

function M.remove(state, id)
	if not state or not present(id) then
		return false
	end
	id = tostring(id)
	for index, instruction in ipairs(state.pending_instructions or {}) do
		if instruction.id == id then
			table.remove(state.pending_instructions, index)
			return true
		end
	end
	return false
end

function M.clear(state, kind)
	if not state then
		return false
	end
	local kept = {}
	local changed = false
	for _, instruction in ipairs(state.pending_instructions or {}) do
		if kind == nil or instruction.kind == kind then
			changed = true
		else
			table.insert(kept, instruction)
		end
	end
	if changed then
		state.pending_instructions = kept
	end
	return changed
end

function M.consume_steers(state)
	if not state then
		return false
	end
	local kept = {}
	local changed = false
	for _, instruction in ipairs(state.pending_instructions or {}) do
		if instruction.kind == "steer" and instruction.accepted == true then
			changed = true
		else
			table.insert(kept, instruction)
		end
	end
	if changed then
		state.pending_instructions = kept
	end
	return changed
end

local function stop_timer(timer)
	if not timer then
		return
	end
	pcall(timer.stop, timer)
	local closing = false
	pcall(function()
		closing = timer:is_closing()
	end)
	if not closing then
		pcall(timer.close, timer)
	end
end

function M.stop_spinner(state)
	if not state then
		return
	end
	stop_timer(state.instruction_spinner_timer)
	state.instruction_spinner_timer = nil
	state.instruction_spinner_frame = nil
end

function M.sync_spinner(state, active, refresh)
	if not state then
		return
	end
	if not active then
		M.stop_spinner(state)
		return
	end
	if state.instruction_spinner_timer then
		return
	end
	local timer = vim.uv.new_timer()
	if not timer then
		state.instruction_spinner_frame = 1
		return
	end
	state.instruction_spinner_frame = math.max(1, tonumber(state.instruction_spinner_frame) or 1)
	state.instruction_spinner_timer = timer
	timer:start(
		150,
		150,
		vim.schedule_wrap(function()
			if state.instruction_spinner_timer ~= timer then
				return
			end
			state.instruction_spinner_frame = (tonumber(state.instruction_spinner_frame) or 1) + 1
			if type(refresh) == "function" then
				pcall(refresh)
			end
		end)
	)
end

return M
