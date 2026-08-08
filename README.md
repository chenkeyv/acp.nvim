# acp.nvim

A Codex-first client for Neovim. It talks directly to
[Codex app-server](https://developers.openai.com/codex/app-server), the same
client-facing server used by the
[Codex IDE extension](https://developers.openai.com/codex/ide), and renders the
experience with native Neovim tab pages, buffers, selectors, and permission
prompts.

The `acp.nvim` name and `:Acp*` command prefix are retained for continuity.
Generic ACP adapters and Claude support are intentionally outside the first
phase.

## What works

- one long-lived `codex app-server` process per Neovim instance
- new, recent, and resumed Codex threads, including VS Code-created threads
- a persistent left sessions split with the current chat pinned at the top
- an inset floating prompt with role, status, and tool-aware chat styling
- streamed agent messages and plans
- command, tool, and file-change summaries
- model and reasoning-effort selectors from the server catalog
- token usage, turn status, interruption, and follow-up queueing or steering
- current-file and visual/range context
- command, file-change, and permission-profile approval prompts
- Codex `request_user_input` questions and basic MCP elicitation when enabled
  by the server's negotiated capabilities
- review, context compaction, login, and a read-only unified diff view
- transactional Lua hot reloads that preserve the Codex process, thread, tab,
  prompt draft, and active turn

Codex app-server owns command execution, file changes, sandboxing, and policy.
This plugin sends prompts/editor context and displays the server's events and
approval requests; it does not implement a second filesystem or terminal tool
runner.

## Requirements

- Neovim 0.10 or newer
- a recent Codex CLI on `PATH`
- an authenticated Codex session (`codex login` or `:AcpLogin`)

No npm ACP adapter is required.

## Installation

With `vim.pack`:

```lua
vim.g.acp_nvim_config = {
	-- nil values inherit Codex config.toml and server defaults.
	model = nil,
	reasoning_effort = nil,
}

vim.pack.add({
	"https://github.com/chenkeyv/acp.nvim",
})
```

Or call setup explicitly from another plugin manager:

```lua
require("acp").setup({
	command = { "codex", "app-server" },
	auto_context = true,
	follow_up = "queue", -- busy-turn delivery for <C-CR> and :AcpSend: "queue" or "steer"
	thread_sources = { "cli", "vscode", "appServer" },
	window = {
		input_height = 6,
		input_padding = 2,
		sessions_width = 30,
	},
})
```

`command = "codex"` is also accepted and expands to the default app-server
command. A command table is used exactly as supplied.

The prompt floats over reserved blank rows at the bottom of the chat, so it
does not cover the latest response. `input_height` includes the frame and
`input_padding` controls its inset from the chat text area.

The sessions split is scoped to the current working directory, like
`codex resume` without `--all`. It includes the CLI and VS Code interactive
sources plus `appServer`, so chats created by acp.nvim remain resumable too.

Useful optional overrides:

```lua
require("acp").setup({
	model = "gpt-5.6-sol",
	reasoning_effort = "high",
	personality = "pragmatic",
	approval_policy = "on-request", -- "untrusted", "on-request", or "never"
	sandbox = "workspace-write", -- "read-only", "workspace-write", or "danger-full-access"
	review_delivery = "inline", -- "inline" or "detached"
	max_threads = 100,
})
```

## Commands

| Command | Purpose |
| --- | --- |
| `:AcpChat [prompt]` | Open the dedicated Codex tab; a range adds the selected lines as context |
| `:AcpNew [prompt]` | Start a fresh chat |
| `:AcpThreads` | Select and resume a recent thread |
| `:AcpSessions` | Focus or restore the left sessions split |
| `:AcpAddContext` | Add the current file or selected range |
| `:AcpAddFile` | Add the current file |
| `:AcpModel` | Choose a model advertised by app-server |
| `:AcpReasoning` | Choose a supported reasoning effort |
| `:AcpReview [instructions]` | Review uncommitted changes or use custom instructions |
| `:AcpDiff` | Open the latest unified diff |
| `:AcpActions` | Open the native action selector |
| `:AcpLogin` | Inspect account state or start ChatGPT login |
| `:AcpSend` | Send the prompt buffer |
| `:AcpStop` | Interrupt the active turn |
| `:AcpClose` | Close the Codex tab without stopping app-server |
| `:AcpReload` | Reload plugin Lua while preserving the current Codex session and tab |

The prompt also accepts `/model`, `/reasoning`, `/review`, `/compact`,
`/status`, `/new`, `/threads`, `/login`, and `/reload`.

Codex tab keymaps:

- `<C-s>` starts a turn when idle or steers the active turn
- `<C-CR>` sends from the prompt, using `follow_up` when a turn is active
- `i` focuses the prompt from output
- `n`, `t`, `d`, `m`, `r`, and `s` select new chat, sessions, diff, model,
  reasoning, and stop from output
- in the sessions split, `<Enter>` resumes a session, `r` refreshes the list,
  `n` starts a new chat, and `i` focuses the prompt
- `q` closes the Codex tab and returns to the source tab

## Hot reload during development

After updating the files on Neovim's runtime path, run `:AcpReload`. The reload
is transactional: it keeps the existing app-server process and state tables,
loads fresh `acp.*` modules, then rebinds server callbacks, commands, keymaps,
and autocommands. Before unloading anything, it compiles every Lua module under
`lua/acp/`. If preflight, module loading, or runtime adoption fails, the previous
modules stay active and the current chat is left untouched. Development
environments may safely drive this command from their own debounced filesystem
watcher.

An installation that predates `:AcpReload` needs one final Neovim restart to
load the command. Later updates can use hot reload.

## Current scope

This is the first native-client slice, not a pixel-for-pixel copy of the VS
Code extension. It currently keeps one visible chat tab, accepts text/file
context rather than image or audio input, presents MCP form data as JSON, and
shows a unified diff rather than per-hunk review controls. Cloud-task handoff,
branch workflows, multiple simultaneous chat tabs, and richer attachment UI are
future work.

## Health and tests

Run `:checkhealth acp` to verify Neovim, the Codex executable, and direct
app-server configuration.

```sh
NVIM_LOG_FILE=/tmp/acp.nvim-nvim.log nvim --headless -u tests/minimal_init.lua \
  -c "luafile tests/acp_spec.lua" -c "qa!"
```
