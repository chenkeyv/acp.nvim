local transcript = require("acp.transcript")

local M = {}

local function trim(value)
	return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function split_lines(value)
	local lines = {}
	value = tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
	for line in (value .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	return lines
end

function M.clean(value)
	local text = tostring(value or "")
	-- Operating System Command sequences end with BEL or String Terminator.
	text = text:gsub("\27%][^\7]*\7", "")
	text = text:gsub("\27%].-\27\\", "")
	-- Control Sequence Introducer and remaining single-character escapes.
	text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
	text = text:gsub("\27[@-_]", "")
	text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "")
	return text:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function decode_escapes(value)
	local decoded = {}
	local index = 1
	value = tostring(value or "")
	while index <= #value do
		local char = value:sub(index, index)
		if char ~= "\\" or index == #value then
			table.insert(decoded, char)
			index = index + 1
		else
			local escaped = value:sub(index + 1, index + 1)
			local replacements = {
				["\\"] = "\\",
				['"'] = '"',
				["n"] = "\n",
				["r"] = "\r",
				["t"] = "\t",
			}
			if replacements[escaped] then
				table.insert(decoded, replacements[escaped])
				index = index + 2
			else
				table.insert(decoded, "\\" .. escaped)
				index = index + 2
			end
		end
	end
	return table.concat(decoded)
end

local function unwrap_variant(value)
	local name, payload = tostring(value or ""):match('^([%a_][%w_]*)%(%s*"(.*)"%s*%)$')
	if name and payload then
		return ("%s: %s"):format(name, decode_escapes(payload))
	end
	return value
end

local function unwrap_process(value)
	local message = tostring(value or ""):match('^CreateProcess%s*{%s*message%s*:%s*"(.*)"%s*}%s*$')
	if not message then
		return value
	end
	return unwrap_variant(decode_escapes(message))
end

local function normalize_message(value)
	local message = trim(value)
	local field, field_value = message:match("^([%a_][%w_.]*)=(.*)$")
	if field == "error" or field == "message" then
		message = trim(field_value)
	end

	local prefix, process = message:match("^(.-):%s*(CreateProcess%s*{.*}%s*)$")
	if process then
		local detail = trim(unwrap_process(process))
		prefix = trim(prefix)
		if prefix ~= "" and detail ~= "" then
			return prefix .. "\n" .. detail
		end
		message = detail ~= "" and detail or prefix
	else
		message = trim(unwrap_process(message))
	end

	local quoted = message:match('^"(.*)"$')
	if quoted then
		message = decode_escapes(quoted)
	end
	return trim(message)
end

local function parse_line(line)
	local timestamp, level, rest = line:match("^(%d%d%d%d%-%d%d%-%d%dT%S+)%s+([A-Z]+)%s+(.+)$")
	if not timestamp then
		return { message = trim(line) }, false
	end
	local source, body = rest:match("^([^%s]+):%s+(.*)$")
	if not source then
		return {
			timestamp = timestamp,
			level = level,
			message = normalize_message(rest),
		}, true
	end
	return {
		timestamp = timestamp,
		level = level,
		source = source,
		message = normalize_message(body),
	}, true
end

local function kind_for(level)
	level = tostring(level or ""):upper()
	if level == "ERROR" then
		return "error", "error"
	elseif level == "WARN" or level == "WARNING" then
		return "warning", "warning"
	elseif level ~= "" then
		return "notice", "info"
	end
	return "warning", "warning"
end

local function source_label(source)
	source = tostring(source or "")
	source = source:gsub("^codex_core::", ""):gsub("^codex_app_server::", "")
	return source:gsub("::", "/")
end

local function notice(entry)
	local kind, icon = kind_for(entry.level)
	local title = "Codex server"
	local source = source_label(entry.source)
	if source ~= "" then
		title = title .. " · " .. source
	end
	local lines = { "", transcript.line(icon, title) }
	for _, line in ipairs(split_lines(entry.message)) do
		if line ~= "" then
			table.insert(lines, "  " .. line)
		elseif #lines > 2 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
	end
	return {
		kind = kind,
		message = entry.message,
		lines = lines,
		metadata = {
			server_log = {
				level = entry.level,
				source = entry.source,
				timestamp = entry.timestamp,
			},
		},
	}
end

function M.is_background_noise(entry)
	local metadata = type(entry) == "table" and entry.metadata or nil
	local server = type(metadata) == "table" and metadata.server_log or nil
	if type(server) ~= "table" or server.source ~= "codex_models_manager::manager" then
		return false
	end
	return tostring(entry.message or ""):find("failed to refresh available models:", 1, true) == 1
end

function M.is_duplicate_tool_failure(entry)
	local metadata = type(entry) == "table" and entry.metadata or nil
	local server = type(metadata) == "table" and metadata.server_log or nil
	if type(server) ~= "table" or server.source ~= "codex_core::tools::router" then
		return false
	end

	local message = tostring(entry.message or "")
	return message:find("apply_patch verification failed:", 1, true) == 1
		or message:find("exec_command failed for ", 1, true) == 1
end

function M.should_suppress(entry)
	return M.is_background_noise(entry) or M.is_duplicate_tool_failure(entry)
end

function M.parse(value)
	local entries = {}
	local pending
	local pending_blank_lines = 0
	local function flush_pending()
		if pending and pending.message ~= "" then
			table.insert(entries, notice(pending))
		end
		pending = nil
		pending_blank_lines = 0
	end
	for _, raw_line in ipairs(split_lines(M.clean(value))) do
		local line = trim(raw_line)
		if line == "" then
			if pending then
				pending_blank_lines = pending_blank_lines + 1
			end
		elseif line:find("could not create PATH aliases", 1, true) then
			flush_pending()
		else
			local entry, structured = parse_line(line)
			if structured then
				flush_pending()
				pending = entry
			elseif pending then
				pending.message = pending.message .. string.rep("\n", pending_blank_lines + 1) .. entry.message
				pending_blank_lines = 0
			elseif entry.message ~= "" then
				table.insert(entries, notice(entry))
			end
		end
	end
	flush_pending()
	return entries
end

return M
