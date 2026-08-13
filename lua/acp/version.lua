local M = {}

M.requirement = "Neovim nightly 0.13-dev or newer"

local function meets_minimum(info)
	if type(info) ~= "table" then
		return false
	end
	local major = tonumber(info.major)
	local minor = tonumber(info.minor)
	if not major or not minor then
		return false
	end
	return major > 0 or (major == 0 and minor >= 13)
end

function M.is_supported(info)
	return meets_minimum(info) and info.api_prerelease == true
end

function M.current()
	local info = vim.version()
	return vim.fn.has("nvim-0.13") == 1 and M.is_supported(info), info
end

function M.describe(info)
	info = info or vim.version()
	local text = ("%d.%d.%d"):format(tonumber(info.major) or 0, tonumber(info.minor) or 0, tonumber(info.patch) or 0)
	if type(info.prerelease) == "string" and info.prerelease ~= "" then
		text = text .. "-" .. info.prerelease
	end
	return text
end

function M.error_message(info)
	return ("acp.nvim requires %s; stable releases are not supported (detected Neovim %s)"):format(
		M.requirement,
		M.describe(info)
	)
end

function M.assert_supported()
	local supported, info = M.current()
	if not supported then
		error(M.error_message(info), 2)
	end
	return info
end

return M
