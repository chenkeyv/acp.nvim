# acp.nvim

Minimal Agent Client Protocol client for Neovim.

This plugin provides an editor-native ACP chat surface:

- dedicated ACP tab by default
- side panel for open ACP sessions
- plain output buffer for streamed agent responses
- output-visible run status for active prompts, tools, and completion
- floating Markdown input prompt for completion-friendly editing
- `codex-acp` and `claude-agent-acp` adapter presets
- basic ACP JSON-RPC, session, prompt, permission, and file read/write support

## Requirements

- Neovim nightly
- An ACP adapter binary on `PATH`

For Codex:

```sh
npm install -g @zed-industries/codex-acp
```

## Installation

With `vim.pack`:

```lua
vim.pack.add({
	"https://github.com/chenkeyv/acp.nvim",
})
```

The Codex adapter automatically reads the active Codex model and context window
from Codex metadata. Other adapters can provide prompt-title metadata with
static values or a resolver function:

```lua
vim.g.acp_nvim_config = {
	adapters = {
		claude_code = {
			metadata = function()
				return {
					model = "claude-sonnet-4.5",
					context_window = 200000,
				}
			end,
		},
	},
}
```

## Commands

- `:AcpChat [codex|claude_code]` opens the default dedicated tab layout
- `:AcpChatTab [adapter]` opens the dedicated tab layout
- `:AcpChatFloat [adapter]` opens a floating output/input layout
- `:AcpChatWindow [adapter]` opens a split-window layout
- `:AcpSend` sends the current prompt
- `:AcpStop` stops the current agent process
- `:AcpSessions` focuses the sessions side panel
- `:AcpHealth [adapter]` checks whether the adapter command is available

In the sessions panel:

- `<Enter>` focuses the session under the cursor

In the prompt buffer:

- `<Enter>` inserts a newline
- `<C-Enter>` sends the prompt
- `<C-s>` also sends the prompt as a terminal-compatible fallback

## Status

This is an early minimal ACP client. Terminal operations, session switching, and
rich diff approval UI are not implemented yet.
