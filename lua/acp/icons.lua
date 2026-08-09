local M = {}

local nerd = {
	acp = "󰚩",
	action = "󰌵",
	agent = "󰚩",
	arrow_right = "",
	blink = "󰂫",
	busy = "󰔟",
	call = "󰃷",
	changes = "󰏫",
	close = "󰅖",
	code = "",
	color = "",
	command = "",
	config = "",
	context = "󰉉",
	diagnostics = "󰒡",
	edit = "",
	enter = "󰌑",
	error = "",
	file = "󰈙",
	filter = "",
	fold = "",
	history = "󰋚",
	hint = "󰌶",
	hierarchy = "󰙅",
	help = "󰋖",
	idle = "",
	info = "",
	inspect = "󰍉",
	jump = "󰁔",
	key = "󰌌",
	link = "",
	location = "",
	lsp = "",
	map = "󰍍",
	model = "󰚩",
	note = "󰎚",
	package = "󰏗",
	pulse_empty = "",
	pulse_full = "",
	pulse_mid = "",
	preferred = "",
	prompt = "󰭻",
	quickfix = "󰁨",
	reference = "",
	restore = "󰑓",
	scope = "󰆐",
	search = "",
	section = "",
	send = "󰒊",
	session = "󰒲",
	source = "󰈙",
	status = "󰐊",
	stop = "",
	symbol = "󰆧",
	terminal = "",
	tool = "",
	treesitter = "",
	type = "󰊄",
	user = "",
	warning = "",
	yank = "",
}

local text = {
	agent = "A",
	busy = "*",
	changes = "~",
	code = "{}",
	command = ">",
	context = "@",
	error = "!",
	history = "+",
	idle = "+",
	info = "i",
	note = "-",
	section = "#",
	send = ">",
	status = "*",
	tool = "T",
	user = "U",
	warning = "!",
}

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local text_spinner = { "|", "/", "-", "\\" }

for name, glyph in pairs(nerd) do
	M[name] = glyph
end

function M.get(name)
	local values = vim.g.have_nerd_font == false and text or nerd
	return values[name] or text[name] or "·"
end

function M.spinner(index)
	local values = vim.g.have_nerd_font == false and text_spinner or spinner
	local number = math.max(1, math.floor(tonumber(index) or 1))
	return values[((number - 1) % #values) + 1]
end

return M
