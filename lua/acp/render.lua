local action = require("acp.action")
local transcript = require("acp.transcript")

local M = {}

local function present(value)
	return value ~= nil and value ~= vim.NIL
end

local function clean(value)
	if not present(value) then
		return ""
	end
	return tostring(value or ""):gsub("\27%[[0-9;?]*[ -/]*[@-~]", ""):gsub("%s+$", "")
end

local function status_label(status)
	if not present(status) then
		status = "done"
	end
	return tostring(status or "done"):gsub("(%l)(%u)", "%1 %2"):lower()
end

local function change_label(change)
	local kind = change.kind
	if type(kind) ~= "table" then
		return status_label(kind)
	end
	if kind.type == "update" and kind.move_path and kind.move_path ~= vim.NIL then
		return ("move to `%s`"):format(kind.move_path)
	end
	return status_label(kind.type)
end

local function failed_status(status)
	local text = status_label(status)
	for _, value in ipairs({ "failed", "error", "cancelled", "canceled", "declined", "rejected", "interrupted" }) do
		if text == value then
			return true
		end
	end
	return false
end

function M.header(kind, suffix)
	return transcript.header(kind, suffix)
end

function M.transcript_line(kind, content)
	return transcript.line(kind, content)
end

function M.item_status(item)
	if type(item) ~= "table" then
		return "working"
	end
	if item.type == "commandExecution" then
		return ("running %s"):format(item.command or "command")
	elseif item.type == "fileChange" then
		return "applying file changes"
	elseif item.type == "mcpToolCall" then
		return ("using %s/%s"):format(item.server or "mcp", item.tool or "tool")
	elseif item.type == "dynamicToolCall" then
		return ("using %s"):format(item.tool or "tool")
	elseif item.type == "reasoning" then
		return "thinking"
	elseif item.type == "agentMessage" then
		return "responding"
	elseif item.type == "enteredReviewMode" then
		return "reviewing changes"
	end
	return "working"
end

local function file_change_lines(item)
	local lines = {}
	local status = status_label(item.status)
	local failed = failed_status(item.status)
	for _, change in ipairs(item.changes or {}) do
		local detail = ("%s `%s`"):format(change_label(change), change.path or "file")
		local content = failed and ("File changes: %s · %s"):format(status, detail) or detail
		table.insert(lines, transcript.line(failed and "error" or "changes", content))
	end
	if #lines == 0 then
		table.insert(lines, transcript.line(failed and "error" or "changes", ("File changes: %s"):format(status)))
	end
	return lines
end

function M.completed_item(item)
	if type(item) ~= "table" then
		return {}
	end
	local action_kind = action.kind(item)
	if action_kind then
		local child = action.new_child(item)
		return action.render_block({
			children = { child },
			metadata = { presentation = action.is_exploration(item) and "explore" or action_kind },
		})
	elseif item.type == "fileChange" then
		return file_change_lines(item)
	elseif item.type == "plan" and item.text and item.text ~= "" then
		return { "", transcript.header("plan"), "", item.text }
	elseif item.type == "enteredReviewMode" then
		return { transcript.line("note", "Entered review mode.") }
	elseif item.type == "exitedReviewMode" and item.review and item.review ~= "" then
		return { "", transcript.header("review"), "", item.review }
	elseif item.type == "contextCompaction" then
		return { transcript.line("note", "Conversation context compacted.") }
	end
	return {}
end

function M.thread_diff(thread)
	local diffs = {}
	for _, turn in ipairs((thread and thread.turns) or {}) do
		for _, item in ipairs(turn.items or {}) do
			if item.type == "fileChange" then
				for _, change in ipairs(item.changes or {}) do
					if change.diff and change.diff ~= "" then
						table.insert(diffs, change.diff)
					end
				end
			end
		end
	end
	return table.concat(diffs, "\n")
end

function M.thread_label(thread)
	local title = present(thread.name) and thread.name or thread.preview
	if not present(title) or title == "" then
		title = thread.id or "Untitled chat"
	end
	title = clean(title):gsub("%s+", " ")
	if #title > 72 then
		title = title:sub(1, 69) .. "..."
	end
	local updated = tonumber(thread.updatedAt or thread.createdAt)
	local stamp = updated and os.date("%Y-%m-%d %H:%M", updated) or ""
	return stamp ~= "" and (title .. "  " .. stamp) or title
end

return M
