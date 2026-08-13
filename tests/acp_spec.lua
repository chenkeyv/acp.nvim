local approval = require("acp.approval")
local action = require("acp.action")
local blocks = require("acp.blocks")
local Client = require("acp.codex").Client
local completion = require("acp.completion")
local completion_source = require("acp.completion.source")
local context = require("acp.context")
local health = require("acp.health")
local icons = require("acp.icons")
local jsonrpc = require("acp.jsonrpc")
local output = require("acp.output")
local output_ui = require("acp.output_ui")
local permission = require("acp.permission")
local render = require("acp.render")
local requests = require("acp.requests")
local server_log = require("acp.server_log")
local transcript = require("acp.transcript")
local treesitter = require("acp.treesitter")
local ui = require("acp.ui")
local version = require("acp.version")
local view = require("acp.view")

local tests = {}

local function test(name, callback)
	table.insert(tests, { name = name, callback = callback })
end

local function eq(actual, expected)
	if not vim.deep_equal(actual, expected) then
		error(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)), 2)
	end
end

local function ok(value, message)
	if not value then
		error(message or "expected truthy value", 2)
	end
end

local function contains(text, fragment)
	ok(tostring(text):find(fragment, 1, true), ("expected %q to contain %q"):format(text, fragment))
end

local function count(text, fragment)
	local total = 0
	local start = 1
	while true do
		local first, last = text:find(fragment, start, true)
		if not first then
			return total
		end
		total = total + 1
		start = last + 1
	end
end

local function chunks_text(chunks)
	local values = {}
	for _, chunk in ipairs(chunks or {}) do
		table.insert(values, type(chunk) == "table" and (chunk[1] or "") or tostring(chunk))
	end
	return table.concat(values)
end

local function server_error_stderr()
	return table.concat({
		"\27[2m2026-08-08T23:36:02.598319Z\27[0m ",
		"\27[31mERROR\27[0m ",
		"\27[2mcodex_core::tools::router\27[0m\27[2m:\27[0m ",
		"\27[3merror\27[0m\27[2m=\27[0m",
		[=[exec_command failed for `/bin/zsh -lc 'git ls-remote origin refs/heads/main'`: CreateProcess { message: "Rejected(\"This action was rejected due to unacceptable risk.\\nReason: Automatic approval review failed: stream disconnected before completion.\\nProceed only with a materially safer alternative.\")" }]=],
	})
end

local function model_refresh_stderr()
	return "2026-08-10T08:00:00.000000Z ERROR codex_models_manager::manager: "
		.. "failed to refresh available models: timeout waiting for child process to exit\n"
end

local function apply_patch_error_stderr()
	return table.concat({
		"2026-08-10T08:00:00.000000Z ERROR codex_core::tools::router: ",
		"apply_patch verification failed: Failed to find expected lines in ",
		"/Users/keyv/Developer/acp.nvim/README.md:\n\n",
		"its inset from the chat text area. Prompt, model, reasoning, and context metadata\n",
		"sit on the lower-left border, while the send and steer hints remain on the\n",
		"right. A blank top row separates the turn panel from the chat, while the\n",
	})
end

local function fake_process()
	local process = { writes = {} }
	local handle = {}

	function handle:write(data)
		for line in data:gmatch("[^\n]+") do
			table.insert(process.writes, vim.json.decode(line))
		end
	end

	function handle:kill(signal)
		process.killed = signal
	end

	process.spawn = function(command, options, on_exit)
		process.command = command
		process.options = options
		process.on_exit = on_exit
		return handle
	end

	return process
end

test("version contract accepts only Neovim 0.13+ development builds", function()
	ok(version.is_supported({ major = 0, minor = 13, patch = 0, api_prerelease = true }))
	ok(version.is_supported({ major = 0, minor = 14, patch = 0, api_prerelease = true }))
	ok(not version.is_supported({ major = 0, minor = 12, patch = 9, api_prerelease = true }))
	ok(not version.is_supported({ major = 0, minor = 13, patch = 0, api_prerelease = false }))
	ok(not version.is_supported({ major = 0, minor = 14, patch = 0, api_prerelease = false }))
	contains(version.error_message({ major = 0, minor = 13, patch = 0 }), "stable releases are not supported")
	local supported = version.current()
	ok(supported, "the test suite requires a supported Neovim nightly")
end)

test("plugin loading rejects unsupported Neovim before marking itself loaded", function()
	local original_current = version.current
	local original_loaded = vim.g.loaded_acp_nvim
	version.current = function()
		return false, { major = 0, minor = 13, patch = 0, prerelease = nil, api_prerelease = false }
	end
	vim.g.loaded_acp_nvim = nil
	local plugin = vim.fs.joinpath(vim.fn.getcwd(), "plugin", "acp.lua")
	local loaded, err = pcall(dofile, plugin)
	local marked_loaded = vim.g.loaded_acp_nvim
	local init = vim.fs.joinpath(vim.fn.getcwd(), "lua", "acp", "init.lua")
	local required, require_err = pcall(dofile, init)
	version.current = original_current
	vim.g.loaded_acp_nvim = original_loaded
	ok(not loaded, "stable Neovim should be rejected")
	contains(err, "stable releases are not supported")
	eq(marked_loaded, nil)
	ok(not required, "explicit require should reject stable Neovim")
	contains(require_err, "stable releases are not supported")
end)

local function with_permission_select(replacement, callback)
	local original = permission.select
	permission.select = replacement
	local passed, err = pcall(callback)
	permission.select = original
	if not passed then
		error(err, 2)
	end
end

test("app-server messages omit the JSON-RPC version field", function()
	local request = jsonrpc.request(1, "thread/list", { limit = 10 })
	local notification = jsonrpc.notification("initialized")
	local response = jsonrpc.result(1, { ready = true })

	eq(request.method, "thread/list")
	eq(request.params.limit, 10)
	eq(request.jsonrpc, nil)
	eq(notification.method, "initialized")
	eq(notification.params, nil)
	eq(notification.jsonrpc, nil)
	eq(response.result.ready, true)
end)

test("line buffer emits complete non-empty JSONL records", function()
	local lines = {}
	local buffer = jsonrpc.LineBuffer.new()
	buffer:push('{"one":1}\n{"two":', function(line)
		table.insert(lines, line)
	end)
	buffer:push("2}\r\n\n", function(line)
		table.insert(lines, line)
	end)
	eq(lines, { '{"one":1}', '{"two":2}' })
	buffer:reset()
	eq(buffer.data, "")
end)

