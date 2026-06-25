local M = {
	acp = "󰚩",
	action = "󰌵",
	agent = "󰚩",
	blink = "󰂫",
	busy = "󰔟",
	call = "󰃷",
	changes = "󰏫",
	code = "",
	color = "",
	command = "",
	config = "",
	context = "󰉉",
	diagnostics = "󰒡",
	edit = "",
	error = "",
	file = "󰈙",
	fold = "",
	history = "󰋚",
	hint = "󰌶",
	hierarchy = "󰙅",
	idle = "",
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

function M.title(text, icon)
	return ("%s %s"):format(icon or M.acp, text or "ACP")
end

function M.quickfix_title(text)
	return M.title(text, M.quickfix)
end

return M
