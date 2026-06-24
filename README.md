# acp.nvim

Minimal Agent Client Protocol client for Neovim.

This plugin provides an editor-native ACP chat surface:

- dedicated ACP tab by default
- side panel for open ACP sessions
- plain output buffer for streamed agent responses
- output-visible run status for active prompts, tools, and completion
- Neovim highlight groups for readable transcript sections
- non-blocking adapter startup and session creation
- plain-text transcript history under Neovim state
- editor context insertion from the source buffer, bounded Tree-sitter node text, LSP clients, and diagnostics
- visual/range context capture for selected code
- LSP diagnostic fix drafts from the current buffer or visual range
- floating permission chooser with numbered actions
- floating file-write review with a diff preview before applying agent edits
- quickfix navigation for files changed during an ACP session
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
- `:AcpChatBuffer [adapter]` opens the split-window layout
- `:AcpSend` sends the current prompt
- `:AcpStop` stops the current agent process
- `:AcpSessions` focuses the sessions side panel
- `:AcpChanges` opens a quickfix list of files changed in the current ACP session
- `:AcpHistory` opens saved transcript history
- `:AcpAddContext` inserts source-buffer context into the current prompt
- `:AcpFixDiagnostics [adapter]` opens chat with a diagnostics-focused draft prompt
- `:AcpHealth [adapter]` checks whether the adapter command is available

In the sessions panel:

- `<Enter>` focuses the session under the cursor

In the prompt buffer:

- `<Enter>` inserts a newline
- `<C-Enter>` sends the prompt
- `<C-s>` also sends the prompt as a terminal-compatible fallback
- `<leader>ac` inserts source-buffer context into the prompt
- `<leader>af` opens the current session's changed files in quickfix

The chat-opening commands accept a line range, so opening ACP from Visual mode
preserves the selected lines for `:AcpAddContext`.
`:AcpFixDiagnostics` also accepts a range, limiting the diagnostic draft to
that selection.

## Development

Activate this checkout in the already installed `vim.pack` plugin slot:

```sh
scripts/update-local-plugin.sh
```

The script moves the installed checkout to `acp.nvim.remote`, then symlinks this
repo in its place. Later edits in this checkout are picked up by a fresh Neovim
session. To restore the installed checkout:

```sh
scripts/update-local-plugin.sh --restore
```

Run the headless smoke tests with:

```sh
NVIM_LOG_FILE=/tmp/acp.nvim-nvim.log nvim --headless -u tests/minimal_init.lua -c "luafile tests/acp_spec.lua" -c "qa!"
```

## Status

This is an early ACP client. Terminal operations, adapter-backed session
restoration, and batch pre-apply review workflows are not implemented yet.
