local action = require("acp.action")
local output = require("acp.output")

local M = {}

local function cache_for(block)
	local revision = tonumber(block.revision) or 0
	local cache = block.semantic_cache
	if type(cache) ~= "table" or cache.revision ~= revision then
		cache = { revision = revision, references = {} }
		block.semantic_cache = cache
	end
	return cache
end

function M.invalidate(block)
	block.semantic_cache = nil
end

local function code_blocks_for(block)
	local values = {}
	for child_index, child in ipairs(block.children or {}) do
		if child.kind == "code" and child.line1 and child.line2 then
			local lines = vim.split(tostring(child.text or ""), "\n", { plain = true })
			local empty = #lines == 1 and lines[1] == ""
			local preview = not empty and vim.trim(lines[1]) or nil
			preview = preview ~= "" and preview or nil
			table.insert(values, {
				start_line = child.line1 - block.line1 + 1,
				end_line = child.line2 - block.line1 + 1,
				language = child.language or "text",
				filetype = output.filetype_for_language(child.language),
				lines = lines,
				line_count = empty and 0 or #lines,
				preview = preview,
				closed = child.closed ~= false,
				block_id = block.id,
				child_index = child_index,
			})
		end
	end
	return values
end

function M.local_code_blocks(block)
	local cache = cache_for(block)
	if cache.code_blocks == nil then
		cache.code_blocks = code_blocks_for(block)
	end
	return cache.code_blocks
end

local function diagnostics_for(block)
	local severity
	if block.kind == "error" then
		severity = vim.diagnostic.severity.ERROR
	elseif block.kind == "warning" then
		severity = vim.diagnostic.severity.WARN
	elseif block.kind == "activity" and block.status == "failed" then
		severity = vim.diagnostic.severity.ERROR
	end
	if not severity then
		return {}
	end

	local presentation = block.metadata and block.metadata.presentation
	local child = block.children and block.children[1]
	if block.kind == "activity" then
		for _, candidate in ipairs(block.children or {}) do
			if action.failed(candidate) then
				child = candidate
				break
			end
		end
	end
	local item = child and child.item or {}
	local message = block.metadata and block.metadata.problem_message or block.text
	if not message and block.kind == "activity" then
		local command = presentation == "command" or presentation == "explore"
		local label = command and tostring(item.command or "command") or tostring(item.tool or "tool")
		message = (command and "Command failed: " or "Tool failed: ") .. label
	end
	message =
		vim.trim(tostring(message or (severity == vim.diagnostic.severity.WARN and "Codex warning" or "Codex error")))
	local local_line = math.max(1, tonumber(block.header_offset) or 1)
	local text = tostring(block.lines[local_line] or "")
	return {
		{
			lnum = local_line - 1,
			col = 0,
			end_lnum = local_line - 1,
			end_col = #text,
			severity = severity,
			source = "acp.nvim",
			message = message,
			block_id = block.id,
		},
	}
end

function M.local_diagnostics(block)
	local cache = cache_for(block)
	if cache.diagnostics == nil then
		cache.diagnostics = diagnostics_for(block)
	end
	return cache.diagnostics
end

function M.local_references(block, cwd)
	local cache = cache_for(block)
	cwd = cwd or vim.fn.getcwd()
	local key = tostring(cwd)
	if cache.references[key] == nil then
		cache.references[key] = output.file_references(block.lines, { cwd = cwd, limit = 120 })
		for _, reference in ipairs(cache.references[key]) do
			reference.block_id = block.id
		end
	end
	return cache.references[key]
end

function M.shift(value, offset, fields)
	local copy = vim.tbl_extend("force", {}, value)
	for _, field in ipairs(fields) do
		if copy[field] ~= nil then
			copy[field] = copy[field] + offset
		end
	end
	return copy
end

function M.code_blocks(model)
	local values = {}
	for _, block in ipairs(model.blocks) do
		for _, local_block in ipairs(M.local_code_blocks(block)) do
			table.insert(values, M.shift(local_block, block.line1 - 1, { "start_line", "end_line" }))
		end
	end
	return values
end

function M.code_block_at(model, line)
	line = tonumber(line) or 1
	local block = model:block_at(line)
	if not block then
		return nil
	end
	local local_line = line - block.line1 + 1
	for _, local_block in ipairs(M.local_code_blocks(block)) do
		if local_line >= local_block.start_line and local_line <= local_block.end_line then
			return M.shift(local_block, block.line1 - 1, { "start_line", "end_line" })
		end
	end
end

function M.references(model, cwd, limit)
	limit = math.max(1, tonumber(limit) or 120)
	local values = {}
	local seen = {}
	for _, block in ipairs(model.blocks) do
		for _, local_reference in ipairs(M.local_references(block, cwd)) do
			local key = ("%s:%d:%d"):format(
				local_reference.path,
				local_reference.line or 1,
				local_reference.column or 1
			)
			if not seen[key] then
				seen[key] = true
				table.insert(values, M.shift(local_reference, block.line1 - 1, { "source_line" }))
				if #values >= limit then
					return values
				end
			end
		end
	end
	return values
end

function M.diagnostics(model)
	local values = {}
	for _, block in ipairs(model.blocks) do
		for _, local_diagnostic in ipairs(M.local_diagnostics(block)) do
			table.insert(values, M.shift(local_diagnostic, block.line1 - 1, { "lnum", "end_lnum" }))
		end
	end
	return values
end

function M.invalidate_references(model)
	for _, block in ipairs(model.blocks) do
		local cache = block.semantic_cache
		if type(cache) == "table" then
			cache.references = {}
		end
	end
end

return M