test("Codex server logs normalize and classify transcript notices", function()
	local notices = server_log.parse(server_error_stderr())
	eq(#notices, 1)
	local notice = notices[1]
	eq(notice.kind, "error")
	eq(notice.metadata.server_log.level, "ERROR")
	eq(notice.metadata.server_log.source, "codex_core::tools::router")
	eq(notice.metadata.server_log.timestamp, "2026-08-08T23:36:02.598319Z")
	local text = table.concat(notice.lines, "\n")
	contains(text, transcript.line("error", "Codex server · tools/router"))
	contains(text, "exec_command failed for `/bin/zsh -lc 'git ls-remote origin refs/heads/main'`")
	contains(text, "Rejected: This action was rejected due to unacceptable risk.")
	contains(text, "\n  Reason: Automatic approval review failed")
	contains(text, "\n  Proceed only with a materially safer alternative.")
	ok(not text:find("\27", 1, true), "ANSI escapes must not reach the transcript")
	ok(not text:find("2026-08-08", 1, true), "transport timestamps should stay in metadata")
	ok(not text:find("CreateProcess", 1, true), "Rust debug wrappers should be unwrapped")
	ok(not text:find("\\n", 1, true), "escaped newlines should become native buffer lines")

	local plain = server_log.parse("\27[33mconnection warning\27[0m\n")
	eq(#plain, 1)
	eq(plain[1].kind, "warning")
	contains(table.concat(plain[1].lines, "\n"), transcript.line("warning", "Codex server"))
	contains(table.concat(plain[1].lines, "\n"), "connection warning")
	eq(server_log.parse("could not create PATH aliases\n"), {})

	local refresh = server_log.parse(model_refresh_stderr())
	eq(#refresh, 1)
	ok(server_log.is_background_noise(refresh[1]))
	ok(server_log.should_suppress(refresh[1]))
	ok(not server_log.is_background_noise(notice), "tool failures are not background work")
	ok(server_log.is_duplicate_tool_failure(notice))
	ok(server_log.should_suppress(notice), "command failures already render in their action cell")
	local other_manager_error = server_log.parse(
		"2026-08-10T08:00:00.000000Z ERROR codex_models_manager::manager: failed to load configured model\n"
	)
	ok(not server_log.is_background_noise(other_manager_error[1]), "other model-manager errors must remain visible")
	ok(not server_log.should_suppress(other_manager_error[1]), "actionable model-manager errors must remain visible")

	local patch_notices = server_log.parse(apply_patch_error_stderr())
	eq(#patch_notices, 1)
	local patch_notice = patch_notices[1]
	eq(patch_notice.kind, "error")
	eq(patch_notice.metadata.server_log.source, "codex_core::tools::router")
	eq(patch_notice.lines, {
		"",
		transcript.line("error", "Codex server · tools/router"),
		"  apply_patch verification failed: Failed to find expected lines in /Users/keyv/Developer/acp.nvim/README.md:",
		"",
		"  its inset from the chat text area. Prompt, model, reasoning, and context metadata",
		"  sit on the lower-left border, while the send and steer hints remain on the",
		"  right. A blank top row separates the turn panel from the chat, while the",
	})
	ok(server_log.is_duplicate_tool_failure(patch_notice))
	ok(server_log.should_suppress(patch_notice), "patch failures already render in their action cell")
	local followed_by_warning = server_log.parse(
		apply_patch_error_stderr() .. "2026-08-10T08:00:01.000000Z WARN codex_core::client: connection warning\n"
	)
	eq(#followed_by_warning, 2)
	eq(followed_by_warning[1].kind, "error")
	eq(followed_by_warning[2].kind, "warning")
	eq(followed_by_warning[2].metadata.server_log.source, "codex_core::client")
	ok(not server_log.should_suppress(followed_by_warning[2]), "transport warnings must remain visible")

	local other_router_error =
		server_log.parse("2026-08-10T08:00:02.000000Z ERROR codex_core::tools::router: tool registry unavailable\n")
	ok(not server_log.should_suppress(other_router_error[1]), "unknown router failures must remain visible")
end)

test("client performs the app-server handshake in order", function()
	local process = fake_process()
	local client = Client.new({ command = "codex", spawn = process.spawn })
	local initialized

	client:initialize(function(success, result)
		initialized = { success = success, result = result }
	end)

	eq(process.command, { "codex", "app-server" })
	eq(#process.writes, 1)
	eq(process.writes[1].method, "initialize")
	eq(process.writes[1].params.clientInfo.name, "acp_nvim")
	eq(process.writes[1].params.capabilities, nil)
	eq(initialized, nil)

	client:handle_message({ id = 0, result = { serverInfo = { name = "codex" } } })
	eq(process.writes[2].method, "initialized")
	eq(initialized.success, true)
	eq(initialized.result.serverInfo.name, "codex")
	client:stop()
	eq(process.killed, 15)
end)

test("requests wait for initialization and route responses", function()
	local process = fake_process()
	local client = Client.new({ spawn = process.spawn })
	local models

	client:list_models(function(result, err)
		eq(err, nil)
		models = result
	end)
	eq(#process.writes, 1)
	eq(process.writes[1].method, "initialize")

	client:handle_message({ id = 0, result = { serverInfo = {} } })
	eq(process.writes[2].method, "initialized")
	eq(process.writes[3].method, "model/list")
	client:handle_message({ id = 1, result = { data = { { id = "gpt-test" } }, nextCursor = vim.NIL } })
	eq(models[1].id, "gpt-test")
	eq(#process.writes, 3)
	client:stop()
end)

test("client exposes the Codex completion request contracts", function()
	local process = fake_process()
	local client = Client.new({ spawn = process.spawn })
	client:start()
	client.initialized = true
	local results = {}

	client:list_skills("/tmp/project", function(result, err)
		results.skills = { result = result, err = err }
	end)
	client:list_apps("thread-1", function(result, err)
		results.apps = { result = result, err = err }
	end)
	client:search_files("comp", { "/tmp/project" }, function(result, err)
		results.files = { result = result, err = err }
	end)
	client:set_thread_name("thread-1", "release prep", function(result, err)
		results.name = { result = result, err = err }
	end)

	eq(process.writes[1].method, "skills/list")
	eq(process.writes[1].params, { cwds = { "/tmp/project" } })
	eq(process.writes[2].method, "app/installed")
	eq(process.writes[2].params, { forceRefresh = false, threadId = "thread-1" })
	eq(process.writes[3].method, "fuzzyFileSearch")
	eq(process.writes[3].params, { query = "comp", roots = { "/tmp/project" } })
	eq(process.writes[4].method, "thread/name/set")
	eq(process.writes[4].params, { threadId = "thread-1", name = "release prep" })

	client:handle_message({ id = 0, result = { data = { { cwd = "/tmp/project", skills = {} } } } })
	client:handle_message({ id = 1, result = { apps = { { id = "github", callable = true, enabled = true } } } })
	client:handle_message({ id = 2, result = { files = { { path = "lua/acp/ui.lua" } } } })
	client:handle_message({ id = 3, result = {} })
	eq(results.skills.result.data[1].cwd, "/tmp/project")
	eq(results.apps.result[1].id, "github")
	eq(results.files.result.files[1].path, "lua/acp/ui.lua")
	eq(results.name.result, {})
	client:stop()
end)

local function completion_context(line, bufnr)
	return {
		bufnr = bufnr or vim.api.nvim_get_current_buf(),
		line = line,
		cursor = { 1, #line },
		bounds = { line_number = 1, start_col = 1, length = #line },
		trigger = { kind = "manual", initial_kind = "manual" },
	}
end

local function completion_labels(items)
	return vim.tbl_map(function(item)
		return item.label
	end, items or {})
end

test("Codex completion parses native tokens and publishes the documented commands", function()
	eq(completion_source.token(completion_context("/mod")), { prefix = "/", query = "mod", start_col = 0 })
	eq(completion_source.token(completion_context("Use $skill")), { prefix = "$", query = "skill", start_col = 4 })
	eq(completion_source.token(completion_context("Open @lua/acp")), { prefix = "@", query = "lua/acp", start_col = 5 })
	eq(completion_source.token(completion_context("dictionary")), {
		prefix = "word",
		query = "dictionary",
		start_col = 0,
	})
	eq(completion_source.token(completion_context("https://example.com")), {
		prefix = "word",
		query = "com",
		start_col = 16,
	})

	local commands = completion_source._command_items(completion_context("/"), {
		prefix = "/",
		query = "",
		start_col = 0,
	})
	local labels = completion_labels(commands)
	for _, command in ipairs({
		"/permissions",
		"/apps",
		"/plugins",
		"/skills",
		"/mention",
		"/model",
		"/plan",
		"/goal",
		"/review",
		"/status",
		"/usage",
		"/theme",
		"/pet",
	}) do
		ok(vim.tbl_contains(labels, command), "missing Codex command: " .. command)
	end
	ok(vim.tbl_contains(labels, "/reasoning"), "expected the acp.nvim reasoning selector")
	ok(not vim.tbl_contains(labels, "/clean"), "undocumented /clean must not be advertised")
	for _, item in ipairs(commands) do
		eq(item.textEdit.range.start.character, 0)
		eq(item.textEdit.range["end"].character, 1)
	end
end)

test("Codex completion maps skills, apps, and files to Blink items", function()
	local ctx = completion_context("$")
	local token = { prefix = "$", query = "", start_col = 0 }
	local skills = completion_source._skill_items(ctx, token, {
		data = {
			{
				cwd = "/tmp/project",
				skills = {
					{
						name = "review-code",
						path = "/tmp/skills/review-code/SKILL.md",
						description = "Review code",
						enabled = true,
						scope = "user",
					},
					{ name = "disabled", path = "/tmp/disabled", description = "", enabled = false },
				},
			},
		},
	})
	eq(#skills, 1)
	eq(skills[1].label, "$review-code")
	eq(skills[1].data, {
		acp_kind = "skill",
		name = "review-code",
		path = "/tmp/skills/review-code/SKILL.md",
	})

	local apps = completion_source._app_items(ctx, token, {
		{ id = "github", runtimeName = "GitHub", callable = true, enabled = true },
		{ id = "off", runtimeName = "Off", callable = false, enabled = true },
	})
	eq(#apps, 1)
	eq(apps[1].label, "$github")
	eq(apps[1].data.acp_kind, "app")

	ctx = completion_context("@lua")
	local files = completion_source._file_items(ctx, { prefix = "@", query = "lua", start_col = 0 }, {
		files = {
			{
				file_name = "completion.lua",
				match_type = "file",
				path = "lua/acp/completion.lua",
				root = "/tmp/project",
				score = 400,
			},
			{
				file_name = "acp",
				match_type = "directory",
				path = "lua/acp",
				root = "/tmp/project",
				score = 300,
			},
		},
	})
	eq(completion_labels(files), { "@lua/acp/completion.lua", "@lua/acp/" })
	eq(files[1].data.path, "/tmp/project/lua/acp/completion.lua")
	eq(files[2].data.name, "acp")
end)

test("Codex mentions become structured app-server input with byte ranges", function()
	completion_source.clear_cache()
	local ctx = completion_context("$")
	local source = completion_source.new()
	local original_client = ui._client()
	local fake = {}
	function fake:set_handlers() end
	function fake:list_skills(_, callback)
		callback({
			data = {
				{
					cwd = vim.fn.getcwd(),
					skills = {
						{
							name = "review-code",
							path = "/tmp/skills/review-code/SKILL.md",
							description = "Review code",
							enabled = true,
							scope = "user",
						},
					},
				},
			},
		})
	end
	function fake:list_apps(_, callback)
		callback({ { id = "github", runtimeName = "GitHub", callable = true, enabled = true } })
	end
	function fake:search_files(_, _, callback)
		callback({ files = {} })
	end
	function fake:stop() end
	ui._set_client(fake)
	source:get_completions(ctx, function() end)

	local root = vim.fn.tempname()
	vim.fn.mkdir(vim.fs.joinpath(root, "lua"), "p")
	local path = vim.fs.joinpath(root, "lua", "demo.lua")
	vim.fn.writefile({ "return true" }, path)
	local text = "Use $review-code and $github on @lua/demo.lua; ignore $unknown."
	local input, elements = completion.input(text, root)
	eq(input, {
		{ type = "skill", name = "review-code", path = "/tmp/skills/review-code/SKILL.md" },
		{ type = "mention", name = "demo.lua", path = path },
	})
	eq(
		vim.tbl_map(function(element)
			return element.placeholder
		end, elements),
		{ "$review-code", "$github", "@lua/demo.lua" }
	)
	for _, element in ipairs(elements) do
		eq(text:sub(element.byteRange.start + 1, element.byteRange["end"]), element.placeholder)
	end

	vim.fn.delete(root, "rf")
	ui._set_client(original_client)
end)

test("dictionary completion is asynchronous, bounded, and cached", function()
	completion_source.clear_cache()
	local dictionary = vim.fn.tempname()
	vim.fn.writefile({ "completion", "completions", "compiler", "compare", "other" }, dictionary)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].dictionary = dictionary
	local synchronous = true
	local words
	local started = vim.uv.hrtime()
	local command
	local options
	local process_callback
	local process = { killed = false }
	function process:kill()
		self.killed = true
	end
	local function spawn(cmd, opts, callback)
		command = cmd
		options = opts
		process_callback = callback
		return process
	end
	completion_source._dictionary_words(bufnr, "comp", function(result)
		synchronous = false
		words = result
	end, spawn)
	ok((vim.uv.hrtime() - started) / 1e6 < 50, "dictionary lookup must not block the prompt")
	ok(synchronous, "dictionary process should complete asynchronously")
	eq(options, { text = true })
	ok(vim.tbl_contains(command, "--ignore-case"))
	ok(vim.tbl_contains(command, "40"))
	eq(command[#command], dictionary)
	process_callback({ code = 0, stdout = "completion\ncompletions\ncompiler\ncompare\n" })
	ok(
		vim.wait(100, function()
			return words ~= nil
		end, 5),
		"dictionary callback timed out"
	)
	eq(words, { "completion", "completions", "compiler", "compare" })

	local cached
	completion_source._dictionary_words(bufnr, "comp", function(result)
		cached = result
	end)
	eq(cached, words)
	local items = completion_source._dictionary_items(
		completion_context("comp", bufnr),
		{ prefix = "word", query = "comp", start_col = 0 },
		words
	)
	eq(completion_labels(items), words)
	vim.api.nvim_buf_delete(bufnr, { force = true })
	vim.fn.delete(dictionary)
end)

test("turn requests use the current stable app-server shape", function()
	local process = fake_process()
	local client = Client.new({ spawn = process.spawn })
	client:start()
	client.initialized = true

	client:start_turn("thread-1", {
		text = "fix this",
		cwd = "/tmp/project",
		model = "gpt-test",
		effort = "high",
		additional_context = {
			["nvim:1"] = { kind = "application", value = "Selected line" },
		},
	}, function() end)

	local message = process.writes[1]
	eq(message.method, "turn/start")
	eq(message.params.threadId, "thread-1")
	eq(message.params.input[1], { type = "text", text = "fix this", text_elements = {} })
	eq(message.params.cwd, "/tmp/project")
	eq(message.params.model, "gpt-test")
	eq(message.params.effort, "high")
	eq(message.params.additionalContext["nvim:1"].kind, "application")
	client:stop()
end)

test("thread listing paginates and preserves extension sources", function()
	local process = fake_process()
	local client = Client.new({ spawn = process.spawn })
	client:start()
	client.initialized = true
	local threads

	client:list_threads({
		cwd = "/tmp/project",
		source_kinds = { "appServer", "vscode" },
		max_threads = 3,
	}, function(result)
		threads = result
	end)

	eq(process.writes[1].params.cwd, "/tmp/project")
	eq(process.writes[1].params.sourceKinds, { "appServer", "vscode" })
	client:handle_message({ id = 0, result = { data = { { id = "a" } }, nextCursor = "next" } })
	eq(process.writes[2].params.cursor, "next")
	client:handle_message({ id = 1, result = { data = { { id = "b" } }, nextCursor = vim.NIL } })
	eq({ threads[1].id, threads[2].id }, { "a", "b" })
	eq(#process.writes, 2)
	client:stop()
end)

test("client dispatches notifications and replies to server requests", function()
	local process = fake_process()
	local notification
	local client = Client.new({
		spawn = process.spawn,
		on_notification = function(method, params)
			notification = { method = method, params = params }
		end,
		on_request = function(method, params, reply)
			eq(method, "test/request")
			reply({ echoed = params.value })
			return true
		end,
	})
	client:start()
	client.initialized = true

	client:handle_message({ method = "test/event", params = { value = 3 } })
	eq(notification, { method = "test/event", params = { value = 3 } })
	client:handle_message({ id = 7, method = "test/request", params = { value = 4 } })
	eq(process.writes[1], { id = 7, result = { echoed = 4 } })

	client.on_request = nil
	client:handle_message({ id = 8, method = "unknown/request" })
	eq(process.writes[2].error.code, jsonrpc.errors.method_not_found)
	client:stop()
end)

test("editor context becomes mentions and bounded application context", function()
	local bufnr = vim.api.nvim_create_buf(false, false)
	vim.bo[bufnr].swapfile = false
	local path = vim.fn.getcwd() .. "/lua/acp/example.lua"
	vim.api.nvim_buf_set_name(bufnr, path)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three", "four" })

	local file = context.file(bufnr, vim.fn.getcwd())
	local selection = context.selection(bufnr, { line1 = 2, line2 = 4 }, vim.fn.getcwd(), { max_lines = 2 })
	local contexts = {}
	eq(context.add(contexts, file), true)
	eq(context.add(contexts, file), false)
	eq(context.add(contexts, selection), true)

	local input, additional, labels = context.turn_payload(contexts)
	eq(input[1], { type = "mention", name = "example.lua", path = path })
	contains(additional["nvim:2"].value, "lines 2-4")
	contains(additional["nvim:2"].value, "selection truncated")
	eq(labels, { "lua/acp/example.lua", "lua/acp/example.lua:2-4" })
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("structured thread model renders history and diffs", function()
	local thread = {
		id = "thread-1",
		preview = "Fix the parser",
		updatedAt = 1,
		turns = {
			{
				items = {
					{ type = "userMessage", content = { { type = "text", text = "Please fix it" } } },
					{
						type = "commandExecution",
						command = "\27[31mnvim --headless\27[0m",
						status = "completed",
						exitCode = 0,
					},
					{
						type = "fileChange",
						status = "completed",
						changes = {
							{
								path = "lua/acp/ui.lua",
								kind = { type = "update", move_path = vim.NIL },
								diff = "--- a\n+++ b",
							},
						},
					},
					{ type = "agentMessage", text = "Done." },
				},
			},
		},
	}
	local text = table.concat(blocks.from_thread(thread):render_lines(), "\n")
	contains(text, render.header("user"))
	contains(text, "Please fix it")
	contains(text, "nvim --headless")
	ok(not text:find("\27", 1, true), "ANSI escape sequences should be removed")
	contains(text, "lua/acp/ui.lua")
	contains(text, render.header("agent"))
	contains(text, "Done.")
	ok(not text:find("Working directory:", 1, true), "working-directory metadata belongs in window chrome")
	eq(render.thread_diff(thread), "--- a\n+++ b")
	contains(render.thread_label(thread), "Fix the parser")
	local failed_change = render.completed_item({
		type = "fileChange",
		status = "failed",
		changes = { { path = "lua/acp/ui.lua", kind = { type = "update", move_path = vim.NIL } } },
	})[1]
	contains(failed_change, "File changes: failed")
end)

test("chat blocks preserve roles, action cells, code, and failures", function()
	local chat = blocks.from_thread({
		turns = {
			{
				items = {
					{ id = "user-1", type = "userMessage", content = { { type = "text", text = "Inspect it" } } },
					{
						id = "command-1",
						type = "commandExecution",
						command = "rg blocks",
						status = "completed",
						exitCode = 0,
						aggregatedOutput = "lua/acp/blocks.lua\nREADME.md",
					},
					{
						id = "change-1",
						type = "fileChange",
						status = "completed",
						changes = { { path = "lua/acp/blocks.lua", kind = { type = "update" } } },
					},
					{
						id = "agent-1",
						type = "agentMessage",
						text = "Implemented.\n```lua\nreturn true\n```\nDone.",
					},
					{
						id = "command-2",
						type = "commandExecution",
						command = "false",
						status = "completed",
						exitCode = 1,
						aggregatedOutput = "boom",
					},
				},
			},
		},
	})

	eq(
		vim.tbl_map(function(block)
			return block.kind
		end, chat.blocks),
		{ "user", "activity", "activity", "agent", "activity" }
	)
	eq(#chat.blocks[2].children, 1)
	eq(chat.blocks[2].children[1].kind, "command")
	eq(chat.blocks[2].metadata.presentation, "command")
	eq(chat.blocks[3].children[1].kind, "file")
	local activity = chat:activities()[1]
	eq(activity.line, chat.blocks[2].header_line)
	eq(activity.line2, chat.blocks[2].line2)
	eq(activity.counts, { command = 1, tool = 0, file = 0 })
	eq(#chat:activities(), 3)
	local rendered = chat:render_lines()
	for index, block in ipairs(chat.blocks) do
		eq(block.lines[1], "")
		if index > 1 then
			ok(rendered[block.line1 - 1] ~= "", "expected exactly one blank row between top-level cells")
		end
	end

	local code
	for _, child in ipairs(chat.by_id["agent-1"].children) do
		if child.kind == "code" then
			code = child
		end
	end
	eq(code.language, "lua")
	eq(code.text, "return true")
	eq(chat:render_lines()[code.line1], "```lua")
	eq(chat:render_lines()[code.line2], "```")
	ok(code.line1 >= chat.by_id["agent-1"].line1)
	ok(code.line2 <= chat.by_id["agent-1"].line2)
	eq(chat:block_at(code.line1).id, "agent-1")
	eq(chat:section_at(code.line1).kind, "AGENT")

	local text = table.concat(chat:render_lines(), "\n")
	contains(text, render.header("user"))
	contains(text, render.header("agent"))
	contains(text, "• Ran rg blocks")
	contains(text, "  └ lua/acp/blocks.lua")
	contains(text, icons.get("changes") .. " update")
	contains(text, "• Ran false")
	contains(text, "  └ boom")
	contains(text, "lua/acp/blocks.lua")
	eq(#chat:diagnostics(), 1)
	eq(#chat:code_blocks(), 1)
	local section_text, range = chat:section_text(code.line1)
	contains(section_text, render.header("agent"))
	contains(section_text, "Done.")
	eq(range.block_id, "agent-1")
end)

test("top-level blocks collapse terminal blank lines at boundaries", function()
	local chat = blocks.new()
	local bufnr = vim.api.nvim_create_buf(false, true)
	local function apply(operation)
		ok(operation, "expected an incremental chat operation")
		vim.api.nvim_buf_set_lines(bufnr, operation.start_row, operation.end_row, false, operation.lines)
		eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), chat:render_lines())
	end

	apply(chat:add_user("Question\n\n", {}))
	local agent_operation, agent = chat:ensure_agent("agent-spacing")
	eq(agent_operation.type, "replace")
	apply(agent_operation)
	apply(chat:append_text(agent.id, "Answer\n\n"))
	local user_operation = chat:add_user("Next question", {})
	eq(user_operation.type, "replace")
	apply(user_operation)
	eq(chat:render_lines(), {
		"",
		render.header("user"),
		"Question",
		"",
		render.header("agent"),
		"Answer",
		"",
		render.header("user"),
		"Next question",
	})

	apply(chat:append_text(agent.id, "Continuation\n\n"))
	eq(agent.text, "Answer\n\nContinuation\n\n")
	eq(chat:render_lines(), {
		"",
		render.header("user"),
		"Question",
		"",
		render.header("agent"),
		"Answer",
		"",
		"Continuation",
		"",
		render.header("user"),
		"Next question",
	})
	for index, block in ipairs(chat.blocks) do
		eq(block.lines[1], "")
		if index < #chat.blocks then
			ok(block.lines[#block.lines] ~= "", "completed cells must end before the next separator")
			eq(chat.blocks[index + 1].line1, block.line2 + 1)
		end
	end
	eq(chat.line_count, #chat:render_lines())

	local legacy = vim.deepcopy(chat)
	table.insert(legacy.blocks[1].lines, "")
	local adopted = blocks.adopt(legacy)
	ok(adopted.blocks[1].lines[#adopted.blocks[1].lines] ~= "", "adoption must normalize legacy spacing")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("live chat consumers use structural rows instead of reparsing rendered text", function()
	local chat = blocks.new()
	chat:add_user("Review `lua/acp/view.lua:12`.", {})
	chat:ensure_agent("agent-structural")
	chat:append_text("agent-structural", "Done.\n```lua\nreturn true\n```")
	chat:add_notice("warning", "Check the structural result")
	local _, action_block = chat:add_item({
		id = "command-structural",
		type = "commandExecution",
		command = "false",
		status = "completed",
		exitCode = 1,
		aggregatedOutput = "boom",
	})

	local agent = chat.by_id["agent-structural"]
	local code
	for _, child in ipairs(agent.children) do
		if child.kind == "code" then
			code = child
		end
	end
	eq(chat:row_at(agent.header_line).role, "header")
	eq(chat:row_at(code.line1).role, "code_fence")
	eq(chat:row_at(code.line1 + 1).role, "code")
	eq(chat:row_at(action_block.header_line).role, "action_header")
	eq(chat:row_at(action_block.header_line + 1).role, "action_output")

	for _, name in ipairs({
		"sections",
		"activity_groups",
		"code_blocks",
		"problem_diagnostics",
		"fold_expr",
		"fold_text",
	}) do
		ok(output[name] == nil, "rendered-text parser should not be exported: " .. name)
	end
	eq(transcript.header_kind, nil)
	eq(transcript.parse, nil)

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chat:render_lines())
	local semantic = chat:semantic_data(vim.fn.getcwd())
	eq(#semantic.sections, 4)
	eq(#semantic.activities, 1)
	eq(#semantic.code_blocks, 1)
	eq(#semantic.diagnostics, 2)
	contains(semantic.diagnostics[1].message, "structural result")
	contains(semantic.diagnostics[2].message, "Command failed: false")
	ok(#semantic.references >= 1)
	eq(semantic.code_blocks[1].block_id, "agent-structural")
	eq(chat:fold_level(agent.header_line), ">1")
	contains(chat:fold_text(agent.header_line, agent.line2), "AGENT")
	local entries = chat:entries()
	ok(#entries > 0)
	eq(entries[1].kind, "USER")
	view.refresh_transcript(bufnr, 0, chat)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("Codex-style command cells show the first and final three output lines", function()
	local chat = blocks.new()
	local _, activity_block = chat:start_item({
		id = "command-preview",
		type = "commandExecution",
		command = "printf output\necho done",
		status = "inProgress",
		commandActions = {},
	})
	eq(activity_block.lines, { "", "• Running printf output", "  │ echo done" })

	local output_lines = {}
	for index = 1, 10 do
		table.insert(output_lines, (index == 1 and "\27[31m" or "") .. "line " .. index)
	end
	local update = chat:append_command_output("command-preview", table.concat(output_lines, "\n"))
	eq(update.type, "replace")
	eq(#activity_block.lines, 3 + action.preview_limit)
	eq(activity_block.lines, {
		"",
		"• Running printf output",
		"  │ echo done",
		"  └ line 1",
		"    ... +6 lines",
		"    line 8",
		"    line 9",
		"    line 10",
	})
	ok(not table.concat(activity_block.lines, "\n"):find("K to inspect", 1, true))
	for _, line in ipairs(vim.list_slice(activity_block.lines, 4)) do
		ok(
			vim.fn.strdisplaywidth(line) <= action.command_preview_width,
			"command output rows must stay display-width bounded"
		)
	end

	local completed = chat:complete_item({
		id = "command-preview",
		type = "commandExecution",
		command = "printf output\necho done",
		status = "completed",
		exitCode = 0,
		durationMs = 420,
	})
	eq(completed.type, "replace")
	contains(activity_block.lines[2], "• Ran printf output")
	local details = chat:activity_detail_lines(activity_block.line1)
	local detail_text = table.concat(details, "\n")
	contains(detail_text, "$ printf output\necho done")
	contains(detail_text, "line 1")
	contains(detail_text, "line 10")
	contains(detail_text, "✓ • 420ms")
	eq(#activity_block.lines, 3 + action.preview_limit)
	eq(activity_block.lines[5], "    ... +6 lines")
	local activity = chat:activity_at(activity_block.line1)
	eq(activity.counts, { command = 1, tool = 0, file = 0 })
	eq(activity.presentation, "command")

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chat:render_lines())
	view.refresh_transcript(bufnr, 0, chat)
	local highlights = {}
	for _, extmark in
		ipairs(vim.api.nvim_buf_get_extmarks(bufnr, view.transcript_namespace, 0, -1, {
			details = true,
		}))
	do
		ok(not (extmark[4] and extmark[4].virt_text), "action glyphs should be literal buffer text")
		highlights[extmark[4] and extmark[4].hl_group or ""] = true
	end
	ok(highlights.AcpActionSuccess)
	ok(highlights.AcpActionOutput)
	ok(next(vim.api.nvim_get_hl(0, { name = "@acp.action.active", link = false })) ~= nil)
	ok(next(vim.api.nvim_get_hl(0, { name = "@acp.action.arguments", link = false })) ~= nil)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

local function highlighted_text(bufnr, group)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local values = {}
	for _, extmark in
		ipairs(vim.api.nvim_buf_get_extmarks(bufnr, view.transcript_namespace, 0, -1, {
			details = true,
		}))
	do
		local details = extmark[4] or {}
		if details.hl_group == group and details.end_col then
			local line = lines[extmark[2] + 1] or ""
			table.insert(values, line:sub(extmark[3] + 1, details.end_col))
		end
	end
	return values
end

local function highlight_at(bufnr, line, text, group)
	local row = line - 1
	local source = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local first = source:find(text, 1, true)
	ok(first ~= nil, ("expected line %d to contain %q"):format(line, text))
	local inspected = vim.inspect_pos(bufnr, row, first - 1, {
		extmarks = true,
		semantic_tokens = true,
		syntax = true,
		treesitter = true,
	})
	for _, extmark in ipairs(inspected.extmarks or {}) do
		local opts = extmark.opts or {}
		if opts.hl_group == group then
			return opts
		end
	end
	error(("expected %s at %q"):format(group, text), 2)
end

test("live action cells use structural Bash and semantic tool highlighting", function()
	local chat = blocks.new()
	chat:add_item({
		id = "syntax-command",
		type = "commandExecution",
		command = [[printf '%s\n' "$HOME" && rg --glob '*.lua' acp]],
		status = "completed",
		exitCode = 0,
		aggregatedOutput = "ok",
		commandActions = {},
	})
	chat:add_item({
		id = "semantic-search",
		type = "mcpToolCall",
		server = "docs",
		tool = "find_docs",
		arguments = { query = "action cells" },
		status = "completed",
		result = { content = { { type = "text", text = "found" } } },
	})
	chat:add_item({
		id = "semantic-read",
		type = "dynamicToolCall",
		namespace = "workspace",
		tool = "read_file",
		status = "completed",
		success = true,
		contentItems = { { type = "text", text = "read" } },
	})
	chat:add_item({
		id = "semantic-list",
		type = "mcpToolCall",
		server = "workspace",
		tool = "list_files",
		status = "completed",
		result = { content = { { type = "text", text = "listed" } } },
	})
	chat:add_item({
		id = "semantic-edit",
		type = "dynamicToolCall",
		namespace = "workspace",
		tool = "apply_patch",
		status = "completed",
		success = true,
		contentItems = { { type = "text", text = "edited" } },
	})
	chat:add_item({
		id = "semantic-target",
		type = "mcpToolCall",
		server = "workspace",
		tool = "target",
		status = "completed",
		result = { content = { { type = "text", text = "generic" } } },
	})
	chat:add_item({
		id = "semantic-file-change",
		type = "fileChange",
		status = "completed",
		changes = { { path = "lua/acp/view.lua", kind = { type = "update" } } },
	})

	chat:add_item({
		id = "explore-search",
		type = "commandExecution",
		command = "rg action",
		commandActions = { { type = "search", query = "action" } },
		status = "completed",
		exitCode = 0,
	})
	chat:add_item({
		id = "explore-read",
		type = "commandExecution",
		command = "sed -n 1,20p lua/acp/view.lua",
		commandActions = { { type = "read", path = "lua/acp/view.lua" } },
		status = "completed",
		exitCode = 0,
	})
	chat:add_item({
		id = "explore-list",
		type = "commandExecution",
		command = "rg --files lua/acp",
		commandActions = { { type = "listFiles", path = "lua/acp" } },
		status = "completed",
		exitCode = 0,
	})
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chat:render_lines())
	-- Simulate an existing session that still has the pre-change cyan command
	-- group. Reload-safe structural targets must not inherit this stale color.
	vim.api.nvim_set_hl(0, "AcpActionCommand", { fg = "#2ac3de" })
	view.define_highlights()
	view.refresh_transcript(bufnr, 0, chat)

	local shell_commands = highlighted_text(bufnr, "AcpShellCommand")
	ok(vim.tbl_contains(shell_commands, "printf"))
	ok(vim.tbl_contains(shell_commands, "rg"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpShellString"), "'%s\\n'"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpShellOperator"), "&&"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpShellVariable"), "HOME"))

	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionSearch"), "find_docs"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionSearch"), "Search"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionRead"), "read_file"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionRead"), "Read"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionList"), "list_files"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionList"), "List"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionText"), " action"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionText"), " lua/acp/view.lua"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionText"), " lua/acp"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionEdit"), "apply_patch"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionEdit"), "update"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionTool"), "target"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionNamespace"), "docs"))
	ok(vim.tbl_contains(highlighted_text(bufnr, "AcpActionArguments"), [[{"query":"action cells"}]]))
	local explore_block = chat.by_id["explore-search"]
	local target_highlight = highlight_at(bufnr, explore_block.line1 + 2, "action", "AcpActionText")
	eq(target_highlight.hl_group_link, "Normal")
	ok(target_highlight.priority > 90, "normal action targets must override the ACP parser capture")
	eq(vim.api.nvim_get_hl(0, { name = "AcpActionCommand" }).fg, tonumber("2ac3de", 16))

	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("Codex-style command cells use the shared first-and-final-three preview", function()
	local command_lines = {
		"printf output " .. string.rep("界", 100),
		"echo second",
		"echo third",
		"echo fourth",
		"echo fifth",
		"echo done",
	}
	local command = table.concat(command_lines, "\n")
	local chat = blocks.new()
	local _, activity_block = chat:start_item({
		id = "command-invocation-preview",
		type = "commandExecution",
		command = command,
		status = "inProgress",
		commandActions = {},
	})

	eq(#activity_block.lines, 1 + action.preview_limit)
	contains(activity_block.lines[2], "• Running printf output")
	contains(activity_block.lines[2], "...")
	eq(activity_block.lines[3], "  │ ... +2 lines")
	eq(activity_block.lines[4], "  │ echo fourth")
	eq(activity_block.lines[5], "  │ echo fifth")
	eq(activity_block.lines[6], "  │ echo done")
	ok(not table.concat(activity_block.lines, "\n"):find("K to inspect", 1, true))
	for _, line in ipairs(vim.list_slice(activity_block.lines, 2)) do
		ok(
			vim.fn.strdisplaywidth(line) <= action.command_preview_width,
			"command invocation rows must stay display-width bounded"
		)
	end

	local detail_text = table.concat(chat:activity_detail_lines(activity_block.line1), "\n")
	contains(detail_text, command)
	contains(detail_text, "echo third")

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].filetype = "acp"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chat:render_lines())
	view.define_highlights()
	view.refresh_transcript(bufnr, 0, chat)
	local active = treesitter.start(bufnr)
	if treesitter.status().available then
		ok(active, "expected the ACP highlighter to start for the preview-marker regression")
	end
	local omission_meta = highlight_at(bufnr, activity_block.line1 + 2, "... +2 lines", "AcpActionMeta")
	eq(omission_meta.hl_group_link, "Comment")
	local meta_text = highlighted_text(bufnr, "AcpActionMeta")
	ok(vim.tbl_contains(meta_text, "... +2 lines"))
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("Codex-style tools and exploration use Calling and Explored hierarchies", function()
	local chat = blocks.new()
	local _, tool_block = chat:start_item({
		id = "tool-live",
		type = "mcpToolCall",
		server = "search",
		tool = "find_docs",
		arguments = { query = "ratatui styling", limit = 3 },
		status = "inProgress",
	})
	contains(tool_block.lines[2], "• Calling search.find_docs(")
	chat:update_item_progress("tool-live", "Searching documentation")
	eq(tool_block.lines[3], "  └ Searching documentation")
	chat:complete_item({
		id = "tool-live",
		type = "mcpToolCall",
		server = "search",
		tool = "find_docs",
		arguments = { query = "ratatui styling", limit = 3 },
		status = "completed",
		result = { content = { { type = "text", text = "Found styling guidance in styles.md" } } },
	})
	contains(tool_block.lines[2], "• Called search.find_docs(")
	eq(tool_block.lines[3], "  └ Found styling guidance in styles.md")
	eq(chat:activity_at(tool_block.line1).presentation, "tool")

	local explore = blocks.new()
	local _, explore_block = explore:add_item({
		id = "search-1",
		type = "commandExecution",
		command = "rg shimmer_spans",
		commandActions = { { type = "search", command = "rg shimmer_spans", query = "shimmer_spans" } },
		status = "completed",
		exitCode = 0,
	})
	explore:add_item({
		id = "read-1",
		type = "commandExecution",
		command = "sed -n 1,80p shimmer.rs status_indicator_widget.rs",
		commandActions = {
			{ type = "read", command = "sed", name = "shimmer.rs", path = "shimmer.rs" },
			{
				type = "read",
				command = "sed",
				name = "status_indicator_widget.rs",
				path = "status_indicator_widget.rs",
			},
		},
		status = "completed",
		exitCode = 0,
	})
	eq(explore_block.lines, {
		"",
		"• Explored",
		"  └ Search shimmer_spans",
		"    Read shimmer.rs, status_indicator_widget.rs",
	})
	eq(#explore_block.children, 2)
	local detail = table.concat(explore:activity_detail_lines(explore_block.line1), "\n")
	contains(detail, "$ rg shimmer_spans")
	contains(detail, "$ sed -n 1,80p")

	local failed = blocks.new()
	local _, failed_block = failed:add_item({
		id = "tool-failed",
		type = "mcpToolCall",
		server = "search",
		tool = "find_docs",
		status = "completed",
		result = { isError = true, content = { { type = "text", text = "No index available" } } },
	})
	eq(failed_block.status, "failed")
	eq(#failed:diagnostics(), 1)
end)

test("MCP and dynamic tools keep compact transcript previews and complete details", function()
	local long_argument = string.rep("documentation query ", 12)
	local long_result = "Result 1 " .. string.rep("界", 100)
	local result_lines = { long_result }
	for index = 2, 12 do
		table.insert(result_lines, "Result " .. index)
	end
	local result_text = table.concat(result_lines, "\n")

	for _, item in ipairs({
		{
			id = "mcp-preview",
			type = "mcpToolCall",
			server = "search",
			tool = "inspect",
			arguments = { query = long_argument },
			status = "completed",
			result = { content = { { type = "text", text = result_text } } },
		},
		{
			id = "dynamic-preview",
			type = "dynamicToolCall",
			namespace = "search",
			tool = "inspect",
			arguments = { query = long_argument },
			status = "completed",
			success = true,
			contentItems = { { type = "text", text = result_text } },
		},
	}) do
		local chat = blocks.new()
		local _, tool_block = chat:add_item(item)
		eq(#tool_block.lines, 2 + action.preview_limit)
		contains(tool_block.lines[2], "search.inspect(...)")
		ok(not table.concat(tool_block.lines, "\n"):find(long_argument, 1, true))
		eq(tool_block.lines[4], "    ... +8 lines")
		eq(tool_block.lines[5], "    Result 10")
		eq(tool_block.lines[6], "    Result 11")
		eq(tool_block.lines[7], "    Result 12")
		ok(not table.concat(tool_block.lines, "\n"):find("K to inspect", 1, true))
		for _, line in ipairs(vim.list_slice(tool_block.lines, 2)) do
			ok(
				vim.fn.strdisplaywidth(line) <= action.tool_preview_width,
				"tool preview rows must stay display-width bounded"
			)
		end

		local detail_text = table.concat(chat:activity_detail_lines(tool_block.line1), "\n")
		contains(detail_text, long_argument)
		contains(detail_text, long_result)
		contains(detail_text, "Result 6")
		contains(detail_text, "Result 12")
	end
end)

test("ACP Tree-sitter grammar is distributable and keeps the acp filetype", function()
	local parser = treesitter.parser_config()
	eq(parser.location, "tree-sitter-acp")
	eq(parser.queries, "queries/acp")
	eq(parser.revision, treesitter.parser_revision())
	ok(parser.revision ~= "missing")
	for _, path in ipairs({
		"tree-sitter-acp/tree-sitter.json",
		"tree-sitter-acp/grammar.js",
		"tree-sitter-acp/src/parser.c",
		"tree-sitter-acp/src/node-types.json",
		"queries/acp/highlights.scm",
		"queries/acp/injections.scm",
	}) do
		ok(vim.fn.filereadable(vim.fs.joinpath(parser.path, path)) == 1, "missing parser artifact: " .. path)
	end
	local parser_source =
		table.concat(vim.fn.readfile(vim.fs.joinpath(parser.path, "tree-sitter-acp/src/parser.c")), "\n")
	contains(parser_source, "#define LANGUAGE_VERSION 15")
	treesitter.setup()
	eq(vim.treesitter.language.get_lang("acp"), "acp")
end)

test("Tree-sitter highlighting has no parser fallbacks", function()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].filetype = "acp"
	local original_add = vim.treesitter.language.add
	local original_start = vim.treesitter.start
	local original_stop = vim.treesitter.stop
	local checked_languages = {}
	local started_languages = {}
	local stopped = 0
	vim.treesitter.language.add = function(language)
		table.insert(checked_languages, language)
		return false, nil, "missing parser"
	end
	vim.treesitter.start = function(_, language)
		table.insert(started_languages, language)
		return true
	end
	vim.treesitter.stop = function()
		stopped = stopped + 1
	end

	local passed, err = pcall(function()
		local active, mode = treesitter.start(bufnr)
		ok(not active)
		eq(mode, "unavailable")
		eq(checked_languages, { "acp" })
		eq(started_languages, {})
		eq(stopped, 1)

		local chat = blocks.new()
		chat:add_user("Use `plain text`.", {})
		chat:add_item({
			id = "no-parser-command",
			type = "commandExecution",
			command = "printf '%s\\n' \"$HOME\" && rg action",
			status = "completed",
			exitCode = 0,
			aggregatedOutput = "done",
		})
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chat:render_lines())
		vim.api.nvim_buf_set_extmark(bufnr, view.transcript_namespace, 0, 0, {
			line_hl_group = "AcpActionCommand",
		})
		view.refresh_transcript(bufnr, 1, chat)
		eq(vim.api.nvim_buf_get_extmarks(bufnr, view.transcript_namespace, 0, -1, {}), {})
		eq(checked_languages, { "acp", "acp" })
		eq(stopped, 2)
	end)

	vim.treesitter.language.add = original_add
	vim.treesitter.start = original_start
	vim.treesitter.stop = original_stop
	vim.api.nvim_buf_delete(bufnr, { force = true })
	if not passed then
		error(err, 2)
	end
end)

test("Bash highlighting has no lexical fallback", function()
	local original_parser = vim.treesitter.get_string_parser
	vim.treesitter.get_string_parser = function()
		error("missing Bash parser")
	end
	local passed, spans = pcall(require("acp.syntax").shell_spans, [[printf '%s\n' "$HOME" && rg action]])
	vim.treesitter.get_string_parser = original_parser
	ok(passed, spans)
	eq(spans, {})
end)

test("structural adoption normalizes spacing and action rows", function()
	local restored = blocks.adopt({
		blocks = {
			{
				id = "old-command",
				kind = "activity",
				status = "completed",
				lines = { "• Ran true", "  └ (no output)" },
				children = {
					{
						id = "old-command",
						kind = "command",
						status = "completed",
						item = {
							id = "old-command",
							type = "commandExecution",
							command = "true",
							status = "completed",
							exitCode = 0,
						},
						output = "",
						relative_line1 = 1,
						relative_line2 = 2,
					},
				},
				header_offset = 1,
				metadata = { presentation = "command" },
			},
			{
				id = "old-files",
				kind = "activity",
				status = "completed",
				lines = { icons.get("changes") .. " update `lua/acp/ui.lua`" },
				children = {
					{
						id = "old-file",
						kind = "file",
						status = "completed",
						lines = { icons.get("changes") .. " update `lua/acp/ui.lua`" },
						relative_line1 = 1,
						relative_line2 = 1,
					},
				},
				header_offset = 1,
				metadata = { presentation = "files" },
			},
		},
		sequence = 2,
		revision = 0,
	})

	for _, block in ipairs(restored.blocks) do
		eq(block.lines[1], "")
		eq(block.header_offset, 2)
		eq(block.children[1].line1, block.header_line)
	end
end)

test("chat adoption drops blocks without a structural role", function()
	local chat = blocks.adopt({
		blocks = {
			{ id = "raw-text", kind = "raw", lines = { "## Codex", "unstructured" } },
			{
				id = "agent-structural",
				kind = "agent",
				text = "Preserved.",
				lines = { "", render.header("agent"), "Preserved." },
				children = {},
				header_offset = 2,
				content_offset = 3,
			},
		},
	})

	eq(#chat.blocks, 1)
	eq(chat.by_id["raw-text"], nil)
	eq(chat.by_id["agent-structural"].kind, "agent")
	eq(chat:sections()[1].kind, "AGENT")
end)

test("live chat blocks emit bounded incremental buffer operations", function()
	local chat = blocks.new()
	local spacer_rows = 3
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "", "", "", "" })
	local function apply(operation)
		vim.api.nvim_buf_set_lines(bufnr, operation.start_row, operation.end_row, false, operation.lines)
		local expected = chat:render_lines()
		for _ = 1, spacer_rows do
			table.insert(expected, "")
		end
		eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), expected)
	end

	local user_operation = chat:add_user("Build it", {})
	eq(user_operation.start_row, 0)
	eq(user_operation.end_row, 1)
	apply(user_operation)

	local agent_operation = chat:ensure_agent("agent-live")
	eq(agent_operation.start_row, #user_operation.lines)
	apply(agent_operation)
	local first_delta = chat:append_text("agent-live", "One")
	eq(first_delta.type, "replace")
	eq(first_delta.lines, { "One" })
	apply(first_delta)
	local second_delta = chat:append_text("agent-live", "\nTwo")
	eq(second_delta.lines, { "One", "Two" })
	apply(second_delta)

	local activity_operation, activity_block = chat:add_item({
		id = "command-live-1",
		type = "commandExecution",
		command = "true",
		status = "completed",
		exitCode = 0,
	})
	apply(activity_operation)
	local tool_operation, tool_block = chat:add_item({
		id = "tool-live-1",
		type = "dynamicToolCall",
		tool = "inspect",
		status = "completed",
	})
	apply(tool_operation)
	eq(tool_operation.type, "insert")
	eq(#tool_block.children, 1)
	eq(#chat:activities(), 2)
	local activity_line = activity_block.line1
	local tool_line = tool_block.line1
	local late_delta = chat:append_text("agent-live", "\nThree")
	apply(late_delta)
	eq(activity_block.line1, activity_line + 1)
	eq(tool_block.line1, tool_line + 1)
	eq(activity_block.children[1].line1, activity_block.header_line)
	eq(tool_block.children[1].line1, tool_block.header_line)
	eq(chat.line_count, #chat:render_lines())
	eq(vim.api.nvim_buf_get_lines(bufnr, chat.line_count, -1, false), { "", "", "" })
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("large block transcripts keep lookup and streaming edits bounded", function()
	local thread = { turns = {} }
	for turn = 1, 250 do
		local response = {}
		for line = 1, 14 do
			response[line] = ("response %d line %d"):format(turn, line)
		end
		thread.turns[turn] = {
			items = {
				{
					id = "user-" .. turn,
					type = "userMessage",
					content = { { type = "text", text = "prompt " .. turn } },
				},
				{
					id = "command-" .. turn,
					type = "commandExecution",
					command = "true",
					status = "completed",
					exitCode = 0,
				},
				{
					id = "agent-" .. turn,
					type = "agentMessage",
					text = table.concat(response, "\n"),
				},
			},
		}
	end

	local started = vim.uv.hrtime()
	local chat = blocks.from_thread(thread)
	eq(chat.line_count, 5500)
	for line = 1, chat.line_count, 5 do
		ok(chat:block_at(line))
	end
	local elapsed_ms = (vim.uv.hrtime() - started) / 1000000
	ok(elapsed_ms < 1000, ("expected 5,500-line block indexing under 1s, got %.2fms"):format(elapsed_ms))
	local semantic = chat:semantic_data(vim.fn.getcwd())
	ok(chat:semantic_data(vim.fn.getcwd()) == semantic, "expected model-wide semantics to reuse the current revision")

	local operation = chat:append_text("agent-250", "\nfinal streamed line")
	eq(operation.type, "replace")
	eq(operation.start_row, 5499)
	eq(operation.end_row, 5500)
	eq(#operation.lines, 2)
	eq(chat.line_count, 5501)
	ok(chat:semantic_data(vim.fn.getcwd()) ~= semantic, "expected a streamed edit to invalidate model-wide semantics")
end)

test("chat view stacks floating surfaces and styles transcript roles", function()
	local stack = view.stack_geometry({ row = 1, col = 31, width = 89, height = 30 }, { status = "ready" }, {
		input_height = 6,
		input_padding = 2,
		instruction_height = 4,
	})
	eq({
		outer_width = stack.outer_width,
		bottom_padding = stack.bottom_padding,
		chat = stack.chat,
		turn = stack.turn,
		prompt = stack.prompt,
	}, {
		outer_width = 89,
		bottom_padding = 2,
		chat = { row = 1, col = 31, width = 89, height = 20 },
		turn = { row = 21, col = 32, width = 87, height = 2 },
		prompt = { row = 23, col = 31, width = 87, height = 4, outer_height = 6 },
	})
	eq(#stack.turn_lines, 2)
	eq(stack.turn_lines[1], string.rep(" ", 87))
	contains(stack.turn_lines[2], icons.get("idle") .. " ready")
	eq(vim.fn.strdisplaywidth(stack.turn_lines[2]), 87)
	local instruction_block = view.instruction_block({
		status = "responding",
		busy = true,
		pending_instructions = {
			{ id = "steer-1", kind = "steer", text = "Keep the public API unchanged" },
			{ id = "queue-1", kind = "queued", text = "Run the tests afterward" },
		},
	}, 52, 4)
	eq(#instruction_block.lines, 4)
	eq(instruction_block.lines[1], string.rep(" ", 52))
	contains(instruction_block.lines[2], icons.get("send") .. " steer")
	contains(instruction_block.lines[2], "Keep the public API unchanged")
	contains(instruction_block.lines[3], icons.get("history") .. " queued")
	contains(instruction_block.lines[4], icons.spinner(1) .. " responding")
	for _, line in ipairs(instruction_block.lines) do
		eq(vim.fn.strdisplaywidth(line), 52)
	end
	local prompt_title = chunks_text(view.prompt_title({
		pending_instructions = {
			{ kind = "steer", text = "Keep the public API unchanged" },
			{ kind = "queued", text = "Run the tests afterward" },
		},
	}))
	ok(not prompt_title:find("steer", 1, true))
	ok(not prompt_title:find("queued", 1, true))
	local prompt_footer = chunks_text(view.prompt_footer({
		model = "gpt-5.6",
		effort = "high",
		tokens = { totalTokens = 50000, modelContextWindow = 1050000 },
		contexts = { { type = "file" } },
	}, 83))
	eq(vim.fn.strdisplaywidth(prompt_footer), 83)
	ok(not prompt_footer:find("Prompt", 1, true))
	contains(prompt_footer, "gpt-5.6 · high")
	contains(prompt_footer, "ctx 95% · 1.1m")
	contains(prompt_footer, "+1 context")
	contains(prompt_footer, "<C-s> steer")
	contains(prompt_footer, "<C-CR> send")
	ok(
		prompt_footer:find("gpt-5.6 · high", 1, true) < prompt_footer:find("ctx 95% · 1.1m", 1, true),
		"expected model and effort before remaining context"
	)
	ok(
		prompt_footer:find("ctx 95% · 1.1m", 1, true) < prompt_footer:find("<C-s> steer", 1, true),
		"expected remaining context before the lower-right key hints"
	)
	local narrow_footer = chunks_text(view.prompt_footer({ model = "gpt-5.6", effort = "high" }, 20))
	eq(vim.fn.strdisplaywidth(narrow_footer), 20)
	contains(narrow_footer, "gpt-5.6 · high")
	ok(not narrow_footer:find("Prompt", 1, true))
	contains(
		chunks_text(view.prompt_title({ tokens = { totalTokens = 1200, modelContextWindow = 1000 } })),
		"ctx 0% · 1k"
	)
	contains(
		chunks_text(view.prompt_title({
			tokens = { totalTokens = 177080, modelContextWindow = 258400 },
		})),
		"ctx 31% · 258.4k"
	)
	local idle_block = view.instruction_block({ status = "ready" }, 28, 4)
	eq(#idle_block.lines, 2)
	eq(idle_block.lines[1], string.rep(" ", 28))
	contains(idle_block.lines[2], icons.get("idle") .. " ready")
	eq(vim.fn.strdisplaywidth(idle_block.lines[2]), 28)
	local default_height_block = view.instruction_block({
		status = "running command",
		busy = true,
		pending_instructions = {
			{ id = "queue-default", kind = "queued", text = "Run the tests" },
		},
	}, 28)
	eq(#default_height_block.lines, 3)
	eq(default_height_block.lines[1], string.rep(" ", 28))
	contains(default_height_block.lines[2], icons.get("history") .. " queued")
	contains(default_height_block.lines[3], icons.spinner(1) .. " running command")
	local clipped_instructions = view.instruction_block({
		status = "running",
		busy = true,
		pending_instructions = {
			{ id = "queue-1", kind = "queued", text = "first" },
			{ id = "queue-2", kind = "queued", text = "second" },
			{ id = "queue-3", kind = "queued", text = "third" },
		},
	}, 28, 3)
	eq(#clipped_instructions.lines, 3)
	eq(clipped_instructions.lines[1], string.rep(" ", 28))
	contains(clipped_instructions.lines[2], "+3 pending instructions")
	contains(clipped_instructions.lines[3], icons.spinner(1) .. " running")
	eq(vim.fn.strdisplaywidth(clipped_instructions.lines[2]), 28)
	eq(vim.fn.strdisplaywidth(clipped_instructions.lines[3]), 28)

	local styled_chat = blocks.new()
	styled_chat:add_user("Use `turn/steer`.", {})
	styled_chat:ensure_agent("styled-agent")
	styled_chat:append_text("styled-agent", "Done with `inline` syntax.\n```lua\nreturn true\n```")
	styled_chat:add_item({
		id = "styled-command",
		type = "commandExecution",
		command = "nvim --headless",
		status = "completed",
		exitCode = 0,
		aggregatedOutput = "ok",
	})
	styled_chat:add_item({
		id = "styled-tool",
		type = "mcpToolCall",
		server = "mcp",
		tool = "read",
		status = "completed",
		result = { content = { { type = "text", text = "done" } } },
	})
	styled_chat:add_item({
		id = "styled-file",
		type = "fileChange",
		status = "completed",
		changes = { { path = "lua/acp/view.lua", kind = { type = "update" } } },
	})
	styled_chat:add_notice("warning", "Check this result")
	styled_chat:add_notice("error", "Failed to apply change")
	styled_chat:ensure_plan("styled-plan")
	styled_chat:append_text("styled-plan", "Verify the result.")

	local bufnr = vim.api.nvim_create_buf(false, true)
	local direct_lines = styled_chat:render_lines()
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, direct_lines)
	view.define_highlights()
	view.refresh_transcript(bufnr, 0, styled_chat)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, view.transcript_namespace, 0, -1, { details = true })
	local groups = {}
	for _, extmark in ipairs(marks) do
		local details = extmark[4] or {}
		if details.hl_group then
			groups[details.hl_group] = true
		end
		ok(not details.sign_text, "chat icons should be buffer text, not signs")
		ok(details.conceal == nil, "direct transcript icons should not need conceal extmarks")
	end
	ok(groups.AcpUserHeader)
	ok(groups.AcpAgentHeader)
	ok(groups.AcpActionSuccess)
	ok(groups.AcpActionText)
	ok(groups.AcpShellCommand)
	ok(groups.AcpActionTool)
	ok(groups.AcpTranscriptTool)
	ok(groups.AcpTranscriptWarning)
	ok(groups.AcpTranscriptError)
	ok(groups.AcpSectionHeader)
	ok(groups.AcpCodeFence)
	ok(groups.AcpInlineCode)
	for _, capture in ipairs({
		"@acp.action.active",
		"@acp.action.success",
		"@acp.action.namespace",
		"@acp.action.tool",
		"@acp.action.text",
		"@acp.action.arguments",
		"@acp.action.verb",
		"@acp.action.failure",
	}) do
		ok(next(vim.api.nvim_get_hl(0, { name = capture, link = false })) ~= nil, "missing highlight: " .. capture)
	end
	local styled_text = table.concat(direct_lines, "\n")
	for _, name in ipairs({ "user", "agent", "changes", "warning", "error", "section" }) do
		contains(styled_text, icons.get(name))
	end
	local evaluated = vim.api.nvim_eval_statusline(
		view.chat_winbar({
			status = "running command",
			busy = true,
			tokens = { totalTokens = 42000, modelContextWindow = 272000 },
		}),
		{ maxwidth = 49 }
	)
	contains(evaluated.str, icons.get("agent") .. " Codex")
	ok(not evaluated.str:find("running command", 1, true), "turn status should live in the attached panel")
	local previous_have_nerd_font = vim.g.have_nerd_font
	vim.g.have_nerd_font = false
	eq(icons.get("user"), "U")
	eq(icons.get("code"), "{}")
	eq(icons.get("send"), ">")
	eq(icons.get("history"), "+")
	eq(transcript.header("user"), "U You")
	eq(transcript.line("warning", "Warning: check"), "! Warning: check")
	vim.g.have_nerd_font = previous_have_nerd_font
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("output projections consume structural semantics", function()
	local chat = blocks.new()
	chat:add_user("Review `lua/acp/view.lua:1`.", {})
	chat:ensure_agent("projection-agent")
	chat:append_text("projection-agent", "Done.\n```lua\nreturn true\n```")
	chat:add_item({
		id = "projection-command",
		type = "commandExecution",
		command = "false",
		status = "completed",
		exitCode = 1,
		aggregatedOutput = "boom",
	})
	chat:add_notice("warning", "Inspect the failure")

	local semantic = chat:semantic_data(vim.fn.getcwd())
	eq(#semantic.sections, 4)
	eq(#semantic.activities, 1)
	eq(#semantic.code_blocks, 1)
	eq(#semantic.references, 1)
	eq(#semantic.diagnostics, 2)
	eq(output.code_block_text(semantic.code_blocks[1]), "return true")
	contains(chat:fold_text(chat.by_id["projection-command"].header_line), "ACTIVITY")

	local items = output.output_items({
		total_lines = semantic.total_lines,
		references = semantic.references,
		blocks = semantic.code_blocks,
		diagnostics = semantic.diagnostics,
		activities = semantic.activities,
	})
	eq(#items, 5)
	local entries = output.output_map_entries({
		total_lines = semantic.total_lines,
		sections = semantic.sections,
		items = items,
	})
	eq(#entries, #semantic.sections + #items)
	local map_lines, rows = output.output_map_lines(entries, {
		total_lines = semantic.total_lines,
		current_line = chat.by_id["projection-agent"].header_line,
	})
	ok(#map_lines > #entries)
	ok(vim.tbl_count(rows) > 0)
end)

test("output UI restores semantic visuals and section drafting", function()
	local output_buf = vim.api.nvim_create_buf(false, true)
	local input_buf = vim.api.nvim_create_buf(false, true)
	local chat = blocks.new()
	local _, user_block = chat:add_user("Review `lua/acp/view.lua:1`.", {}, { id = "output-ui-user" })
	chat:ensure_agent("output-ui-agent")
	chat:append_text("output-ui-agent", "```lua\nreturn true\n```")
	chat:add_notice("warning", "Inspect this")
	local lines = chat:render_lines()
	vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, lines)
	local output_win = vim.api.nvim_open_win(output_buf, false, {
		relative = "editor",
		row = 0,
		col = 0,
		width = 40,
		height = 5,
		style = "minimal",
	})
	local reference_line = user_block.header_line + 1
	vim.api.nvim_win_set_cursor(output_win, { reference_line, lines[reference_line]:find("lua", 1, true) - 1 })
	local state = {
		cwd = vim.fn.getcwd(),
		output_buf = output_buf,
		output_win = output_win,
		input_buf = input_buf,
		chat = chat,
	}

	output_ui.refresh(state)
	eq(state.output_cache.changedtick, vim.api.nvim_buf_get_changedtick(output_buf))
	local current_cache = state.output_cache
	output_ui.refresh(state)
	ok(state.output_cache == current_cache, "an unchanged transcript should reuse its semantic and visual cache")
	local visual_marks = vim.api.nvim_buf_get_extmarks(output_buf, output_ui.namespaces.visual, 0, -1, {
		details = true,
	})
	ok(#visual_marks > 0)
	local reference_highlighted = false
	for _, extmark in ipairs(visual_marks) do
		local details = extmark[4] or {}
		ok(not details.virt_text, "semantic icons and code languages should not be virtual text")
		if details.hl_group == "AcpOutputReference" then
			reference_highlighted = true
		end
		ok(not details.sign_text, "transcript references should not add sign icons")
		if details.virt_text_pos == "right_align" then
			for _, chunk in ipairs(details.virt_text or {}) do
				ok(not tostring(chunk[1]):find("REF", 1, true), "transcript references should not add REF badges")
			end
		end
	end
	ok(reference_highlighted, "transcript references should remain highlighted")
	local current_marks = vim.api.nvim_buf_get_extmarks(output_buf, output_ui.namespaces.current, 0, -1, {
		details = true,
	})
	ok(#current_marks > 0, "the current reference should remain highlighted")
	for _, extmark in ipairs(current_marks) do
		ok(not (extmark[4] or {}).virt_text, "cursor highlights should not add virtual text")
	end
	eq(#vim.diagnostic.get(output_buf), 0)
	ok(output_ui.yank_section(state))
	contains(vim.fn.getreg('"'), "Review")
	ok(output_ui.draft_section(state))
	contains(table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"), "follow-up context")

	output_ui.close(state)
	vim.api.nvim_win_close(output_win, true)
	vim.api.nvim_buf_delete(output_buf, { force = true })
	vim.api.nvim_buf_delete(input_buf, { force = true })
end)

test("approval requests return Codex decision payloads", function()
	local captured
	with_permission_select(function(params, callback)
		captured = params
		callback(params.options[2])
	end, function()
		local response
		ok(approval.handle("item/commandExecution/requestApproval", {
			command = "git status",
			cwd = "/tmp/project",
			reason = "Inspect the worktree",
			availableDecisions = { "accept", "acceptForSession", "decline", "cancel" },
		}, function(result)
			response = result
		end))
		eq(captured.toolCall.title, "git status")
		eq(response, { decision = "acceptForSession" })
	end)
end)

test("file approvals show the affected files", function()
	with_permission_select(function(params, callback)
		local text = table.concat(permission.lines(params), "\n")
		contains(text, "Apply changes to 2 file(s)")
		contains(text, "lua/acp/ui.lua")
		contains(text, "lua/acp/codex.lua")
		callback(params.options[1])
	end, function()
		local response
		approval.handle("item/fileChange/requestApproval", {
			reason = "Apply the proposed patch",
			item = {
				changes = {
					{ path = "lua/acp/ui.lua" },
					{ path = "lua/acp/codex.lua" },
				},
			},
		}, function(result)
			response = result
		end)
		eq(response, { decision = "accept" })
	end)
end)

test("server input requests use native Neovim selectors", function()
	local original_select = vim.ui.select
	local original_input = vim.ui.input
	vim.ui.select = function(items, _, callback)
		callback(items[2])
	end
	vim.ui.input = function(_, callback)
		callback("free form")
	end
	local response
	local passed, err = pcall(function()
		ok(requests.handle("item/tool/requestUserInput", {
			questions = {
				{
					id = "choice",
					header = "Approach",
					question = "Which approach?",
					options = { { label = "A" }, { label = "B" } },
				},
				{ id = "note", header = "Note", question = "Anything else?" },
			},
		}, function(result)
			response = result
		end))
	end)
	vim.ui.select = original_select
	vim.ui.input = original_input
	if not passed then
		error(err, 2)
	end
	eq(response.answers.choice.answers, { "B" })
	eq(response.answers.note.answers, { "free form" })
end)

test("permission profile requests can grant the turn", function()
	with_permission_select(function(params, callback)
		callback(params.options[1])
	end, function()
		local response
		ok(requests.handle("item/permissions/requestApproval", {
			cwd = "/tmp/project",
			reason = "Needs network access",
			permissions = { network = { enabled = true } },
		}, function(result)
			response = result
		end))
		eq(response.scope, "turn")
		eq(response.permissions.network.enabled, true)
	end)
end)

test("permission UI is Codex-specific and self-contained", function()
	local lines = permission.lines({
		toolCall = { title = "Run tests", kind = "command", location = "/tmp/project" },
		options = { { optionId = "accept", name = "Allow once" } },
	})
	local text = table.concat(lines, "\n")
	contains(text, "Codex permission request")
	contains(text, "Run tests")
	contains(text, "Allow once")
	contains(text, "1-9 to choose")
end)

test("closing a permission buffer cancels the request", function()
	local selected = "pending"
	local bufnr = permission.select({
		toolCall = { title = "Run tests" },
		options = { { optionId = "accept", name = "Allow once" } },
	}, function(option)
		selected = option
	end)
	vim.api.nvim_buf_delete(bufnr, { force = true })
	eq(selected, nil)
end)

test("setup exposes only the focused Codex command surface", function()
	ui.setup({ command = { "codex", "app-server" } })
	for _, command in ipairs({
		"AcpChat",
		"AcpNew",
		"AcpThreads",
		"AcpSessions",
		"AcpAddContext",
		"AcpAddFile",
		"AcpModel",
		"AcpReasoning",
		"AcpReview",
		"AcpDiff",
		"AcpActions",
		"AcpLogin",
		"AcpInstallParser",
		"AcpSend",
		"AcpStop",
		"AcpClose",
		"AcpReload",
	}) do
		eq(vim.fn.exists(":" .. command), 2)
	end
	eq(vim.fn.exists(":AcpChatWindow"), 0)
	eq(ui.get_config().command, { "codex", "app-server" })
end)

test("Blink registers ACP plus configured buffer and path completion", function()
	local blink_root = vim.env.ACP_BLINK_CMP_PATH or vim.fn.expand("~/.local/share/nvim/lazy/blink.cmp")
	if vim.fn.isdirectory(blink_root) ~= 1 then
		return
	end
	vim.opt.runtimepath:prepend(blink_root)
	local cmp = require("blink.cmp")
	cmp.setup({
		fuzzy = { implementation = "lua" },
		sources = { default = { "buffer", "path" } },
	})
	completion.reset()
	ok(completion.setup())
	local config = require("blink.cmp.config")
	eq(config.sources.providers.acp.module, "acp.completion.source")
	eq(config.sources.providers.acp.name, "Codex")
	eq(completion.sources(), { "acp", "buffer", "path" })
	local sources = require("blink.cmp.sources.lib")
	local prompt_sources = sources.per_filetype_provider_ids["acp-prompt"]
	for _, source in ipairs({ "acp", "buffer", "path" }) do
		ok(vim.tbl_contains(prompt_sources, source), "missing Blink source: " .. source)
	end

	local source_buf = vim.api.nvim_create_buf(false, false)
	vim.bo[source_buf].buflisted = true
	vim.bo[source_buf].swapfile = false
	vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "workspaceBufferTerm" })
	local prompt_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[prompt_buf].filetype = "acp-prompt"
	vim.b[prompt_buf].acp_cwd = "/tmp/acp-workspace"
	vim.api.nvim_win_set_buf(0, prompt_buf)
	eq(config.sources.providers.path.opts.get_cwd({ bufnr = prompt_buf }), "/tmp/acp-workspace")
	ok(config.sources.providers.path.should_show_items(completion_context("src/", prompt_buf), {}))
	ok(not config.sources.providers.path.should_show_items(completion_context("/", prompt_buf), {}))
	ok(vim.tbl_contains(config.sources.providers.buffer.opts.get_bufnrs(), source_buf))

	local live = sources.get_provider_by_id("acp")
	local old_module = live.module
	package.loaded["acp.completion.source"] = nil
	completion.reload()
	ok(live.module ~= old_module, "hot reload must replace Blink's instantiated ACP source")
	eq(live.list, nil)

	vim.api.nvim_buf_delete(prompt_buf, { force = true })
	vim.api.nvim_buf_delete(source_buf, { force = true })
end)

test("Codex chat uses a dedicated tab and preserves the source layout", function()
	ui._reset()
	ui.setup({ auto_context = false, command = { "missing-codex" } })
	local fake = { stopped = false }
	function fake:set_handlers(handlers)
		self.handlers = handlers
	end
	function fake:list_threads(_, callback)
		callback({})
	end
	function fake:stop()
		self.stopped = true
	end
	ui._set_client(fake)
	vim.cmd("enew!")
	local origin_tab = vim.api.nvim_get_current_tabpage()
	local origin_win = vim.api.nvim_get_current_win()
	local origin_windows = vim.api.nvim_tabpage_list_wins(origin_tab)
	local tab_count = #vim.api.nvim_list_tabpages()

	local passed, err = pcall(function()
		ui.open()
		local state = ui._state()
		local chat_tab = vim.api.nvim_get_current_tabpage()
		ok(chat_tab ~= origin_tab)
		eq(state.tabpage, chat_tab)
		eq(#vim.api.nvim_list_tabpages(), tab_count + 1)
		eq(vim.api.nvim_tabpage_list_wins(origin_tab), origin_windows)
		eq(#vim.api.nvim_tabpage_list_wins(chat_tab), 5)
		eq(vim.bo[state.sessions_buf].filetype, "acp-sessions")
		eq(vim.bo[state.output_host_buf].filetype, "acp-host")
		eq(vim.bo[state.output_buf].filetype, "acp")
		eq(vim.b[state.output_buf].acp_language_injection, "treesitter-acp")
		eq(vim.bo[state.input_buf].filetype, "acp-prompt")
		eq(vim.b[state.input_buf].completion, true)
		eq(vim.b[state.input_buf].acp_cwd, state.cwd)
		local input_keymaps = {}
		for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(state.input_buf, "i")) do
			input_keymaps[keymap.lhs] = keymap.desc
		end
		eq(input_keymaps["/"], "Open Codex completion")
		eq(input_keymaps["$"], "Open Codex completion")
		eq(input_keymaps["@"], "Open Codex completion")
		eq(vim.bo[state.sessions_buf].undolevels, -1)
		eq(vim.bo[state.output_host_buf].undolevels, -1)
		eq(vim.bo[state.output_buf].undolevels, -1)
		eq(vim.wo[state.output_win].foldmethod, "expr")
		eq(vim.wo[state.output_win].foldexpr, "v:lua.acp_nvim_output_foldexpr()")
		eq(vim.wo[state.output_win].foldlevel, 2)
		eq(vim.wo[state.output_win].foldcolumn, "0")
		eq(vim.wo[state.output_win].signcolumn, "no")
		eq(vim.wo[state.output_win].statuscolumn, "  ")
		eq(vim.wo[state.output_win].breakindent, false)
		eq(vim.wo[state.output_win].showbreak, "")
		eq(vim.b[state.output_buf].indent_guide, false)
		local output_keymaps = {}
		for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(state.output_buf, "n")) do
			output_keymaps[keymap.desc] = true
		end
		for _, description in ipairs({
			"Next Codex output section",
			"Previous Codex output item",
			"Inspect Codex output item",
			"Search Codex output",
			"Open Codex output map",
			"Yank Codex code block",
		}) do
			ok(output_keymaps[description], "missing output keymap: " .. description)
		end
		ok(
			not output_keymaps["Center active Codex response or redraw"],
			"legacy output centering keymap must be removed"
		)
		eq(vim.fn.exists(":AcpOutputMap"), 2)
		eq(vim.fn.exists(":AcpOutputItemsQuickfix"), 2)
		eq(vim.fn.exists(":AcpCodeBlockDraft"), 2)
		ok(output_ui.open_map(state))
		ok(vim.api.nvim_win_is_valid(state.output_map_win))
		eq(vim.api.nvim_win_get_config(state.output_map_win).relative, "win")
		contains(table.concat(vim.api.nvim_buf_get_lines(state.output_map_buf, 0, -1, false), "\n"), "Output Map")
		output_ui.close(state)
		eq(vim.fn.winlayout(), {
			"row",
			{
				{ "leaf", state.sessions_win },
				{ "leaf", state.output_host_win },
			},
		})
		local chat_float = vim.api.nvim_win_get_config(state.output_win)
		local prompt = vim.api.nvim_win_get_config(state.input_win)
		local turn_panel = vim.api.nvim_win_get_config(state.instruction_win)
		eq(chat_float.relative, "win")
		eq(chat_float.win, state.output_host_win)
		eq(chat_float.zindex, 49)
		eq(chat_float.row, 0)
		eq(chat_float.col, 0)
		eq(chat_float.border, "none")
		eq(prompt.relative, "win")
		eq(prompt.win, state.output_host_win)
		eq(prompt.zindex, 50)
		ok(not chunks_text(prompt.title):find("Prompt", 1, true))
		local prompt_footer = chunks_text(prompt.footer)
		ok(not prompt_footer:find("Prompt", 1, true))
		contains(prompt_footer, "<C-s> steer")
		contains(prompt_footer, "<C-CR> send")
		eq(prompt.footer_pos, "left")
		eq(vim.fn.strdisplaywidth(prompt_footer), prompt.width)
		eq(turn_panel.relative, "win")
		eq(turn_panel.win, state.output_host_win)
		eq(turn_panel.focusable, false)
		eq(turn_panel.col, 1)
		eq(turn_panel.width, prompt.width)
		eq(chat_float.width, prompt.width + 2)
		eq(chat_float.row + chat_float.height, turn_panel.row)
		eq(turn_panel.row + turn_panel.height, prompt.row)
		eq(
			prompt.row + prompt.height + 2 + ui.get_config().window.input_padding,
			vim.api.nvim_win_get_height(state.output_host_win)
		)
		eq(turn_panel.border, "none")
		eq(turn_panel.height, 2)
		contains(table.concat(vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false), "\n"), "new chat")
		vim.cmd("redraw")
		local output_info = vim.fn.getwininfo(state.output_win)[1]
		eq(output_info.textoff, 2)
		eq(prompt.width + 2, vim.api.nvim_win_get_width(state.output_win))
		eq(vim.api.nvim_win_get_width(state.output_win), vim.api.nvim_win_get_width(state.output_host_win))
		eq(vim.wo[state.output_win].scrolloff, 0)
		eq(vim.wo[state.output_win].fillchars, "eob: ")
		eq(vim.wo[state.input_win].fillchars, "eob: ")
		ok(not vim.wo[state.output_win].winhighlight:find("FloatBorder", 1, true))
		contains(vim.wo[state.input_win].winhighlight, "AcpPromptBorder")
		eq(vim.api.nvim_win_get_position(state.sessions_win)[2], 0)
		eq(vim.api.nvim_win_get_tabpage(state.output_win), chat_tab)
		eq(vim.api.nvim_win_get_tabpage(state.output_host_win), chat_tab)
		eq(vim.api.nvim_win_get_tabpage(state.input_win), chat_tab)
		eq(vim.api.nvim_win_get_tabpage(state.sessions_win), chat_tab)

		local closed_prompt = state.input_win
		local attached_turn = state.instruction_win
		vim.api.nvim_win_close(closed_prompt, true)
		ok(
			vim.wait(100, function()
				return not vim.api.nvim_win_is_valid(attached_turn)
			end),
			"closing the composer prompt should close its sibling turn panel"
		)
		ui.open()
		state = ui._state()
		ok(state.input_win ~= closed_prompt)
		ok(state.instruction_win ~= attached_turn)
		ok(vim.api.nvim_win_is_valid(state.instruction_win))
		eq(vim.api.nvim_get_current_tabpage(), chat_tab)
		eq(state.tabpage, chat_tab)
		eq(#vim.api.nvim_list_tabpages(), tab_count + 1)
		eq(#vim.api.nvim_tabpage_list_wins(chat_tab), 5)
		eq(vim.api.nvim_win_get_config(state.input_win).relative, "win")
		eq(vim.api.nvim_tabpage_list_wins(origin_tab), origin_windows)

		vim.api.nvim_win_close(state.sessions_win, true)
		vim.cmd("AcpSessions")
		state = ui._state()
		eq(#vim.api.nvim_tabpage_list_wins(chat_tab), 5)
		eq(vim.api.nvim_get_current_win(), state.sessions_win)
		eq(vim.api.nvim_win_get_position(state.sessions_win)[2], 0)
		eq(vim.api.nvim_win_get_config(state.input_win).relative, "win")

		local old_prompt_width = vim.api.nvim_win_get_config(state.input_win).width
		vim.api.nvim_win_set_width(state.sessions_win, 20)
		vim.api.nvim_exec_autocmds("WinResized", {})
		ok(
			vim.wait(100, function()
				return vim.api.nvim_win_get_config(state.input_win).width > old_prompt_width
			end),
			"expected the floating prompt to follow chat-window resizing"
		)
		local resized_prompt = vim.api.nvim_win_get_config(state.input_win)
		local resized_turn = vim.api.nvim_win_get_config(state.instruction_win)
		local resized_chat = vim.api.nvim_win_get_config(state.output_win)
		eq(resized_turn.win, state.output_host_win)
		eq(resized_turn.width, resized_prompt.width)
		eq(resized_chat.width, resized_prompt.width + 2)
		eq(resized_chat.row + resized_chat.height, resized_turn.row)
		eq(resized_turn.row + resized_turn.height, resized_prompt.row)

		local chat_windows = vim.api.nvim_tabpage_list_wins(chat_tab)
		state.thread_id = "thread-1"
		state.diff = "--- a/file\n+++ b/file"
		ui.open_diff()
		local diff_tab = vim.api.nvim_get_current_tabpage()
		ok(diff_tab ~= chat_tab)
		eq(#vim.api.nvim_list_tabpages(), tab_count + 2)
		eq(vim.api.nvim_tabpage_list_wins(origin_tab), origin_windows)
		eq(vim.api.nvim_tabpage_list_wins(chat_tab), chat_windows)
		vim.cmd("tabclose!")
		eq(vim.api.nvim_get_current_tabpage(), chat_tab)

		ui.close()
		eq(vim.api.nvim_get_current_tabpage(), origin_tab)
		eq(vim.api.nvim_get_current_win(), origin_win)
		eq(#vim.api.nvim_list_tabpages(), tab_count)
		eq(vim.api.nvim_tabpage_list_wins(origin_tab), origin_windows)
	end)
	ui._reset()
	eq(fake.stopped, true)
	if not passed then
		error(err, 2)
	end
end)

test("sessions split lists and resumes Codex threads", function()
	ui._reset()
	ui.setup({ auto_context = false, command = { "missing-codex" } })
	local fake = {
		threads = {
			{ id = "thread-a", preview = "First session", cwd = "/tmp/project" },
			{ id = "thread-b", preview = "Second session", cwd = "/tmp/project" },
		},
	}

	function fake:set_handlers(handlers)
		self.handlers = handlers
	end

	function fake:list_threads(opts, callback)
		self.list_opts = opts
		callback(vim.deepcopy(self.threads))
	end

	function fake:resume_thread(thread_id, opts, callback)
		self.resumed = { thread_id = thread_id, opts = opts }
		callback({
			thread = {
				id = thread_id,
				cwd = opts.cwd,
				turns = {
					{
						items = {
							{
								id = "restored-user",
								type = "userMessage",
								content = { { type = "text", text = "Restore the blocks" } },
							},
							{
								id = "restored-command",
								type = "commandExecution",
								command = "true",
								status = "completed",
								exitCode = 0,
							},
							{
								id = "restored-tool",
								type = "dynamicToolCall",
								tool = "inspect",
								status = "completed",
							},
							{
								id = "restored-agent",
								type = "agentMessage",
								text = "Restored.\n```lua\nreturn true\n```",
							},
						},
					},
				},
			},
			cwd = opts.cwd,
		})
	end

	function fake:stop() end

	ui._set_client(fake)
	local passed, err = pcall(function()
		ui.open()
		local state = ui._state()
		eq(fake.list_opts.cwd, vim.fs.normalize(vim.fn.getcwd()))
		eq(fake.list_opts.source_kinds, { "cli", "vscode", "appServer" })
		eq(vim.api.nvim_buf_get_lines(state.sessions_buf, 0, -1, false), {
			"* New chat",
			"  First session",
			"  Second session",
		})

		vim.api.nvim_set_current_win(state.sessions_win)
		vim.api.nvim_win_set_cursor(state.sessions_win, { 1, 0 })
		ui.select_session()
		eq(fake.resumed, nil)
		eq(vim.api.nvim_get_current_win(), state.input_win)

		vim.api.nvim_set_current_win(state.sessions_win)
		vim.api.nvim_win_set_cursor(state.sessions_win, { 3, 0 })
		ui.select_session()

		eq(fake.resumed.thread_id, "thread-b")
		eq(state.thread_id, "thread-b")
		eq(vim.api.nvim_get_current_win(), state.input_win)
		eq(
			vim.tbl_map(function(block)
				return block.kind
			end, state.chat.blocks),
			{ "user", "activity", "activity", "agent" }
		)
		eq(#state.chat:activities(), 2)
		eq(state.chat:code_block_at(state.chat.by_id["restored-agent"].line2 - 1).language, "lua")
		local lines = vim.api.nvim_buf_get_lines(state.sessions_buf, 0, -1, false)
		eq(lines, { "* Second session", "  First session" })

		fake.threads = { fake.threads[1] }
		vim.cmd("AcpSessions")
		lines = vim.api.nvim_buf_get_lines(state.sessions_buf, 0, -1, false)
		eq(lines, { "* Second session", "  First session" })
	end)
	ui._reset()
	if not passed then
		error(err, 2)
	end
end)

test("clear slash command resets the chat locally and preserves busy input", function()
	ui._reset()
	ui.setup({ auto_context = false, command = { "missing-codex" } })
	local fake = { starts = 0, turns = {}, unsubscribed = {} }

	function fake:set_handlers(handlers)
		self.handlers = handlers
	end

	function fake:list_threads(_, callback)
		callback({})
	end

	function fake:start_thread(opts, callback)
		self.starts = self.starts + 1
		local id = "clear-thread-" .. self.starts
		callback({
			thread = { id = id, cwd = opts.cwd, turns = {} },
			cwd = opts.cwd,
		})
	end

	function fake:start_turn(thread_id, payload, callback)
		table.insert(self.turns, { thread_id = thread_id, payload = payload })
		callback({ turn = { id = "clear-turn-1", status = "inProgress" } })
	end

	function fake:unsubscribe_thread(thread_id, callback)
		table.insert(self.unsubscribed, thread_id)
		callback({})
	end

	function fake:set_thread_name(thread_id, name, callback)
		self.named = { thread_id = thread_id, name = name }
		callback({})
	end

	function fake:stop() end

	ui._set_client(fake)
	local passed, err = pcall(function()
		ui.open()
		local state = ui._state()
		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "Keep this old chat" })
		ui.send()
		eq(state.thread_id, "clear-thread-1")
		eq(#fake.turns, 1)
		fake.handlers.on_notification("turn/completed", {
			threadId = state.thread_id,
			turn = { id = "clear-turn-1", status = "completed" },
		})
		state.contexts = { { type = "file", path = "/tmp/old" } }
		state.diff = "old diff"
		state.tokens = { totalTokens = 12 }

		local output_buf = state.output_buf
		local input_buf = state.input_buf
		local output_win = state.output_win
		local input_win = state.input_win
		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "/clear release prep" })
		ui.send()
		state = ui._state()

		eq(fake.unsubscribed, { "clear-thread-1" })
		eq(fake.named, { thread_id = "clear-thread-2", name = "release prep" })
		eq(fake.starts, 2)
		eq(#fake.turns, 1)
		eq(state.output_buf, output_buf)
		eq(state.input_buf, input_buf)
		eq(state.output_win, output_win)
		eq(state.input_win, input_win)
		eq(state.chat.blocks, {})
		eq(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), { "" })
		eq(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), { "" })
		eq(state.contexts, {})
		eq(state.diff, "")
		eq(state.tokens, nil)
		eq(state.thread_id, "clear-thread-2")
		eq(state.status, "ready")

		state.busy = true
		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "/clear" })
		ui.send()
		eq(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), { "/clear" })
		eq(state.thread_id, "clear-thread-2")
		eq(fake.starts, 2)
		eq(#fake.turns, 1)
	end)
	ui._reset()
	if not passed then
		error(err, 2)
	end
end)

test("native Codex tab starts a thread, streams a turn, and tracks its diff", function()
	ui._reset()
	ui.setup({ auto_context = false, command = { "missing-codex" } })
	local fake = { turns = {}, stopped = false }

	function fake:set_handlers(handlers)
		self.handlers = handlers
	end

	function fake:start_thread(opts, callback)
		self.thread_opts = opts
		callback({
			thread = { id = "thread-1", cwd = opts.cwd, turns = {} },
			cwd = opts.cwd,
			model = "gpt-test",
			reasoningEffort = "high",
		})
	end

	function fake:start_turn(thread_id, payload, callback)
		table.insert(self.turns, { thread_id = thread_id, payload = payload })
		callback({ turn = { id = "turn-1", status = "inProgress" } })
	end

	function fake:list_threads(_, callback)
		callback({})
	end

	function fake:unsubscribe_thread(thread_id, callback)
		self.unsubscribed = thread_id
		callback({})
	end

	function fake:stop()
		self.stopped = true
	end

	ui._set_client(fake)
	local passed, err = pcall(function()
		ui.open()
		local state = ui._state()
		vim.api.nvim_win_close(state.input_win, true)
		ui.open()
		state = ui._state()
		ok(vim.api.nvim_win_is_valid(state.output_win))
		ok(vim.api.nvim_win_is_valid(state.input_win))
		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "Simplify this plugin" })
		ui.send()

		eq(fake.turns[1].thread_id, "thread-1")
		eq(fake.turns[1].payload.input[1].text, "Simplify this plugin")
		eq(state.busy, true)
		local stable_chat_width = vim.api.nvim_win_get_config(state.output_win).width
		local stable_prompt_width = vim.api.nvim_win_get_config(state.input_win).width
		local stable_instruction_width = vim.api.nvim_win_get_config(state.instruction_win).width
		local function assert_action_status_width()
			eq(vim.api.nvim_win_get_config(state.output_win).width, stable_chat_width)
			eq(vim.api.nvim_win_get_config(state.input_win).width, stable_prompt_width)
			eq(vim.api.nvim_win_get_config(state.instruction_win).width, stable_instruction_width)
			eq(stable_chat_width, stable_prompt_width + 2)
			eq(stable_instruction_width, stable_prompt_width)
			for _, line in ipairs(vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false)) do
				eq(vim.fn.strdisplaywidth(line), stable_instruction_width)
			end
		end
		assert_action_status_width()
		local initial_spinner = vim.api.nvim_buf_get_lines(state.instruction_buf, -2, -1, false)[1]
		ok(
			vim.wait(400, function()
				local current = vim.api.nvim_buf_get_lines(state.instruction_buf, -2, -1, false)[1]
				return current ~= initial_spinner
			end, 10),
			"expected the active turn icon to spin"
		)
		assert_action_status_width()
		fake.handlers.on_notification("item/started", {
			threadId = "thread-1",
			turnId = "turn-1",
			item = {
				id = "command-1",
				type = "commandExecution",
				command = "rg blocks",
				status = "inProgress",
			},
		})
		assert_action_status_width()
		local command_output = {}
		for index = 1, 10 do
			table.insert(command_output, ("match %d"):format(index))
		end
		local action_tick = vim.api.nvim_buf_get_changedtick(state.output_buf)
		fake.handlers.on_notification("item/commandExecution/outputDelta", {
			threadId = "thread-1",
			turnId = "turn-1",
			itemId = "command-1",
			delta = table.concat(command_output, "\n"),
		})
		assert_action_status_width()
		eq(vim.api.nvim_buf_get_changedtick(state.output_buf), action_tick)
		ok(
			vim.wait(250, function()
				local block = state.chat.by_id["command-1"]
				return block and table.concat(block.lines, "\n"):find("... +6 lines", 1, true) ~= nil
			end, 5),
			"expected bounded command output to flush promptly"
		)
		local command_block = state.chat.by_id["command-1"]
		eq(#command_block.lines, action.preview_limit + 2)
		fake.handlers.on_notification("item/completed", {
			threadId = "thread-1",
			turnId = "turn-1",
			item = {
				id = "command-1",
				type = "commandExecution",
				command = "rg blocks",
				status = "completed",
				exitCode = 0,
			},
		})
		for index = 2, 7 do
			fake.handlers.on_notification("item/completed", {
				threadId = "thread-1",
				turnId = "turn-1",
				item = {
					id = "command-" .. index,
					type = "commandExecution",
					command = "echo command-" .. index,
					status = "completed",
					exitCode = 0,
				},
			})
		end
		fake.handlers.on_notification("item/started", {
			threadId = "thread-1",
			turnId = "turn-1",
			item = {
				id = "tool-1",
				type = "mcpToolCall",
				server = "search",
				tool = "inspect",
				arguments = { query = "action cells" },
				status = "inProgress",
			},
		})
		assert_action_status_width()
		fake.handlers.on_notification("item/mcpToolCall/progress", {
			threadId = "thread-1",
			turnId = "turn-1",
			itemId = "tool-1",
			message = "Inspecting action cells",
		})
		assert_action_status_width()
		contains(table.concat(state.chat.by_id["tool-1"].lines, "\n"), "Inspecting action cells")
		fake.handlers.on_notification("item/completed", {
			threadId = "thread-1",
			turnId = "turn-1",
			item = {
				id = "tool-1",
				type = "mcpToolCall",
				server = "search",
				tool = "inspect",
				arguments = { query = "action cells" },
				status = "completed",
				result = { content = { { type = "text", text = "Found action cells" } } },
			},
		})

		fake.handlers.on_notification("item/agentMessage/delta", {
			threadId = "thread-1",
			turnId = "turn-1",
			itemId = "message-1",
			delta = "Implemented.",
		})
		local buffered_tick = vim.api.nvim_buf_get_changedtick(state.output_buf)
		local detail_lines = {}
		for index = 1, 40 do
			table.insert(detail_lines, ("Detail line %d"):format(index))
		end
		fake.handlers.on_notification("item/agentMessage/delta", {
			threadId = "thread-1",
			turnId = "turn-1",
			itemId = "message-1",
			delta = "\n" .. table.concat(detail_lines, "\n"),
		})
		eq(vim.api.nvim_buf_get_changedtick(state.output_buf), buffered_tick)
		ok(
			vim.wait(250, function()
				local text = table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n")
				return text:find("Detail line 40", 1, true) ~= nil
			end, 5),
			"expected batched output to flush promptly"
		)
		ok(
			state.output_cache.changedtick ~= vim.api.nvim_buf_get_changedtick(state.output_buf),
			"full semantic parsing should stay paused during an active turn"
		)
		local content_line = vim.api.nvim_buf_line_count(state.output_buf)
		vim.cmd("redraw")
		local last_position = vim.fn.screenpos(state.output_win, content_line, 1)
		local turn_top = vim.api.nvim_win_get_position(state.instruction_win)[1] + 1
		ok(last_position.row > 0, "expected the latest response line to remain visible")
		ok(last_position.row < turn_top, "the vertically stacked turn panel must not cover the latest response")

		local function assert_output_at_end(message)
			local line = vim.api.nvim_buf_line_count(state.output_buf)
			eq(vim.api.nvim_win_get_cursor(state.output_win)[1], line)
			vim.cmd("redraw")
			local position = vim.fn.screenpos(state.output_win, line, 1)
			local turn_top = vim.api.nvim_win_get_position(state.instruction_win)[1] + 1
			ok(position.row > 0, message .. ": expected the final line to be visible")
			ok(position.row < turn_top, message .. ": expected the final line above the turn panel")
		end

		assert_output_at_end("streamed output should follow the transcript end")
		vim.api.nvim_set_current_win(state.output_win)
		vim.api.nvim_win_call(state.output_win, function()
			vim.api.nvim_win_set_cursor(state.output_win, { 1, 0 })
			vim.cmd("normal! zt")
		end)
		local manual_view = vim.api.nvim_win_call(state.output_win, function()
			return vim.fn.winsaveview()
		end)
		ok(manual_view.lnum < vim.api.nvim_buf_line_count(state.output_buf), "expected a manual position above the end")
		fake.handlers.on_notification("item/agentMessage/delta", {
			threadId = "thread-1",
			turnId = "turn-1",
			itemId = "message-1",
			delta = "\nOutput after manual scrolling",
		})
		ok(
			vim.wait(250, function()
				return state.chat.by_id["message-1"].text:find("Output after manual scrolling", 1, true) ~= nil
			end, 5),
			"expected output after manual scrolling to flush"
		)
		assert_output_at_end("new output should replace the manual scroll position")
		local end_view = vim.api.nvim_win_call(state.output_win, function()
			return vim.fn.winsaveview()
		end)
		ok(end_view.topline ~= manual_view.topline, "expected the viewport to return to the transcript end")
		fake.handlers.on_notification("item/completed", {
			threadId = "thread-1",
			turnId = "turn-1",
			item = { id = "message-1", type = "agentMessage", text = "Implemented." },
		})
		fake.handlers.on_notification("turn/diff/updated", {
			threadId = "thread-1",
			turnId = "turn-1",
			diff = "--- a/file\n+++ b/file",
		})
		fake.handlers.on_notification("item/started", {
			threadId = "thread-1",
			turnId = "turn-1",
			item = { id = "compaction-1", type = "contextCompaction" },
		})
		eq(state.status, "compacting")
		local compacting_output = table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n")
		contains(compacting_output, "Conversation context compacted.")
		fake.handlers.on_notification("item/completed", {
			threadId = "thread-1",
			turnId = "turn-1",
			item = { id = "compaction-1", type = "contextCompaction" },
		})
		fake.handlers.on_notification("thread/compacted", {
			threadId = "thread-1",
			turnId = "turn-1",
		})
		local compacted_output = table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n")
		contains(compacted_output, "Conversation context compacted.")
		eq(count(compacted_output, "Conversation context compacted."), 1)
		fake.handlers.on_notification("thread/compacted", {
			threadId = "thread-1",
			turnId = "turn-legacy-compaction",
		})
		fake.handlers.on_notification("item/started", {
			threadId = "thread-1",
			turnId = "turn-legacy-compaction",
			item = { id = "compaction-legacy", type = "contextCompaction" },
		})
		local legacy_first_output = table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n")
		eq(count(legacy_first_output, "Conversation context compacted."), 2)
		fake.handlers.on_notification("thread/tokenUsage/updated", {
			threadId = "thread-1",
			turnId = "turn-1",
			tokenUsage = {
				total = { totalTokens = 30927358 },
				last = { totalTokens = 177080 },
				modelContextWindow = 258400,
			},
		})
		fake.handlers.on_notification("turn/completed", {
			threadId = "thread-1",
			turn = { id = "turn-1", status = "completed" },
		})
		ok(
			vim.wait(350, function()
				return state.output_cache.changedtick == vim.api.nvim_buf_get_changedtick(state.output_buf)
			end, 5),
			"expected semantic output metadata to refresh after the turn"
		)

		local output = table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n")
		contains(output, "Simplify this plugin")
		contains(output, "Implemented.")
		eq(count(output, "Implemented."), 1)
		eq(state.diff, "--- a/file\n+++ b/file")
		eq(state.tokens.totalTokens, 177080)
		eq(state.token_totals.totalTokens, 30927358)
		local live_prompt_footer = chunks_text(vim.api.nvim_win_get_config(state.input_win).footer)
		contains(live_prompt_footer, "gpt-test · high")
		contains(live_prompt_footer, "ctx 31% · 258.4k")
		ok(
			live_prompt_footer:find("gpt-test · high", 1, true) < live_prompt_footer:find("ctx 31% · 258.4k", 1, true),
			"expected live model and effort before remaining context"
		)
		eq(state.busy, false)
		eq(state.instruction_spinner_timer, nil)
		contains(vim.api.nvim_buf_get_lines(state.instruction_buf, -2, -1, false)[1], icons.get("idle") .. " completed")
		eq(state.output_position_mode, nil)
		local expected_kinds = { "user" }
		for _ = 1, 8 do
			table.insert(expected_kinds, "activity")
		end
		table.insert(expected_kinds, "agent")
		table.insert(expected_kinds, "notice")
		table.insert(expected_kinds, "notice")
		eq(
			vim.tbl_map(function(block)
				return block.kind
			end, state.chat.blocks),
			expected_kinds
		)
		contains(state.chat.by_id["message-1"].text, "Detail line 40")
		eq(state.output_cache.chat_blocks, state.chat.blocks)
		local activities = state.chat:activities()
		eq(#activities, 8)
		for index = 1, 7 do
			eq(activities[index].counts, { command = 1, tool = 0, file = 0 })
		end
		eq(activities[8].counts, { command = 0, tool = 1, file = 0 })
		local activity = activities[1]
		eq(
			vim.api.nvim_win_call(state.output_win, function()
				return vim.fn.foldlevel(activity.line)
			end),
			2
		)
		eq(
			vim.api.nvim_win_call(state.output_win, function()
				return vim.fn.foldclosed(activity.line)
			end),
			-1
		)
		vim.api.nvim_win_set_cursor(state.output_win, { state.chat.blocks[1].header_line, 0 })
		ok(output_ui.jump_section(state, 1))
		eq(vim.api.nvim_win_get_cursor(state.output_win)[1], activity.line)
		ok(output_ui.jump_section(state, 1))
		eq(vim.api.nvim_win_get_cursor(state.output_win)[1], activities[2].line)
		vim.api.nvim_win_set_cursor(state.output_win, { activities[#activities].line, 0 })
		ok(output_ui.jump_section(state, 1))
		eq(vim.api.nvim_win_get_cursor(state.output_win)[1], state.chat.by_id["message-1"].header_line)
		vim.api.nvim_win_set_cursor(state.output_win, { activity.line, 0 })
		eq(output_ui.current_item(state).kind, "activity")
		ok(output_ui.yank_section(state))
		local activity_text = vim.fn.getreg('"')
		contains(activity_text, "rg blocks")
		contains(activity_text, "match 1")
		contains(activity_text, "match 10")
		ok(not activity_text:find("echo command-7", 1, true))
		ok(not activity_text:find("search.inspect", 1, true))
		ok(not activity_text:find("Simplify this plugin", 1, true))
		local windows_before = {}
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			windows_before[winid] = true
		end
		ok(output_ui.inspect(state, activity))
		local preview_win
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			if not windows_before[winid] then
				preview_win = winid
				break
			end
		end
		ok(preview_win and vim.api.nvim_win_is_valid(preview_win), "expected an activity detail float")
		local preview_text =
			table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview_win), 0, -1, false), "\n")
		contains(preview_text, "rg blocks")
		contains(preview_text, "match 1")
		contains(preview_text, "match 10")
		ok(not preview_text:find("echo command-7", 1, true))
		vim.api.nvim_win_close(preview_win, true)
		vim.api.nvim_win_set_cursor(state.output_win, { activities[#activities].line, 0 })
		ok(output_ui.inspect(state, activities[#activities]))
		local tool_preview_win
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			if not windows_before[winid] then
				tool_preview_win = winid
				break
			end
		end
		ok(tool_preview_win and vim.api.nvim_win_is_valid(tool_preview_win), "expected a tool detail float")
		local tool_preview =
			table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(tool_preview_win), 0, -1, false), "\n")
		contains(tool_preview, "search.inspect")
		contains(tool_preview, "Found action cells")
		vim.api.nvim_win_close(tool_preview_win, true)
		eq(vim.api.nvim_buf_get_lines(state.output_buf, 0, state.chat.line_count, false), state.chat:render_lines())
		eq(vim.api.nvim_buf_line_count(state.output_buf), state.chat.line_count)
		local blocks_before_stderr = #state.chat.blocks
		fake.handlers.on_stderr(model_refresh_stderr())
		fake.handlers.on_stderr(model_refresh_stderr())
		eq(#state.chat.blocks, blocks_before_stderr)
		fake.handlers.on_stderr("connection warning\n")
		eq(#state.chat.blocks, blocks_before_stderr + 1)
		eq(state.chat.blocks[#state.chat.blocks].kind, "warning")
		local blocks_after_warning = #state.chat.blocks
		fake.handlers.on_stderr(apply_patch_error_stderr())
		eq(#state.chat.blocks, blocks_after_warning, "duplicate patch stderr must stay in its action cell")
		fake.handlers.on_stderr(server_error_stderr())
		eq(#state.chat.blocks, blocks_after_warning, "duplicate command stderr must stay in its action cell")
		eq(ui.new_chat({ keep_layout = true }), true)
		eq(#ui._state().chat.blocks, 0)
		eq(fake.unsubscribed, "thread-1")
	end)
	ui._reset()
	if not passed then
		error(err, 2)
	end
	eq(fake.stopped, true)
end)

test("control-s steers the active turn instead of queueing", function()
	ui._reset()
	ui.setup({ auto_context = false, follow_up = "queue", command = { "missing-codex" } })
	local fake = { turns = {}, steers = {} }

	function fake:set_handlers(handlers)
		self.handlers = handlers
	end

	function fake:start_thread(opts, callback)
		callback({
			thread = { id = "thread-steer", cwd = opts.cwd, turns = {} },
			cwd = opts.cwd,
		})
	end

	function fake:start_turn(thread_id, payload, callback)
		table.insert(self.turns, { thread_id = thread_id, payload = payload })
		callback({ turn = { id = "turn-steer", status = "inProgress" } })
	end

	function fake:steer_turn(thread_id, turn_id, payload, callback)
		table.insert(self.steers, { thread_id = thread_id, turn_id = turn_id, payload = payload })
		self.steer_callback = callback
	end

	function fake:list_threads(_, callback)
		callback({})
	end

	function fake:stop() end

	ui._set_client(fake)
	local passed, err = pcall(function()
		ui.open()
		local state = ui._state()
		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "Start the implementation" })
		ui.send()
		eq(state.turn_id, "turn-steer")
		eq(#fake.turns, 1)
		fake.handlers.on_notification("item/agentMessage/delta", {
			threadId = "thread-steer",
			turnId = "turn-steer",
			itemId = "shared-message",
			delta = "Before steering.",
		})
		ok(
			vim.wait(250, function()
				return state.chat.by_id["shared-message"] ~= nil
			end, 5),
			"expected the initial response block to flush"
		)
		local function geometry(winid)
			local current = vim.api.nvim_win_get_config(winid)
			return {
				relative = current.relative,
				row = tonumber(current.row),
				col = tonumber(current.col),
				width = current.width,
				height = current.height,
			}
		end
		local stable_prompt_geometry = geometry(state.input_win)
		local initial_instruction_geometry = geometry(state.instruction_win)
		local initial_chat_geometry = geometry(state.output_win)
		eq(initial_instruction_geometry.height, 2)
		local function assert_prompt_stack(height)
			eq(geometry(state.input_win), stable_prompt_geometry)
			local instruction_geometry = geometry(state.instruction_win)
			local chat_geometry = geometry(state.output_win)
			eq(instruction_geometry.relative, initial_instruction_geometry.relative)
			eq(instruction_geometry.col, initial_instruction_geometry.col)
			eq(instruction_geometry.width, initial_instruction_geometry.width)
			eq(instruction_geometry.height, height)
			eq(instruction_geometry.row + instruction_geometry.height, stable_prompt_geometry.row)
			local instruction_config = vim.api.nvim_win_get_config(state.instruction_win)
			eq(instruction_config.win, state.output_host_win)
			eq(chat_geometry.row + chat_geometry.height, instruction_geometry.row)
			eq(chat_geometry.width, stable_prompt_geometry.width + 2)
			eq(chat_geometry.height, initial_chat_geometry.height - (height - initial_instruction_geometry.height))
			eq(state.prompt_reserved_rows, nil)
			eq(state.prompt_spacer_rows, nil)
			local lines = vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false)
			eq(#lines, height)
			for _, line in ipairs(lines) do
				eq(vim.fn.strdisplaywidth(line), instruction_geometry.width)
			end
		end
		assert_prompt_stack(2)
		fake.handlers.on_notification("item/reasoning/textDelta", {
			threadId = "thread-steer",
			turnId = "turn-steer",
			delta = "Checking the implementation.",
		})
		assert_prompt_stack(2)

		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "Keep the public API unchanged" })
		vim.api.nvim_set_current_win(state.input_win)
		local control_s = vim.api.nvim_replace_termcodes("<C-s>", true, false, true)
		vim.api.nvim_feedkeys(control_s, "x", false)

		eq(#fake.steers, 1)
		eq(fake.steers[1].thread_id, "thread-steer")
		eq(fake.steers[1].turn_id, "turn-steer")
		eq(fake.steers[1].payload.input[1].text, "Keep the public API unchanged")
		eq(#state.queue, 0)
		eq(#state.pending_instructions, 1)
		eq(state.pending_instructions[1].kind, "steer")
		ok(vim.api.nvim_win_is_valid(state.instruction_win))
		eq(vim.api.nvim_get_current_win(), state.input_win)
		local prompt_config = vim.api.nvim_win_get_config(state.input_win)
		local instruction_config = vim.api.nvim_win_get_config(state.instruction_win)
		eq(instruction_config.relative, "win")
		eq(instruction_config.win, state.output_host_win)
		eq(instruction_config.focusable, false)
		eq(instruction_config.col, 1)
		eq(instruction_config.width, prompt_config.width)
		eq(instruction_config.row + instruction_config.height, prompt_config.row)
		eq(instruction_config.border, "none")
		assert_prompt_stack(3)
		local instruction_text = table.concat(vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false), "\n")
		contains(instruction_text, "steer")
		contains(instruction_text, "Keep the public API unchanged")
		fake.handlers.on_notification("item/reasoning/textDelta", {
			threadId = "thread-steer",
			turnId = "turn-steer",
			delta = "Still finishing the previous thought.",
		})
		eq(#state.pending_instructions, 1)
		assert_prompt_stack(3)
		fake.steer_callback({})
		assert_prompt_stack(3)
		instruction_text = table.concat(vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false), "\n")
		contains(instruction_text, "steered")
		contains(instruction_text, "sent")
		contains(
			table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n"),
			transcript.header("user", " (steer)")
		)

		fake.handlers.on_notification("item/agentMessage/delta", {
			threadId = "thread-steer",
			turnId = "turn-steer",
			itemId = "shared-message",
			delta = "After steering.",
		})
		eq(#state.pending_instructions, 0)
		ok(vim.api.nvim_win_is_valid(state.instruction_win))
		assert_prompt_stack(2)
		instruction_text = table.concat(vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false), "\n")
		contains(instruction_text, "responding")
		ok(not instruction_text:find("Keep the public API unchanged", 1, true))
		ok(
			vim.wait(250, function()
				local continuation = state.chat.by_id["shared-message:agent:2"]
				return continuation and continuation.text == "After steering."
			end, 5),
			"expected a continuation response after the steer block"
		)
		local ordered = table.concat(state.chat:render_lines(), "\n")
		local before = ordered:find("Before steering.", 1, true)
		local steer = ordered:find("Keep the public API unchanged", 1, true)
		local after = ordered:find("After steering.", 1, true)
		ok(before and steer and after and before < steer and steer < after, "streamed output must preserve event order")
		eq(vim.api.nvim_buf_get_lines(state.output_buf, 0, state.chat.line_count, false), state.chat:render_lines())

		vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "Run the tests afterward" })
		ui.send()
		eq(#fake.steers, 1)
		eq(#state.queue, 1)
		eq(#state.pending_instructions, 1)
		eq(state.pending_instructions[1].kind, "queued")
		ok(vim.api.nvim_win_is_valid(state.instruction_win))
		assert_prompt_stack(3)
		instruction_text = table.concat(vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false), "\n")
		contains(instruction_text, "queued")
		contains(instruction_text, "Run the tests afterward")
		local queued_output = table.concat(vim.api.nvim_buf_get_lines(state.output_buf, 0, -1, false), "\n")
		ok(
			not queued_output:find("Queued follow-up", 1, true),
			"queued instructions should not add redundant transcript notices"
		)

		fake.handlers.on_notification("turn/completed", {
			threadId = "thread-steer",
			turn = { id = "turn-steer", status = "completed" },
		})
		ok(vim.wait(100, function()
			return #fake.turns == 2
		end))
		eq(fake.turns[2].payload.input[1].text, "Run the tests afterward")
		eq(#state.pending_instructions, 0)
		ok(vim.api.nvim_win_is_valid(state.instruction_win))
		assert_prompt_stack(2)
	end)
	ui._reset()
	if not passed then
		error(err, 2)
	end
end)

test("health reports the direct app-server architecture and parser status", function()
	ui.setup({ command = "sh" })
	local reports = {}
	local original = {
		start = vim.health.start,
		ok = vim.health.ok,
		warn = vim.health.warn,
		error = vim.health.error,
	}
	vim.health.start = function(message)
		table.insert(reports, message)
	end
	vim.health.ok = function(message)
		table.insert(reports, message)
	end
	vim.health.warn = function(message)
		table.insert(reports, message)
	end
	vim.health.error = function(message)
		table.insert(reports, message)
	end
	local passed, err = pcall(health.check)
	for key, value in pairs(original) do
		vim.health[key] = value
	end
	ui._reset()
	if not passed then
		error(err, 2)
	end
	local text = table.concat(reports, "\n")
	contains(text, "Supported Neovim nightly: 0.13")
	contains(text, "Codex executable found: sh")
	contains(text, "codex app-server directly")
	contains(text, "ACP parser")
end)

test("hot reload preserves the live client, thread, draft, and Codex tab", function()
	ui._reset()
	ui.setup({ auto_context = false, command = { "missing-codex" } })
	local process = fake_process()
	local live_client = Client.new({ spawn = process.spawn })
	live_client:start()
	live_client.initialized = true
	local pending_result
	live_client:request("test/pending", { value = 1 }, function(result, err)
		pending_result = { result = result, err = err }
	end)
	live_client.line_buffer.data = '{"partial":'
	local pending_requests = live_client.pending
	local line_buffer = live_client.line_buffer
	local process_handle = live_client.handle
	ui._set_client(live_client, { managed = true })
	ui.open()
	local state = ui._state()
	state.thread_id = "thread-hot-reload"
	state.turn_id = "turn-hot-reload"
	state.busy = true
	state.status = "responding"
	state.instruction_sequence = 1
	state.queue = {
		{
			_acp_instruction_id = "instruction:1",
			text = "Preserve this queued instruction",
			payload = { input = { { type = "text", text = "Preserve this queued instruction" } } },
		},
	}
	state.pending_instructions = {
		{ id = "instruction:1", kind = "queued", text = "Preserve this queued instruction" },
	}
	ui.open()
	ok(vim.api.nvim_win_is_valid(state.instruction_win))
	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "preserve this draft" })
	live_client.on_notification("item/agentMessage/delta", {
		threadId = "thread-hot-reload",
		turnId = "turn-hot-reload",
		itemId = "message-before-reload",
		delta = "Before reload.",
	})
	ok(
		vim.wait(250, function()
			return state.chat.by_id["message-before-reload"] ~= nil
		end, 5),
		"expected a structured block before reload"
	)
	vim.bo[state.output_buf].filetype = "markdown"

	local tabpage = state.tabpage
	local sessions_buf = state.sessions_buf
	local sessions_win = state.sessions_win
	local output_host_buf = state.output_host_buf
	local output_host_win = state.output_host_win
	local output_buf = state.output_buf
	local output_win = state.output_win
	local input_buf = state.input_buf
	local input_win = state.input_win
	local instruction_buf = state.instruction_buf
	local instruction_win = state.instruction_win
	local chat = state.chat
	local process_client = ui._client()
	local reload = require("acp.reload")
	local current_ui = ui
	local original_export = ui._export_runtime
	local bad_file = vim.fn.tempname() .. ".lua"
	local passed, err = pcall(function()
		vim.fn.writefile({ "local broken =" }, bad_file)
		local preflight, preflight_err = reload.reload({ silent = true, _files = { bad_file } })
		ok(not preflight, "expected invalid Lua to fail reload preflight")
		contains(preflight_err, "Reload preflight failed")
		ok(package.loaded["acp.ui"] == ui, "preflight failure must not unload the UI module")
		ok(ui._client() == process_client, "preflight failure must preserve the app-server client")

		package.preload["acp.ui"] = function()
			error("simulated reload failure")
		end
		local failed, failure = reload.reload({ silent = true })
		package.preload["acp.ui"] = nil
		ok(not failed, "expected the simulated reload to fail")
		contains(failure, "simulated reload failure")
		ok(package.loaded["acp.ui"] == ui, "expected the previous UI module after rollback")
		ok(ui._state() == state, "rollback must preserve the state table")
		ok(ui._client() == process_client, "rollback must preserve the app-server client")
		ok(process.killed == nil, "rollback must not stop the app-server client")

		ui._export_runtime = nil
		local reloaded, new_ui = reload.reload({ silent = true })
		ok(reloaded, new_ui)
		current_ui = new_ui
		ok(new_ui ~= ui, "expected a newly loaded UI module")
		ok(new_ui._state() == state, "expected the same state table")
		ok(state.chat == chat, "expected the same chat model table")
		ok(getmetatable(state.chat) == require("acp.blocks").Model, "expected methods from the reloaded block model")
		ok(require("acp.blocks").for_buffer(output_buf) == state.chat, "expected the output buffer to rebind")
		contains(state.chat.by_id["message-before-reload"].text, "Before reload.")
		eq(
			vim.api.nvim_buf_get_lines(
				output_buf,
				state.chat.by_id["message-before-reload"].header_line - 1,
				state.chat.by_id["message-before-reload"].header_line,
				false
			)[1],
			render.header("agent")
		)
		ok(new_ui._client() == process_client, "expected the same app-server client")
		ok(type(new_ui._client().set_thread_name) == "function", "expected reloaded client command methods")
		ok(live_client.handle == process_handle, "expected the same process handle")
		ok(live_client.pending == pending_requests, "expected the same pending request table")
		ok(live_client.line_buffer == line_buffer, "expected the same stream buffer")
		eq(live_client.line_buffer.data, '{"partial":')
		ok(process.killed == nil, "hot reload must not stop the app-server client")
		ok(getmetatable(live_client) == require("acp.codex").Client, "expected methods from the reloaded client module")
		eq(state.thread_id, "thread-hot-reload")
		eq(state.turn_id, "turn-hot-reload")
		eq(state.busy, true)
		eq(state.tabpage, tabpage)
		eq(state.sessions_buf, sessions_buf)
		eq(state.sessions_win, sessions_win)
		eq(state.output_host_buf, output_host_buf)
		eq(state.output_host_win, output_host_win)
		eq(state.output_buf, output_buf)
		eq(state.output_win, output_win)
		eq(state.input_buf, input_buf)
		eq(state.input_win, input_win)
		eq(state.instruction_buf, instruction_buf)
		eq(state.instruction_win, instruction_win)
		ok(vim.api.nvim_win_is_valid(state.instruction_win))
		contains(
			table.concat(vim.api.nvim_buf_get_lines(state.instruction_buf, 0, -1, false), "\n"),
			"Preserve this queued instruction"
		)
		eq(vim.bo[state.output_buf].filetype, "acp")
		local restored_chat = vim.api.nvim_win_get_config(state.output_win)
		eq(restored_chat.relative, "win")
		eq(restored_chat.win, state.output_host_win)
		local restored_prompt = vim.api.nvim_win_get_config(state.input_win)
		eq(restored_prompt.relative, "win")
		eq(restored_prompt.win, state.output_host_win)
		local restored_turn = vim.api.nvim_win_get_config(state.instruction_win)
		eq(restored_turn.relative, "win")
		eq(restored_turn.win, state.output_host_win)
		eq(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), { "preserve this draft" })

		live_client.on_notification("item/agentMessage/delta", {
			threadId = "thread-hot-reload",
			turnId = "turn-hot-reload",
			itemId = "message-after-reload",
			delta = "Still connected.",
		})
		ok(
			vim.wait(250, function()
				return table
					.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n")
					:find("Still connected.", 1, true) ~= nil
			end, 5),
			"expected output from the reloaded client to flush promptly"
		)
		local output = table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n")
		eq(
			vim.tbl_map(function(block)
				return block.kind
			end, state.chat.blocks),
			{ "agent", "agent" }
		)
		eq(vim.api.nvim_buf_get_lines(output_buf, 0, state.chat.line_count, false), state.chat:render_lines())
		contains(output, "Still connected.")
		live_client:handle_message({ id = 0, result = { preserved = true } })
		eq(pending_result, { result = { preserved = true }, err = nil })
	end)
	package.preload["acp.ui"] = nil
	pcall(vim.fn.delete, bad_file)
	if package.loaded["acp.ui"] == ui then
		ui._export_runtime = original_export
	end
	current_ui._reset()
	eq(process.killed, 15)
	if not passed then
		error(err, 2)
	end
end)

local failures = {}
for _, case in ipairs(tests) do
	local passed, err = pcall(case.callback)
	if passed then
		print(("ok - %s"):format(case.name))
	else
		table.insert(failures, ("not ok - %s\n%s"):format(case.name, err))
	end
end

if #failures > 0 then
	vim.api.nvim_err_writeln(table.concat(failures, "\n"))
	vim.cmd("cquit 1")
end
