local action = require("acp.action")
local icons = require("acp.icons")
local render = require("acp.render")
local semantics = require("acp.block_semantics")

local M = {}
local Model = {}
Model.__index = Model

local registry = setmetatable({}, { __mode = "v" })

local activity_types = {
	commandExecution = "command",
	dynamicToolCall = "tool",
	fileChange = "file",
	mcpToolCall = "tool",
}

local successful_statuses = {
	completed = true,
	done = true,
	succeeded = true,
	success = true,
}

local failed_statuses = {
	canceled = true,
	cancelled = true,
	declined = true,
	error = true,
	failed = true,
	interrupted = true,
	rejected = true,
}

local section_kinds = {
	activity = "ACTIVITY",
	agent = "AGENT",
	error = "ERROR",
	notice = "NOTE",
	plan = "PLAN",
	review = "REVIEW",
	user = "USER",
	warning = "WARNING",
}

local section_titles = {
	activity = "Completed activity",
	agent = "Response",
	error = "Error",
	notice = "Notice",
	plan = "Plan",
	review = "Review",
	user = "Prompt",
	warning = "Warning",
}

local function present(value)
	return value ~= nil and value ~= vim.NIL
end

local function copy_lines(lines)
	local values = {}
	for _, line in ipairs(lines or {}) do
		table.insert(values, tostring(line or ""))
	end
	return values
end

local function copy_rows(rows)
	return type(rows) == "table" and vim.deepcopy(rows) or nil
end

local function row_lines(rows)
	return vim.tbl_map(function(row)
		return tostring(row.text or "")
	end, rows or {})
end

local function split_lines(text)
	return vim.split(tostring(text or ""), "\n", { plain = true })
end

local function normalize_status(status)
	if not present(status) then
		return "done"
	end
	return tostring(status or "done"):gsub("(%l)(%u)", "%1 %2"):lower()
end

local function activity_failed(item)
	local kind = type(item) == "table" and activity_types[item.type] or nil
	if not kind then
		return false
	end
	local status = normalize_status(item.status)
	if failed_statuses[status] then
		return true
	end
	if item.type == "commandExecution" and present(item.exitCode) and tonumber(item.exitCode) ~= 0 then
		return true
	end
	return false
end

local function activity_success(item)
	local kind = type(item) == "table" and activity_types[item.type] or nil
	if not kind or activity_failed(item) then
		return false
	end
	local status = normalize_status(item.status)
	return successful_statuses[status] == true
end

local function item_problem_message(item, status)
	item = type(item) == "table" and item or {}
	if type(item.error) == "table" and present(item.error.message) then
		return tostring(item.error.message)
	elseif present(item.error) then
		return tostring(item.error)
	elseif item.type == "fileChange" then
		return "File changes " .. tostring(status or "failed")
	end
	local label = tostring(item.type or "Codex item"):gsub("(%l)(%u)", "%1 %2"):lower()
	return label .. " " .. tostring(status or "failed")
end

local function content_segments(text)
	local lines = split_lines(text)
	local segments = {}
	local index = 1
	while index <= #lines do
		local language = lines[index]:match("^```%s*([^%s`]*)")
		if language ~= nil then
			local start_line = index
			index = index + 1
			local content = {}
			while index <= #lines and not lines[index]:match("^```%s*$") do
				table.insert(content, lines[index])
				index = index + 1
			end
			local closed = index <= #lines
			local end_line = closed and index or #lines
			table.insert(segments, {
				kind = "code",
				language = language ~= "" and language or "text",
				start_line = start_line,
				end_line = end_line,
				closed = closed,
				text = table.concat(content, "\n"),
			})
			if closed then
				index = index + 1
			end
		else
			local start_line = index
			local content = {}
			while index <= #lines and lines[index]:match("^```%s*([^%s`]*)") == nil do
				table.insert(content, lines[index])
				index = index + 1
			end
			table.insert(segments, {
				kind = "text",
				start_line = start_line,
				end_line = index - 1,
				text = table.concat(content, "\n"),
			})
		end
	end
	return segments
end

