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

function M.sections(block)
	local cache = cache_for(block)
	if cache.sections == nil then
		cache.sections = output.sections(block.lines)
		for index, section in ipairs(cache.sections) do
			section.line2 = cache.sections[index + 1] and cache.sections[index + 1].line - 1 or #block.lines
		end
	end
	return cache.sections
end

function M.activities(block)
	local cache = cache_for(block)
	if cache.activities == nil then
		cache.activities = output.activity_groups(block.lines)
	end
	return cache.activities
end

function M.local_code_blocks(block)
	local cache = cache_for(block)
	if cache.code_blocks == nil then
		cache.code_blocks = output.code_blocks(block.lines)
	end
	return cache.code_blocks
end

function M.local_diagnostics(block)
	local cache = cache_for(block)
	if cache.diagnostics == nil then
		cache.diagnostics = output.problem_diagnostics(block.lines)
	end
	return cache.diagnostics
end

function M.local_references(block, cwd)
	local cache = cache_for(block)
	cwd = cwd or vim.fn.getcwd()
	local key = tostring(cwd)
	if cache.references[key] == nil then
		cache.references[key] = output.file_references(block.lines, { cwd = cwd, limit = 120 })
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
