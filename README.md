# acp.nvim

Minimal Agent Client Protocol client for Neovim.

This plugin provides an editor-native ACP chat surface:

- dedicated ACP tab by default
- side panel for open ACP sessions
- floating session picker from any buffer
- plain output buffer for streamed agent responses
- output-visible run status for active prompts, tools, and completion
- Neovim highlight groups for readable transcript sections
- non-blocking adapter startup and session creation
- floating slash-command picker for adapter-advertised commands
- native slash-command completion in the prompt buffer
- floating session config picker for adapter-advertised model, mode, and reasoning options
- per-session prompt history recall
- plain-text transcript history under Neovim state
- saved transcript replay into a new chat draft
- adapter-backed session listing and restoration
- async LSP document-symbol picker for adding focused symbol context
- editor context insertion from the source buffer, bounded Tree-sitter node text, LSP clients, and diagnostics
- visual/range context capture for selected code
- context and review draft commands for source/Visual-mode workflows
- LSP diagnostic fix drafts from the current buffer or visual range
- floating permission chooser with numbered actions
- floating terminal command approval with live output in tool calls
- floating batch file-write review with diff previews before applying agent edits
- quickfix navigation for files changed during an ACP session
- floating Markdown input prompt for completion-friendly editing
- `codex-acp` and `claude-agent-acp` adapter presets
- basic ACP JSON-RPC, session, prompt, permission, terminal, and file read/write support

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
- `:AcpChatContext [adapter]` opens chat with source-buffer context already in the prompt
- `:AcpReview [adapter]` opens chat with a review-focused draft prompt
- `:AcpChatTab [adapter]` opens the dedicated tab layout
- `:AcpChatFloat [adapter]` opens a floating output/input layout
- `:AcpChatWindow [adapter]` opens a split-window layout
- `:AcpChatBuffer [adapter]` opens the split-window layout
- `:AcpSend` sends the current prompt
- `:AcpPromptPrev` recalls the previous sent prompt in the current ACP session
- `:AcpPromptNext` steps forward through prompt history or restores the draft
- `:AcpStop` stops the current agent process
- `:AcpSessions` focuses the sessions side panel or opens a floating session picker
- `:AcpChanges` opens a quickfix list of files changed in the current ACP session
- `:AcpCommands` opens a picker for slash commands advertised by the current ACP session
- `:AcpConfig` opens a picker for config options advertised by the current ACP session
- `:AcpSymbols` opens an LSP document-symbol picker for the source buffer
- `:AcpHistory` opens saved transcript history
- `:AcpRestore [adapter]` lists adapter-backed sessions and restores the selected session
- `:AcpHistoryDraft [adapter]` opens saved transcript history and drafts a new chat from the selected transcript
- `:AcpAddContext` inserts source-buffer context into the current prompt
- `:AcpFixDiagnostics [adapter]` opens chat with a diagnostics-focused draft prompt
- `:AcpHealth [adapter]` checks whether the adapter command is available

In the sessions panel:

- `<Enter>` focuses the session under the cursor

In the prompt buffer:

- `<Enter>` inserts a newline
- `<C-Enter>` sends the prompt
- `<C-s>` also sends the prompt as a terminal-compatible fallback
- `<M-p>` / `<M-n>` recall previous/next prompts for the current session
- `<C-Space>` opens native ACP prompt completion
- `<leader>ac` inserts source-buffer context into the prompt
- `<leader>af` opens the current session's changed files in quickfix
- `<leader>a/` opens advertised ACP slash commands
- `<leader>ao` opens advertised ACP config options
- `<leader>al` opens source-buffer LSP symbols

The chat-opening and draft commands accept a line range, so opening ACP from
Visual mode preserves the selected lines for `:AcpAddContext`,
`:AcpChatContext`, `:AcpReview`, and `:AcpFixDiagnostics`.

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

This is an early ACP client; expect adapter support and protocol coverage to vary.
