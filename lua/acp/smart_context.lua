local context = require("acp.context")
local hover = require("acp.hover")
local inlay_hints = require("acp.inlay_hints")
local selection_ranges = require("acp.selection_ranges")
local signature = require("acp.signature")

local M = {}

local function append_text(lines, title, text)
	if type(text) ~= "string" or text == "" then
		return
	end
	table.insert(lines, "")
	table.insert(lines, title)
	vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
end

local function append_inlay_hints(lines, hints, limit)
	if type(hints) ~= "table" or #hints == 0 then
		return
	end

	table.insert(lines, "")
	table.insert(lines, "Inlay hints:")
	for index, hint in ipairs(hints) do
		if index > limit then
			table.insert(lines, ("- ... %d more inlay hint(s)"):format(#hints - limit))
			break
		end
		table.insert(lines, ("- %d:%d %s %s"):format(
			hint.line or 1,
			hint.col or 1,
			hint.kind or "HINT",
			hint.label or "?"
		))
	end
end

local function append_selection_ranges(lines, ranges, limit)
	if type(ranges) ~= "table" or #ranges == 0 then
		return
	end

	table.insert(lines, "")
	table.insert(lines, "Selection ranges:")
	for index, item in ipairs(ranges) do
		if index > limit then
			table.insert(lines, ("- ... %d more selection range(s)"):format(#ranges - limit))
			break
		end
		local range = selection_ranges.range(item) or {}
		table.insert(lines, ("- %s lines %d-%d"):format(
			item.label or "semantic range",
			range.line1 or 1,
			range.line2 or range.line1 or 1
		))
	end
end

function M.prompt(source, data)
	data = data or {}
	local rendered_context = context.render(source, {
		treesitter_text_lines = 40,
		selection_limit = 160,
	})
	if not rendered_context then
		return nil
	end

	local lines = {
		"Use this smart editor context for a focused answer or change.",
		"",
		rendered_context,
	}
	append_text(lines, "Hover:", data.hover_text)
	append_text(lines, "Signature help:", data.signature_text)
	append_inlay_hints(lines, data.inlay_hints, data.inlay_limit or 12)
	append_selection_ranges(lines, data.selection_ranges, data.selection_limit or 8)
	return table.concat(lines, "\n")
end

function M.request(source, callback)
	local data = {
		errors = {},
	}
	local pending = 4

	local function finish(name, apply, err)
		if err then
			data.errors[name] = err
		elseif apply then
			apply()
		end
		pending = pending - 1
		if pending == 0 then
			callback(data, nil)
		end
	end

	local function run(name, fn)
		local done = false
		local function complete(apply, err)
			if done then
				return
			end
			done = true
			finish(name, apply, err)
		end

		local ok, err = pcall(fn, complete)
		if not ok then
			complete(nil, err)
		end
	end

	run("hover", function(done)
		hover.request(source, function(text, err)
			done(function()
				if text and text ~= "" then
					data.hover_text = text
				end
			end, err)
		end)
	end)

	run("signature", function(done)
		signature.request(source, function(text, err)
			done(function()
				if text and text ~= "" then
					data.signature_text = text
				end
			end, err)
		end)
	end)

	run("inlay_hints", function(done)
		inlay_hints.request(source, function(items, err, range)
			done(function()
				if items and #items > 0 then
					data.inlay_hints = items
					data.inlay_range = range
				end
			end, err)
		end)
	end)

	run("selection_ranges", function(done)
		selection_ranges.request(source, function(items, err)
			done(function()
				if items and #items > 0 then
					data.selection_ranges = items
				end
			end, err)
		end)
	end)

	return true
end

return M
