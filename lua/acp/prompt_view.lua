local M = {}

local function trim(text)
	return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function word_count(text)
	local count = 0
	for _ in tostring(text or ""):gmatch("%S+") do
		count = count + 1
	end
	return count
end

function M.define_highlights()
	vim.api.nvim_set_hl(0, "AcpPromptGhost", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AcpPromptStats", { link = "Comment", default = true })
end

function M.info(lines, opts)
	opts = opts or {}
	lines = lines or { "" }
	local text = table.concat(lines, "\n")
	local content = trim(text)

	if content == "" then
		local hint = opts.busy and "Agent is responding - <leader>aq stop"
			or "Ask ACP - <C-s> send | ? actions | <C-Space> completion"
		return {
			empty = true,
			ghost = hint,
		}
	end

	local line_count = math.max(1, #lines)
	local chars = vim.fn.strchars(text)
	local words = word_count(content)
	return {
		empty = false,
		stats = ("%d line%s | %d char%s | %d word%s"):format(
			line_count,
			line_count == 1 and "" or "s",
			chars,
			chars == 1 and "" or "s",
			words,
			words == 1 and "" or "s"
		),
	}
end

return M
