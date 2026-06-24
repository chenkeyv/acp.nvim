local M = {}

local severity_names = {
	[vim.diagnostic.severity.ERROR] = "ERROR",
	[vim.diagnostic.severity.WARN] = "WARN",
	[vim.diagnostic.severity.INFO] = "INFO",
	[vim.diagnostic.severity.HINT] = "HINT",
}

local severity_order = {
	[vim.diagnostic.severity.ERROR] = 1,
	[vim.diagnostic.severity.WARN] = 2,
	[vim.diagnostic.severity.INFO] = 3,
	[vim.diagnostic.severity.HINT] = 4,
}

local function clean(text)
	return tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_range(range)
	if type(range) ~= "table" or not range.line1 or not range.line2 then
		return nil
	end

	local line1 = math.max(1, tonumber(range.line1) or 1)
	local line2 = math.max(1, tonumber(range.line2) or line1)
	if line2 < line1 then
		line1, line2 = line2, line1
	end
	return {
		line1 = line1,
		line2 = line2,
	}
end

local function in_range(item, range)
	if not range then
		return true
	end

	local line = (item.lnum or 0) + 1
	return line >= range.line1 and line <= range.line2
end

local function buffer_path(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return "[No Name]"
	end
	return vim.fn.fnamemodify(name, ":.")
end

local function counts(items)
	local result = {
		[vim.diagnostic.severity.ERROR] = 0,
		[vim.diagnostic.severity.WARN] = 0,
		[vim.diagnostic.severity.INFO] = 0,
		[vim.diagnostic.severity.HINT] = 0,
	}

	for _, item in ipairs(items) do
		if result[item.severity] ~= nil then
			result[item.severity] = result[item.severity] + 1
		end
	end

	return result
end

function M.items(bufnr, opts)
	opts = opts or {}
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end

	local range = normalize_range(opts.range)
	local diagnostics = {}
	for _, item in ipairs(vim.diagnostic.get(bufnr)) do
		if in_range(item, range) then
			table.insert(diagnostics, item)
		end
	end

	table.sort(diagnostics, function(left, right)
		if (left.lnum or 0) ~= (right.lnum or 0) then
			return (left.lnum or 0) < (right.lnum or 0)
		end
		if (left.col or 0) ~= (right.col or 0) then
			return (left.col or 0) < (right.col or 0)
		end
		return (severity_order[left.severity] or 99) < (severity_order[right.severity] or 99)
	end)

	return diagnostics
end

function M.count(bufnr, opts)
	return #M.items(bufnr, opts)
end

function M.render(bufnr, opts)
	opts = opts or {}
	local diagnostics = M.items(bufnr, opts)
	if #diagnostics == 0 then
		return nil
	end

	local limit = opts.limit or 80
	local range = normalize_range(opts.range)
	local summary = counts(diagnostics)
	local lines = {
		"Diagnostics",
		("File: %s"):format(buffer_path(bufnr)),
		("Summary: %d error(s), %d warning(s), %d info, %d hint(s)"):format(
			summary[vim.diagnostic.severity.ERROR],
			summary[vim.diagnostic.severity.WARN],
			summary[vim.diagnostic.severity.INFO],
			summary[vim.diagnostic.severity.HINT]
		),
	}

	if range then
		table.insert(lines, ("Range: lines %d-%d"):format(range.line1, range.line2))
	end

	for index, item in ipairs(diagnostics) do
		if index > limit then
			table.insert(lines, ("- ... %d more diagnostic(s)"):format(#diagnostics - limit))
			break
		end

		local severity = severity_names[item.severity] or "INFO"
		local source = item.source and item.source ~= "" and (" [" .. item.source .. "]") or ""
		local code = item.code and item.code ~= "" and (" (" .. tostring(item.code) .. ")") or ""
		table.insert(lines, ("- %d:%d %s%s%s: %s"):format(
			(item.lnum or 0) + 1,
			(item.col or 0) + 1,
			severity,
			source,
			code,
			clean(item.message)
		))
	end

	return table.concat(lines, "\n")
end

return M
