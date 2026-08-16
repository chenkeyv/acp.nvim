local blocks = require("acp.blocks")

local M = {}

function M.page_size(value)
	return math.max(1, math.floor(tonumber(value) or 20))
end

function M.overscan(value)
	return math.max(0, math.floor(tonumber(value) or 5))
end

function M.model_turn_count(model)
	local count = 0
	for _, block in ipairs(type(model) == "table" and model.blocks or {}) do
		if block.kind == "user" and not (block.metadata and block.metadata.steer) then
			count = count + 1
		end
	end
	return count
end

local function copy_turn(turn, turn_index)
	local copy = vim.deepcopy(turn)
	for item_index, item in ipairs(copy.items or {}) do
		if item.id == nil or item.id == vim.NIL then
			item.id = ("turn:%d:item:%d"):format(turn_index, item_index)
		end
	end
	return copy
end

function M.from_thread(thread, requested_size, requested_overscan)
	local turns = type(thread) == "table" and type(thread.turns) == "table" and thread.turns or {}
	local size = M.page_size(requested_size)
	local overscan = M.overscan(requested_overscan)
	local pages = {}
	local counts = {}
	local ranges = {}
	if #turns == 0 then
		return { blocks.new() }, { 0 }, { { first = 1, last = 0, core_first = 1, core_last = 0 } }
	end
	for core_first = 1, #turns, size do
		local core_last = math.min(#turns, core_first + size - 1)
		local first = math.max(1, core_first - overscan)
		local last = math.min(#turns, core_last + overscan)
		local page_turns = {}
		for index = first, last do
			table.insert(page_turns, copy_turn(turns[index], index))
		end
		table.insert(pages, blocks.from_thread({ turns = page_turns }))
		table.insert(counts, core_last - core_first + 1)
		table.insert(ranges, { first = first, last = last, core_first = core_first, core_last = core_last })
	end
	return pages, counts, ranges
end

function M.tail_turns(model, requested_count)
	local count = M.overscan(requested_count)
	if count == 0 then
		return blocks.new()
	end
	local starts = {}
	for index, block in ipairs(type(model) == "table" and model.blocks or {}) do
		if block.kind == "user" and not (block.metadata and block.metadata.steer) then
			table.insert(starts, index)
		end
	end
	if #starts == 0 then
		return blocks.new()
	end
	local first = starts[math.max(1, #starts - count + 1)]
	local page = blocks.new()
	page.blocks = vim.deepcopy(vim.list_slice(model.blocks, first, #model.blocks))
	return blocks.adopt(page)
end

function M.adopt_pages(value)
	local pages = {}
	for _, page in ipairs(type(value) == "table" and value or {}) do
		if type(page) == "table" and type(page.blocks) == "table" then
			table.insert(pages, blocks.adopt(page))
		end
	end
	return pages
end

return M