local function refresh_block_ranges(block)
	if not block.line1 or not block.line2 then
		return
	end
	local header_offset = block.header_offset or 1
	block.header_line = block.line1 + header_offset - 1
	if block.content_offset then
		local content_line = block.line1 + block.content_offset - 1
		for _, child in ipairs(block.children or {}) do
			if child.start_line then
				child.line1 = content_line + child.start_line - 1
				child.line2 = content_line + child.end_line - 1
			end
		end
	elseif block.kind == "activity" then
		for _, child in ipairs(block.children or {}) do
			if child.relative_line1 then
				child.line1 = block.line1 + child.relative_line1 - 1
				child.line2 = block.line1 + (child.relative_line2 or child.relative_line1) - 1
			else
				child.line1 = nil
				child.line2 = nil
			end
		end
	end
end

local function full_activity_lines(block)
	if
		block.metadata
		and (
			block.metadata.presentation == "command"
			or block.metadata.presentation == "tool"
			or block.metadata.presentation == "explore"
		)
	then
		return action.detail_lines(block) or copy_lines(block.lines)
	end
	local lines = {}
	for _, child in ipairs(block.children or {}) do
		for _, line in ipairs(child.lines or {}) do
			table.insert(lines, tostring(line or ""))
		end
	end
	return #lines > 0 and lines or copy_lines(block.lines)
end

local function block_id(model, prefix, requested)
	if present(requested) and tostring(requested) ~= "" then
		return tostring(requested)
	end
	model.sequence = (model.sequence or 0) + 1
	return ("%s:%d"):format(prefix or "block", model.sequence)
end

local function new_block(model, kind, opts)
	opts = opts or {}
	local lines = copy_lines(opts.lines)
	local rows = copy_rows(opts.rows)
	local header_offset = opts.header_offset
	local content_offset = opts.content_offset
	if lines[1] ~= "" then
		table.insert(lines, 1, "")
		if rows then
			table.insert(rows, 1, { text = "", role = "separator" })
		end
		if header_offset then
			header_offset = header_offset + 1
		end
		if content_offset then
			content_offset = content_offset + 1
		end
	end
	local block = {
		id = block_id(model, kind, opts.id),
		kind = kind,
		status = opts.status,
		text = opts.text,
		lines = lines,
		rows = rows,
		children = opts.children or {},
		header_offset = header_offset,
		content_offset = content_offset,
		metadata = opts.metadata or {},
		revision = 1,
	}
	if #block.lines == 0 then
		block.lines = { "" }
	end
	return block
end

local function touch_block(block)
	block.revision = (tonumber(block.revision) or 0) + 1
	semantics.invalidate(block)
end

local function touch_model(model)
	model.revision = (tonumber(model.revision) or 0) + 1
	model.semantic_cache = nil
end

