local action = require("acp.action")
local render = require("acp.render")
local semantics = require("acp.block_semantics")
local transcript = require("acp.transcript")

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
			local end_line = math.min(#lines, index)
			table.insert(segments, {
				kind = "code",
				language = language ~= "" and language or "text",
				start_line = start_line,
				end_line = end_line,
				text = table.concat(content, "\n"),
			})
			index = index + 1
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
	local separated = kind ~= "legacy"
	local header_offset = opts.header_offset
	local content_offset = opts.content_offset
	if separated and lines[1] ~= "" then
		table.insert(lines, 1, "")
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
		children = opts.children or {},
		header_offset = header_offset,
		content_offset = content_offset,
		metadata = opts.metadata or {},
		separated = separated,
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

function Model:_replace_block_lines(block, lines)
	if not block then
		return nil
	end
	lines = copy_lines(lines)
	if block.separated and lines[1] ~= "" then
		table.insert(lines, 1, "")
	end
	if #lines == 0 then
		lines = { "" }
	end
	local old_line2 = block.line2
	local old_count = #block.lines
	block.lines = lines
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
	local lines = action.render_block(block)
	if #block.children == 1 then
		block.children[1].lines = copy_lines(lines)
		block.children[1].relative_line1 = block.header_offset or 1
		block.children[1].relative_line2 = (block.header_offset or 1) + #lines - 1
	end
	return self:_replace_block_lines(block, lines)
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
	local block = new_block(self, "activity", {
		id = item.id or opts.id,
		status = normalize_status(item.status),
		lines = action.render_block({
			children = { child },
			metadata = { presentation = presentation },
		}),
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
	local block = new_block(self, kind, {
		id = item.id or opts.id,
		status = status,
		text = item.text or item.review,
		lines = lines,
		children = content_segments(item.text or item.review or ""),
		header_offset = #lines > 1 and 2 or 1,
		content_offset = (kind == "plan" or kind == "review") and 3 or nil,
		metadata = { item = vim.deepcopy(item) },
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
	local block = new_block(self, kind, {
		id = opts.id,
		status = opts.status,
		text = message,
		lines = lines,
		header_offset = #lines > 1 and 2 or 1,
		metadata = opts.metadata,
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

function Model:section_at(line)
	local requested_line = type(line) == "table" and line.line1 or tonumber(line) or 1
	local block = type(line) == "table" and line or self:block_at(requested_line)
	if block and block.kind == "legacy" then
		local local_line = requested_line - block.line1 + 1
		local current
		for _, section in ipairs(semantics.sections(block)) do
			if section.line > local_line then
				break
			end
			current = section
		end
		if not current then
			return nil
		end
		local section = semantics.shift(current, block.line1 - 1, { "line", "line2" })
		section.total_lines = self.line_count
		section.block_id = block.id
		return section
	end
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
		if block.kind == "legacy" then
			for _, local_section in ipairs(semantics.sections(block)) do
				local section = semantics.shift(local_section, block.line1 - 1, { "line", "line2" })
				section.total_lines = self.line_count
				section.block_id = block.id
				table.insert(sections, section)
			end
		else
			local section = self:section_at(block)
			if section then
				table.insert(sections, section)
			end
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
	if block.kind == "legacy" then
		local values, range = require("acp.output").section_lines(block.lines, requested_line - block.line1 + 1, opts)
		if not values then
			return nil
		end
		return values, semantics.shift(range, block.line1 - 1, { "line1", "line2" })
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
	local requested_line = type(line) == "table" and line.line1 or tonumber(line) or 1
	local block = type(line) == "table" and line or self:block_at(requested_line)
	if block and block.kind == "legacy" then
		local local_line = requested_line - block.line1 + 1
		for _, local_group in ipairs(semantics.activities(block)) do
			if local_line >= local_group.line and local_line <= local_group.line2 then
				local group = semantics.shift(local_group, block.line1 - 1, { "line", "line2" })
				group.total_lines = self.line_count
				group.block_id = block.id
				return group
			end
		end
		return nil
	end
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
		if block.kind == "legacy" then
			for _, local_group in ipairs(semantics.activities(block)) do
				local group = semantics.shift(local_group, block.line1 - 1, { "line", "line2" })
				group.total_lines = self.line_count
				group.block_id = block.id
				table.insert(groups, group)
			end
		else
			local group = self:activity_at(block)
			if group then
				table.insert(groups, group)
			end
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
	local values = semantics.diagnostics(self)
	for _, block in ipairs(self.blocks) do
		local presentation = block.metadata and block.metadata.presentation
		if
			block.kind == "activity"
			and block.status == "failed"
			and (presentation == "command" or presentation == "tool")
		then
			local child = block.children and block.children[1]
			local item = child and child.item or {}
			local label = presentation == "command" and tostring(item.command or "command")
				or tostring(item.tool or "tool")
			table.insert(values, {
				lnum = (block.header_line or block.line1) - 1,
				col = 0,
				end_lnum = (block.header_line or block.line1) - 1,
				end_col = #(block.lines[block.header_offset or 1] or ""),
				severity = vim.diagnostic.severity.ERROR,
				source = "acp.nvim",
				message = (presentation == "command" and "Command failed: " or "Tool failed: ") .. label,
			})
		end
	end
	return values
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
	for index, block in ipairs(self.blocks or {}) do
		block.index = index
		block.id = present(block.id) and tostring(block.id) or block_id(self, block.kind)
		if block.separated == nil then
			block.separated = block.kind ~= "legacy"
		end
		block.lines = copy_lines(block.lines)
		if block.kind == "legacy" then
			for line_index, line in ipairs(block.lines) do
				block.lines[line_index] = transcript.migrate_line(line)
			end
		else
			local header_index = tonumber(block.header_offset)
			if header_index and block.lines[header_index] then
				block.lines[header_index] = transcript.migrate_line(block.lines[header_index])
			end
			if
				block.kind == "activity"
				or block.kind == "notice"
				or block.kind == "warning"
				or block.kind == "error"
			then
				for line_index, line in ipairs(block.lines) do
					block.lines[line_index] = transcript.migrate_line(line)
				end
			end
		end
		block.children = block.children or {}
		for _, child in ipairs(block.children) do
			if type(child.lines) == "table" then
				for line_index, line in ipairs(child.lines) do
					child.lines[line_index] = transcript.migrate_line(line)
				end
			end
		end
		local presentation = block.metadata and block.metadata.presentation
		if
			block.kind == "activity"
			and (presentation == "command" or presentation == "tool" or presentation == "explore")
		then
			local rendered = action.render_block(block)
			block.lines = block.separated == false and rendered or vim.list_extend({ "" }, rendered)
			block.header_offset = block.separated == false and 1 or 2
			if #block.children == 1 then
				block.children[1].lines = copy_lines(rendered)
				block.children[1].relative_line1 = block.header_offset
				block.children[1].relative_line2 = block.header_offset + #rendered - 1
			end
		end
		if block.separated and block.lines[1] ~= "" then
			table.insert(block.lines, 1, "")
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
		block.revision = tonumber(block.revision) or 1
		semantics.invalidate(block)
		block.line1 = self.line_count + 1
		block.line2 = self.line_count + #block.lines
		self.line_count = block.line2
		self.by_id[block.id] = block
		index_activity_children(self, block)
		refresh_block_ranges(block)
	end
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
	local last = value.blocks[#value.blocks]
	value.activity_open = value.activity_open == true and last and last.kind == "activity" or false
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

function M.from_lines(lines)
	local model = M.new()
	lines = copy_lines(lines)
	if #lines == 0 or (#lines == 1 and lines[1] == "") then
		return model
	end
	for index, line in ipairs(lines) do
		lines[index] = transcript.migrate_line(line)
	end
	model:_append_block(new_block(model, "legacy", {
		id = "legacy:transcript",
		lines = lines,
		header_offset = 1,
		metadata = { migrated = true },
	}))
	model:break_activity()
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
