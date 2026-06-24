# acp.nvim

Minimal Agent Client Protocol client for Neovim.

This plugin provides an editor-native ACP chat surface:

- dedicated ACP tab by default
- side panel for open ACP sessions
- visual session sidebar with current-session highlighting and status badges
- command-style ACP action palette for discovering session and global workflows
- searchable floating pickers for actions, sessions, output, history, diagnostics, LSP, and Tree-sitter workflows
- source preview windows for diagnostics, symbols, references, code actions, and Tree-sitter pickers
- plain output buffer for streamed agent responses
- visual output dashboard with source, model, context window, and key workflow hints
- output-visible run status for active prompts, tools, and completion
- live output winbar/title with status, model, context, and changed-file counts
- Neovim highlight groups and virtual badges for transcript sections, tools, terminal output, and errors
- ghost-text output hints and lightweight animated busy status
- optional Tree-sitter Markdown/code-fence language injection for agent responses
- floating output outline for jumping across long transcripts
- native folds for collapsing transcript sections
- non-blocking adapter startup and session creation
- floating slash-command picker for adapter-advertised commands
- native slash-command completion in the prompt buffer
- prompt-buffer ghost text and draft statistics while composing
- floating session config picker for adapter-advertised model, mode, and reasoning options
- per-session prompt history recall
- searchable, previewable plain-text transcript history under Neovim state
- saved transcript replay into a new chat draft
- adapter-backed session listing and restoration
- async LSP code-action picker for drafting focused fix/refactor prompts
- async LSP hover context insertion for source-cursor documentation
- async LSP references picker for adding focused usage context
- async LSP document-symbol picker for adding focused symbol context
- Tree-sitter node picker for adding syntax-aware focused context
- editor context insertion from the source buffer, bounded Tree-sitter node text, LSP clients, and diagnostics
- visual/range context capture for selected code
- source-buffer virtual marks showing the code linked to an open ACP session
- context and review draft commands for source/Visual-mode workflows
- LSP diagnostic fix drafts from the current buffer or visual range
- floating permission chooser with numbered actions
- floating terminal command approval with live output in tool calls
- floating batch file-write review with diff previews before applying agent edits
- quickfix navigation for files changed during an ACP session
- floating diagnostics picker for drafting focused fixes
- floating Markdown input prompt for completion-friendly editing
- native `:checkhealth acp` diagnostics for adapter commands and metadata
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
- `:AcpActions` opens a picker of available ACP workflows
- `:AcpChanges` opens a quickfix list of files changed in the current ACP session
- `:AcpOutput` opens a floating outline of the current output transcript
- `:AcpDiagnostics` opens a picker for source-buffer diagnostics
- `:AcpCommands` opens a picker for slash commands advertised by the current ACP session
- `:AcpConfig` opens a picker for config options advertised by the current ACP session
- `:AcpCodeActions` opens an LSP code-action picker for the source buffer or range
- `:AcpHover` inserts LSP hover documentation for the source cursor
- `:AcpReferences` opens an LSP references picker for the source cursor
- `:AcpSymbols` opens an LSP document-symbol picker for the source buffer
- `:AcpTreeSitter` opens a Tree-sitter node picker for the source cursor
- `:AcpHistory` opens saved transcript history
- `:AcpRestore [adapter]` lists adapter-backed sessions and restores the selected session
- `:AcpHistoryDraft [adapter]` opens saved transcript history and drafts a new chat from the selected transcript
- `:AcpAddContext` inserts source-buffer context into the current prompt
- `:AcpFixDiagnostics [adapter]` opens chat with a diagnostics-focused draft prompt
- `:AcpHealth [adapter]` checks the adapter command and prompt metadata wiring
- `:checkhealth acp` checks configured adapter commands and prompt metadata wiring

In the sessions panel:

- `<Enter>` focuses the session under the cursor
- `<leader>ak` opens the ACP action palette

In the prompt buffer:

- empty prompts show ghost-text workflow hints; non-empty prompts show draft stats
- `<Enter>` inserts a newline
- `<C-Enter>` sends the prompt
- `<C-s>` also sends the prompt as a terminal-compatible fallback
- `<M-p>` / `<M-n>` recall previous/next prompts for the current session
- `<C-Space>` opens native ACP prompt completion
- `<leader>ac` inserts source-buffer context into the prompt
- `<leader>av` opens the output outline
- `<leader>ad` opens source-buffer diagnostics
- `<leader>af` opens the current session's changed files in quickfix
- `<leader>a/` opens advertised ACP slash commands
- `<leader>ao` opens advertised ACP config options
- `<leader>ak` opens the ACP action palette
- `<leader>aa` opens source-buffer LSP code actions
- `<leader>ah` inserts source-buffer LSP hover documentation
- `<leader>ar` opens source-buffer LSP references
- `<leader>al` opens source-buffer LSP symbols
- `<leader>at` opens source-buffer Tree-sitter nodes

In the output buffer:

- `]]` jumps to the next transcript section
- `[[` jumps to the previous transcript section
- `za` toggles the fold under the cursor
- `zM` closes all transcript folds
- `zR` opens all transcript folds
- `<leader>av` opens the output outline
- `<leader>ak` opens the ACP action palette
- `<leader>az` toggles the fold under the cursor

In floating ACP pickers:

- `/` filters visible picker rows
- `<C-l>` clears the active picker filter
- source-backed pickers show a live preview beside the picker
- `<Enter>` selects the row under the cursor
- `q` or `<Esc>` closes the picker

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