local function shift_after(model, block, delta)
	if delta == 0 then
		return
	end
	for index = (block.index or #model.blocks) + 1, #model.blocks do
		local following = model.blocks[index]
		following.line1 = following.line1 + delta
		following.line2 = following.line2 + delta
		refresh_block_ranges(following)
	end
	model.line_count = model.line_count + delta
end

local function index_activity_children(model, block)
	if block.kind ~= "activity" then
		return
	end
	for _, child in ipairs(block.children or {}) do
		if present(child.id) then
			model.activity_items[tostring(child.id)] = { block = block, child = child }
		end
	end
end

function Model:_append_block(block)
	local old_line_count = self.line_count
	block.index = #self.blocks + 1
	block.line1 = old_line_count + 1
	block.line2 = old_line_count + #block.lines
	self.line_count = block.line2
	table.insert(self.blocks, block)
	self.by_id[block.id] = block
	index_activity_children(self, block)
	refresh_block_ranges(block)
	touch_model(self)
	return {
		type = "insert",
		start_row = old_line_count,
		end_row = old_line_count == 0 and 1 or old_line_count,
		lines = copy_lines(block.lines),
		block = block,
	}
end

function Model:_replace_block_lines(block, lines, rows)
	if not block then
		return nil
	end
	lines = copy_lines(lines)
	rows = copy_rows(rows)
	if lines[1] ~= "" then
		table.insert(lines, 1, "")
		if rows then
			table.insert(rows, 1, { text = "", role = "separator" })
		end
	end
	if #lines == 0 then
		lines = { "" }
	end
	local old_line2 = block.line2
	local old_count = #block.lines
	block.lines = lines
	block.rows = rows
	block.line2 = block.line1 + #lines - 1
	shift_after(self, block, #lines - old_count)
	touch_block(block)
	refresh_block_ranges(block)
	touch_model(self)
	return {
		type = "replace",
		start_row = block.line1 - 1,
		end_row = old_line2,
		lines = copy_lines(lines),
		block = block,
	}
end

function Model:_render_action_block(block)
	if not block or block.kind ~= "activity" then
		return nil
	end
	local active = false
	local failed = false
	for _, child in ipairs(block.children or {}) do
		active = active or action.is_active(child)
		failed = failed or action.failed(child)
		child.relative_line1 = nil
		child.relative_line2 = nil
	end
	block.status = active and "in progress" or failed and "failed" or "completed"
	local rows = action.render_rows(block)
	local lines = row_lines(rows)
	if #block.children == 1 then
		block.children[1].lines = copy_lines(lines)
		block.children[1].relative_line1 = block.header_offset or 1
		block.children[1].relative_line2 = (block.header_offset or 1) + #lines - 1
	end
	return self:_replace_block_lines(block, lines, rows)
end

function Model:_append_block_lines(block, lines, child)
	lines = copy_lines(lines)
	if #lines == 0 then
		return nil
	end
	local start_row = block.line2
	local relative_line1 = #block.lines + 1
	for _, line in ipairs(lines) do
		table.insert(block.lines, line)
	end
	child = child or { kind = "activity", lines = lines }
	child.lines = copy_lines(child.lines or lines)
	touch_block(block)
	block.line2 = block.line2 + #lines
	shift_after(self, block, #lines)
	child.relative_line1 = relative_line1
	child.relative_line2 = relative_line1 + #lines - 1
	table.insert(block.children, child)
	index_activity_children(self, block)
	refresh_block_ranges(block)
	touch_model(self)
	return {
		type = "insert",
		start_row = start_row,
		end_row = start_row,
		lines = lines,
		block = block,
	}
end

function Model:break_activity()
	self.activity_open = false
end

function Model:add_user(text, labels, opts)
	opts = opts or {}
	local lines = { "", render.header("user", opts.suffix) }
	vim.list_extend(lines, split_lines(text))
	if #(labels or {}) > 0 then
		table.insert(lines, render.transcript_line("context", ("Context: %s"):format(table.concat(labels, ", "))))
	end
	local block = new_block(self, "user", {
		id = opts.id,
		text = text,
		lines = lines,
		children = content_segments(text),
		header_offset = 2,
		content_offset = 3,
		metadata = { labels = vim.deepcopy(labels or {}), steer = opts.steer == true },
	})
	self:break_activity()
	return self:_append_block(block), block
end

function Model:ensure_agent(id)
	local existing = present(id) and self.by_id[tostring(id)] or nil
	if existing then
		return nil, existing
	end
	local block = new_block(self, "agent", {
		id = id,
		text = "",
		lines = { "", render.header("agent"), "" },
		children = content_segments(""),
		header_offset = 2,
		content_offset = 3,
	})
	self:break_activity()
	return self:_append_block(block), block
end

function Model:ensure_plan(id)
	local existing = present(id) and self.by_id[tostring(id)] or nil
	if existing then
		return nil, existing
	end
	local block = new_block(self, "plan", {
		id = id,
		text = "",
		lines = { "", render.header("plan"), "" },
		children = content_segments(""),
		header_offset = 2,
		content_offset = 3,
	})
	self:break_activity()
	return self:_append_block(block), block
end

function Model:append_text(id, text)
	local block = present(id) and self.by_id[tostring(id)] or nil
	if not block or (block.kind ~= "agent" and block.kind ~= "plan" and block.kind ~= "review") then
		return nil
	end
	text = tostring(text or "")
	if text == "" then
		return nil
	end
	local old_line2 = block.line2
	local parts = split_lines(text)
	parts[1] = (block.lines[#block.lines] or "") .. parts[1]
	block.lines[#block.lines] = parts[1]
	for index = 2, #parts do
		table.insert(block.lines, parts[index])
	end
	touch_block(block)
	local delta = #parts - 1
	block.line2 = block.line2 + delta
	shift_after(self, block, delta)
	block.text = (block.text or "") .. text
	block.children = content_segments(block.text)
	refresh_block_ranges(block)
	touch_model(self)
	return {
		type = "replace",
		start_row = old_line2 - 1,
		end_row = old_line2,
		lines = parts,
		block = block,
	}
end

function Model:start_item(item, opts)
	opts = opts or {}
	local action_kind = action.kind(item)
	if not action_kind then
		return nil
	end
	local requested_id = present(item.id) and tostring(item.id) or nil
	local existing = requested_id and self.activity_items[requested_id] or nil
	if existing then
		action.update_child(existing.child, item)
		return self:_render_action_block(existing.block), existing.block
	end

	local child = action.new_child(item)
	child.id = child.id or block_id(self, action_kind, opts.id)
	child.item.id = child.item.id or child.id
	local presentation = action.is_exploration(item) and "explore" or action_kind
	local last = self.blocks[#self.blocks]
	if
		presentation == "explore"
		and self.activity_open
		and last
		and last.kind == "activity"
		and last.metadata
		and last.metadata.presentation == "explore"
	then
		table.insert(last.children, child)
		index_activity_children(self, last)
		return self:_render_action_block(last), last
	end

	self:break_activity()
	local activity_rows = action.render_rows({
		children = { child },
		metadata = { presentation = presentation },
	})
	local block = new_block(self, "activity", {
		id = item.id or opts.id,
		status = normalize_status(item.status),
		lines = row_lines(activity_rows),
		rows = activity_rows,
		children = { child },
		header_offset = 1,
		metadata = { presentation = presentation },
	})
	block.status = action.is_active(child) and "in progress" or action.failed(child) and "failed" or "completed"
	child.lines = action.render_block(block)
	child.relative_line1 = block.header_offset or 1
	child.relative_line2 = (block.header_offset or 1) + #child.lines - 1
	self.activity_open = presentation == "explore"
	return self:_append_block(block), block
end

function Model:append_command_output(id, delta)
	local entry = present(id) and self.activity_items[tostring(id)] or nil
	if not entry or not action.append_output(entry.child, delta) then
		return nil
	end
	return self:_render_action_block(entry.block), entry.block
end

function Model:update_item_progress(id, message)
	local entry = present(id) and self.activity_items[tostring(id)] or nil
	if not entry or not action.set_progress(entry.child, message) then
		return nil
	end
	return self:_render_action_block(entry.block), entry.block
end

function Model:complete_item(item, opts)
	local requested_id = type(item) == "table" and present(item.id) and tostring(item.id) or nil
	local entry = requested_id and self.activity_items[requested_id] or nil
	if entry and action.kind(item) then
		action.update_child(entry.child, item)
		return self:_render_action_block(entry.block), entry.block
	end
	return self:add_item(item, opts)
end

function Model:add_item(item, opts)
	opts = opts or {}
	if type(item) ~= "table" then
		return nil
	end
	if item.type == "fileChange" then
		self:invalidate_references()
	end
	if action.kind(item) then
		return self:start_item(item, opts)
	end
	local lines = render.completed_item(item)
	if #lines == 0 then
		return nil
	end
	local activity_kind = item.type == "fileChange" and activity_types[item.type] or nil
	if activity_kind and activity_success(item) then
		local block = self.blocks[#self.blocks]
		local child = {
			id = present(item.id) and tostring(item.id) or block_id(self, activity_kind),
			kind = activity_kind,
			status = normalize_status(item.status),
			item = vim.deepcopy(item),
			lines = copy_lines(lines),
		}
		if
			block
			and block.kind == "activity"
			and self.activity_open
			and block.metadata
			and block.metadata.presentation == "files"
		then
			return self:_append_block_lines(block, lines, child), block
		end
		block = new_block(self, "activity", {
			id = item.id or opts.id,
			status = "completed",
			lines = lines,
			children = { child },
			header_offset = 1,
			metadata = { presentation = "files" },
		})
		child.relative_line1 = block.header_offset or 1
		child.relative_line2 = (block.header_offset or 1) + #lines - 1
		self.activity_open = true
		return self:_append_block(block), block
	end

	local status = normalize_status(item.status)
	local kind = (failed_statuses[status] or activity_failed(item)) and "error" or "notice"
	if item.type == "plan" then
		kind = "plan"
		lines = { "", render.header("plan") }
		vim.list_extend(lines, split_lines(item.text or ""))
	elseif item.type == "exitedReviewMode" then
		kind = "review"
		lines = { "", render.header("review") }
		vim.list_extend(lines, split_lines(item.review or ""))
	elseif lines[1] ~= "" then
		table.insert(lines, 1, "")
	end
	local metadata = { item = vim.deepcopy(item) }
	if kind == "error" or kind == "warning" then
		metadata.problem_message = item_problem_message(item, status)
	end
	local block = new_block(self, kind, {
		id = item.id or opts.id,
		status = status,
		text = item.text or item.review,
		lines = lines,
		children = content_segments(item.text or item.review or ""),
		header_offset = #lines > 1 and 2 or 1,
		content_offset = (kind == "plan" or kind == "review") and 3 or nil,
		metadata = metadata,
	})
	self:break_activity()
	return self:_append_block(block), block
end

function Model:add_notice(kind, message, opts)
	opts = opts or {}
	kind = kind == "error" and "error" or kind == "warning" and "warning" or "notice"
	local prefix = kind == "error" and "Error: " or kind == "warning" and "Warning: " or ""
	local icon = kind == "error" and "error" or kind == "warning" and "warning" or "info"
	local lines = opts.lines or { "", render.transcript_line(icon, prefix .. tostring(message or "")) }
	local metadata = vim.deepcopy(opts.metadata or {})
	if kind == "error" or kind == "warning" then
		metadata.problem_message = tostring(message or kind)
	end
	local block = new_block(self, kind, {
		id = opts.id,
		status = opts.status,
		text = message,
		lines = lines,
		header_offset = #lines > 1 and 2 or 1,
		metadata = metadata,
	})
	self:break_activity()
	return self:_append_block(block), block
end

function Model:render_lines()
	if #self.blocks == 0 then
		return { "" }
	end
	local lines = {}
	for _, block in ipairs(self.blocks) do
		vim.list_extend(lines, copy_lines(block.lines))
	end
	return lines
end

function Model:block_at(line)
	line = tonumber(line) or 1
	local low = 1
	local high = #self.blocks
	while low <= high do
		local middle = math.floor((low + high) / 2)
		local block = self.blocks[middle]
		if line < block.line1 then
			high = middle - 1
		elseif line > block.line2 then
			low = middle + 1
		else
			return block
		end
	end
end

function Model:row_at(line, known_block)
	line = tonumber(line) or 1
	local block = known_block or self:block_at(line)
	if not block then
		return nil
	end
	local local_line = line - block.line1 + 1
	local base = {
		block_id = block.id,
		block_kind = block.kind,
		line = line,
		presentation = block.metadata and block.metadata.presentation,
		status = block.status,
	}
	local stored = block.rows and block.rows[local_line]
	if stored then
		return vim.tbl_extend("force", base, stored)
	end
	if local_line == 1 then
		return vim.tbl_extend("force", base, { role = "separator" })
	end

	local presentation = block.metadata and block.metadata.presentation
	if block.kind == "activity" and presentation == "files" then
		return vim.tbl_extend("force", base, { role = "change" })
	elseif line == block.header_line then
		if block.kind == "user" or block.kind == "agent" or block.kind == "plan" or block.kind == "review" then
			return vim.tbl_extend("force", base, { role = "header", header_kind = block.kind })
		elseif block.kind == "error" or block.kind == "warning" or block.kind == "notice" then
			return vim.tbl_extend("force", base, { role = block.kind })
		end
	end

	for _, child in ipairs(block.children or {}) do
		if child.line1 and line >= child.line1 and line <= child.line2 then
			if child.kind == "code" then
				local fence = line == child.line1 or (child.closed ~= false and line == child.line2)
				return vim.tbl_extend("force", base, {
					role = fence and "code_fence" or "code",
					child = child,
				})
			elseif block.kind == "activity" and child.kind == "file" then
				return vim.tbl_extend("force", base, { role = "change", child = child })
			end
			return vim.tbl_extend("force", base, { role = child.kind or "text", child = child })
		end
	end

	if block.kind == "user" and #(block.metadata and block.metadata.labels or {}) > 0 and line == block.line2 then
		return vim.tbl_extend("force", base, { role = "context" })
	elseif block.kind == "error" or block.kind == "warning" or block.kind == "notice" then
		return vim.tbl_extend("force", base, { role = block.kind })
	end
	return vim.tbl_extend("force", base, { role = "text" })
end

function Model:entries(limit)
	limit = math.max(1, tonumber(limit) or 500)
	local values = {}
	for _, block in ipairs(self.blocks) do
		for line = block.line1, block.line2 do
			local text = vim.trim(tostring(block.lines[line - block.line1 + 1] or ""))
			if text ~= "" then
				local row = self:row_at(line, block) or {}
				local kind = "TEXT"
				if row.role == "header" then
					kind = section_kinds[block.kind] or block.kind:upper()
				elseif row.role == "action_header" then
					kind = row.presentation == "command" and "COMMAND"
						or row.presentation == "tool" and "TOOL"
						or "ACTIVITY"
				elseif row.role == "error" or row.role == "warning" or row.role == "notice" then
					kind = section_kinds[row.role] or row.role:upper()
				elseif row.role == "change" then
					kind = "FILE"
				elseif row.role == "context" then
					kind = "CONTEXT"
				elseif row.role == "code_fence" or row.role == "code" then
					kind = "CODE"
				end
				table.insert(values, {
					line = line,
					kind = kind,
					text = text,
					total_lines = self.line_count,
					block_id = block.id,
				})
				if #values >= limit then
					return values
				end
			end
		end
	end
	return values
end

function Model:fold_level(line)
	line = tonumber(line) or 1
	local block = self:block_at(line)
	if not block then
		return nil
	end
	local header_line = block.header_line or block.line1
	if line < header_line or block.line2 <= header_line then
		return "0"
	end
	local level = block.kind == "activity" and 2 or 1
	return line == header_line and (">" .. level) or tostring(level)
end

local fold_icons = {
	ACTIVITY = "command",
	AGENT = "agent",
	ERROR = "error",
	NOTE = "note",
	PLAN = "section",
	REVIEW = "section",
	USER = "user",
	WARNING = "warning",
}

function Model:fold_text(line, foldend)
	line = tonumber(line) or 1
	local block = self:block_at(line)
	if not block then
		return nil
	end
	if block.kind == "activity" then
		return require("acp.output").activity_fold_text(self:activity_at(block))
	end
	local section = self:section_at(block)
	if not section then
		return nil
	end
	local count = math.max(1, (tonumber(foldend) or block.line2) - line + 1)
	local preview = section.preview and vim.trim(section.preview) or ""
	local suffix = preview ~= "" and ("  " .. preview) or ""
	local text = ("%s %s %s  (%d line%s)%s"):format(
		icons.get(fold_icons[section.kind] or "section"),
		section.kind,
		section.title,
		count,
		count == 1 and "" or "s",
		suffix
	)
	return #text > 120 and (text:sub(1, 117) .. "...") or text
end

function Model:section_at(line)
	local block = type(line) == "table" and line or self:block_at(tonumber(line) or 1)
	local kind = block and section_kinds[block.kind] or nil
	if not kind then
		return nil
	end
	local presentation = block.metadata and block.metadata.presentation
	local title = block.kind == "activity"
			and (presentation == "command" and "Command" or presentation == "tool" and "Tool call" or presentation == "explore" and "Exploration" or ("%d completed item%s"):format(
				#(block.children or {}),
				#(block.children or {}) == 1 and "" or "s"
			))
		or section_titles[block.kind]
	return {
		line = block.header_line or block.line1,
		line2 = block.line2,
		kind = kind,
		title = title,
		preview = block.text and tostring(block.text):gsub("%s+", " "):sub(1, 96) or nil,
		total_lines = self.line_count,
		block_id = block.id,
	}
end

function Model:sections()
	local sections = {}
	for _, block in ipairs(self.blocks) do
		local section = self:section_at(block)
		if section then
			table.insert(sections, section)
		end
	end
	return sections
end

function Model:section_lines(line, opts)
	opts = opts or {}
	local requested_line = tonumber(line) or 1
	local block = self:block_at(requested_line)
	if not block then
		return nil
	end
	local line1 = block.header_line or block.line1
	local values = {}
	for index = line1 - block.line1 + 1, #block.lines do
		table.insert(values, block.lines[index] or "")
	end
	if opts.trim_blank ~= false then
		while #values > 1 and tostring(values[#values] or ""):match("^%s*$") do
			table.remove(values)
		end
	end
	return values,
		{
			line1 = line1,
			line2 = math.max(line1, block.line2),
			kind = section_kinds[block.kind],
			title = section_titles[block.kind],
			block_id = block.id,
		}
end

function Model:section_text(line, opts)
	local values, range = self:section_lines(line, opts)
	if not values then
		return nil
	end
	return table.concat(values, "\n"), range, values
end

function Model:activity_at(line)
	local block = type(line) == "table" and line or self:block_at(tonumber(line) or 1)
	if not block or block.kind ~= "activity" then
		return nil
	end
	local counts = { command = 0, tool = 0, file = 0 }
	for _, child in ipairs(block.children or {}) do
		local changes = child.item and child.item.changes
		local count = child.kind == "file" and math.max(1, type(changes) == "table" and #changes or 0) or 1
		counts[child.kind] = (counts[child.kind] or 0) + count
	end
	local group = {
		kind = "activity",
		line = block.header_line or block.line1,
		line2 = block.line2,
		col = 1,
		count = #block.children,
		counts = counts,
		total_lines = self.line_count,
		block_id = block.id,
		presentation = block.metadata and block.metadata.presentation,
	}
	group.label = require("acp.output").activity_summary(group)
	return group
end

function Model:activity_detail_lines(line)
	local block = type(line) == "table" and line or self:block_at(tonumber(line) or 1)
	if not block or block.kind ~= "activity" then
		return nil
	end
	return full_activity_lines(block)
end

function Model:activities()
	local groups = {}
	for _, block in ipairs(self.blocks) do
		local group = self:activity_at(block)
		if group then
			table.insert(groups, group)
		end
	end
	return groups
end

function Model:code_blocks()
	return semantics.code_blocks(self)
end

function Model:code_block_at(line)
	return semantics.code_block_at(self, line)
end

function Model:references(cwd, limit)
	return semantics.references(self, cwd, limit)
end

function Model:diagnostics()
	return semantics.diagnostics(self)
end

function Model:semantic_data(cwd)
	cwd = cwd or vim.fn.getcwd()
	local cache = self.semantic_cache
	if cache and cache.revision == self.revision and cache.cwd == cwd then
		return cache.value
	end
	local value = {
		references = self:references(cwd),
		code_blocks = self:code_blocks(),
		diagnostics = self:diagnostics(),
		sections = self:sections(),
		activities = self:activities(),
		total_lines = self.line_count,
	}
	self.semantic_cache = { revision = self.revision, cwd = cwd, value = value }
	return value
end

function Model:invalidate_references()
	semantics.invalidate_references(self)
	touch_model(self)
end

function Model:reindex()
	self.by_id = {}
	self.activity_items = {}
	self.line_count = 0
	self.blocks = vim.tbl_filter(function(block)
		return type(block) == "table" and section_kinds[block.kind] ~= nil
	end, self.blocks or {})
	for index, block in ipairs(self.blocks) do
		block.index = index
		block.id = present(block.id) and tostring(block.id) or block_id(self, block.kind)
		block.lines = copy_lines(block.lines)
		if #block.lines == 0 then
			block.lines = { "" }
		end
		block.rows = copy_rows(block.rows)
		block.children = type(block.children) == "table" and block.children or {}
		block.metadata = type(block.metadata) == "table" and block.metadata or {}
		block.separated = nil
		local presentation = block.metadata and block.metadata.presentation
		if
			block.kind == "activity"
			and (presentation == "command" or presentation == "tool" or presentation == "explore")
		then
			local rendered_rows = action.render_rows(block)
			local rendered = row_lines(rendered_rows)
			block.lines = vim.list_extend({ "" }, rendered)
			block.rows = vim.list_extend({ { text = "", role = "separator" } }, rendered_rows)
			block.header_offset = 2
			if #block.children == 1 then
				block.children[1].lines = copy_lines(rendered)
				block.children[1].relative_line1 = block.header_offset
				block.children[1].relative_line2 = block.header_offset + #rendered - 1
			end
		elseif block.lines[1] ~= "" then
			table.insert(block.lines, 1, "")
			if block.rows then
				table.insert(block.rows, 1, { text = "", role = "separator" })
			end
			block.header_offset = (tonumber(block.header_offset) or 1) + 1
			if block.content_offset then
				block.content_offset = block.content_offset + 1
			end
			for _, child in ipairs(block.children) do
				if child.relative_line1 then
					local relative_line1 = child.relative_line1
					local relative_line2 = child.relative_line2 or relative_line1
					child.relative_line1 = relative_line1 + 1
					child.relative_line2 = relative_line2 + 1
				end
			end
		end
		if block.kind == "user" or block.kind == "agent" or block.kind == "plan" or block.kind == "review" then
			block.header_offset = math.max(2, tonumber(block.header_offset) or 2)
			local suffix = block.kind == "user" and block.metadata.steer and " (steer)" or nil
			block.lines[block.header_offset] = render.header(block.kind, suffix)
		end
		block.revision = tonumber(block.revision) or 1
		if block.rows and #block.rows ~= #block.lines then
			block.rows = nil
		end
		semantics.invalidate(block)
		block.line1 = self.line_count + 1
		block.line2 = self.line_count + #block.lines
		self.line_count = block.line2
		self.by_id[block.id] = block
		index_activity_children(self, block)
		refresh_block_ranges(block)
	end
	local last = self.blocks[#self.blocks]
	self.activity_open = self.activity_open == true and last and last.kind == "activity" or false
	touch_model(self)
	return self
end

function M.new()
	return setmetatable({
		blocks = {},
		by_id = {},
		activity_items = {},
		line_count = 0,
		sequence = 0,
		activity_open = false,
		revision = 0,
	}, Model)
end

function M.adopt(value)
	if type(value) ~= "table" or type(value.blocks) ~= "table" then
		return M.new()
	end
	value.sequence = tonumber(value.sequence) or #value.blocks
	value.revision = tonumber(value.revision) or 0
	return setmetatable(value, Model):reindex()
end

local function user_item_content(item)
	local text = {}
	local labels = {}
	for _, content in ipairs(item.content or {}) do
		if content.type == "text" and content.text and content.text ~= "" then
			table.insert(text, content.text)
		elseif content.type == "mention" or content.type == "skill" then
			table.insert(labels, content.path or content.name)
		end
	end
	return table.concat(text, "\n\n"), labels
end

function M.from_thread(thread)
	local model = M.new()
	for turn_index, turn in ipairs((thread and thread.turns) or {}) do
		model:break_activity()
		for item_index, item in ipairs(turn.items or {}) do
			local fallback_id = ("turn:%d:item:%d"):format(turn_index, item_index)
			if item.type == "userMessage" then
				local text, labels = user_item_content(item)
				model:add_user(text, labels, { id = item.id or fallback_id })
			elseif item.type == "agentMessage" then
				local id = item.id or fallback_id
				model:ensure_agent(id)
				if item.text and item.text ~= "" then
					model:append_text(id, item.text)
				end
			else
				model:add_item(item, { id = fallback_id })
			end
		end
	end
	return model
end

function M.bind(bufnr, model)
	if bufnr and model then
		registry[bufnr] = model
	end
end

function M.unbind(bufnr)
	if bufnr then
		registry[bufnr] = nil
	end
end

function M.for_buffer(bufnr)
	return registry[bufnr]
end

M.Model = Model

return M
