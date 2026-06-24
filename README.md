# acp.nvim

Minimal Agent Client Protocol client for Neovim.

This plugin provides an editor-native ACP chat surface:

- dedicated ACP tab by default
- side panel for open ACP sessions
- visual session sidebar with current-session highlighting and status badges
- floating session picker with transcript, source, status, and change previews
- native session close controls from commands, actions, and the session sidebar
- command-style ACP action palette for discovering session and global workflows
- searchable floating pickers for actions, sessions, output, history, diagnostics, LSP, and Tree-sitter workflows
- source preview windows for diagnostics, symbols, references, code actions, and Tree-sitter pickers
- plain output buffer for streamed agent responses
- visual output dashboard with source, model, context window, and key workflow hints
- animated dashboard activity badge with run status and live transcript counts
- live transcript metrics for sections, code blocks, source locations, and changes
- output-visible run status for active prompts, tools, and completion
- live output winbar/title with status, model, context, item position, and changed-file counts
- cursor-aware output breadcrumb showing the active transcript section
- cursor-aware current-section highlighting in the output buffer
- cursor-aware current-item highlighting for references, code blocks, and problems
- searchable output transcript picker with progress, context previews, and jump-to-line navigation
- current-section yank action with a short visual pulse in the output buffer
- follow-up prompt drafting from the current output section
- direct `gf` navigation from transcript file references into source
- inline reference highlights with `R>` signs and right-aligned badges
- context-aware `<Enter>` action for opening transcript references and code blocks
- cursor-aware output action picker for item-specific transcript workflows
- hover-style `K` inspector for output references, code blocks, problems, and sections with winbar status and close keymaps
- cursor-aware code-block yank action that copies fenced output without Markdown fences
- searchable output code-block picker with language-aware previews and scratch buffers
- code-block scratch buffers with winbar actions, Tree-sitter/filetype status, and yank/close keymaps
- virtual code-block headers with language, line count, injection status, and action hints
- searchable output location picker for jumping from transcript file references into source
- quickfix export for transcript file references
- Neovim highlight groups and virtual badges for transcript sections, tools, terminal output, and errors
- tool and terminal virtual headers with activity labels and action hints
- sign-column markers for transcript sections, references, code blocks, run status, tools, files, and errors
- right-aligned output timeline badges with section index and transcript progress
- per-section right-aligned summary badges for line, word, and code-block counts
- native output diagnostics and location-list navigation for transcript errors and stderr
- virtual section separators for scanning long output without changing transcript text
- ghost-text output hints and lightweight animated busy status
- cursor-sensitive ghost-text action hints for references, code blocks, errors, and sections
- optional Tree-sitter Markdown/code-fence language injection for agent responses
- floating output outline with progress markers for jumping across long transcripts
- native folds for collapsing transcript sections
- non-blocking adapter startup and session creation
- floating slash-command picker for adapter-advertised commands
- native slash-command completion in the prompt buffer
- prompt-buffer ghost text and draft statistics while composing
- prompt-focused action picker with source, LSP, Tree-sitter, output, and session workflows
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
- source-buffer diagnostic badges for linked context ranges
- source-context refresh for moving a live session to the current cursor or range
- source-buffer action lens for focusing the linked chat and adding source/LSP/Tree-sitter context
- context and review draft commands for source/Visual-mode workflows
- LSP diagnostic fix drafts from the current buffer or visual range
- floating permission chooser with numbered actions
- floating terminal command approval with live output in tool calls
- floating batch file-write review with diff previews before applying agent edits
- previewed changed-file picker with quickfix export for files written by the agent
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
- `:AcpClose` closes the current ACP session and clears linked source marks
- `:AcpCloseAll` closes every open ACP session
- `:AcpSessions` focuses the sessions side panel or opens a floating session picker with previews
- `:AcpActions` opens a picker of available ACP workflows
- `:AcpPromptActions` opens composer-focused actions with source context preview
- `:AcpSourceActions` opens actions for the source buffer linked to an ACP session
- `:AcpChanges` opens a previewed picker of files changed in the current ACP session
- `:AcpChangesQuickfix` opens a quickfix list of files changed in the current ACP session
- `:AcpOutput` opens a floating outline of the current output transcript
- `:AcpOutputSearch` opens every non-empty output line with context previews
- `:AcpOutputYank` yanks the current output section into the unnamed register
- `:AcpOutputDraft` inserts the current output section as follow-up prompt context
- `:AcpOutputOpen` opens the local file reference or code block under the output cursor
- `:AcpOutputInspect` opens a floating preview for the output item under the cursor
- `:AcpOutputActions` opens cursor-aware actions for the current output item
- `:AcpOutputNextItem` / `:AcpOutputPrevItem` jump between output references, code blocks, and problems
- `:AcpCodeBlocks` opens fenced code blocks from the current output with language-aware previews
- `:AcpCodeBlockYank` yanks the fenced code block under the output cursor
- `:AcpOutputLocations` opens local file references from the current output with source previews
- `:AcpOutputQuickfix` sends local file references from the current output to quickfix
- `:AcpOutputProblems` opens transcript errors and stderr as native diagnostics in the location list
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
- `:AcpRefreshSource` updates the linked source context to the current cursor or range
- `:AcpFixDiagnostics [adapter]` opens chat with a diagnostics-focused draft prompt
- `:AcpHealth [adapter]` checks the adapter command and prompt metadata wiring
- `:checkhealth acp` checks configured adapter commands and prompt metadata wiring

In the sessions panel:

- `<Enter>` focuses the session under the cursor
- `x` closes the session under the cursor
- `<leader>ak` opens the ACP action palette

In the prompt buffer:

- empty prompts show ghost-text workflow hints; non-empty prompts show draft stats
- `?` opens composer-focused actions with source context preview
- `<Enter>` inserts a newline
- `<C-Enter>` sends the prompt
- `<C-s>` also sends the prompt as a terminal-compatible fallback
- `<M-p>` / `<M-n>` recall previous/next prompts for the current session
- `<C-Space>` opens native ACP prompt completion
- `<leader>ac` inserts source-buffer context into the prompt
- `<leader>ax` searches output transcript lines
- `<leader>ay` yanks the current output section
- `<leader>ai` inserts the current output section as follow-up prompt context
- `<leader>av` opens the output outline
- `<leader>ab` opens output code blocks
- `<leader>aY` yanks the code block under the cursor
- `<leader>ag` opens output file references
- `<leader>ae` opens output errors/stderr in the location list
- `<leader>ad` opens source-buffer diagnostics
- `<leader>af` previews the current session's changed files
- `<leader>a/` opens advertised ACP slash commands
- `<leader>ao` opens advertised ACP config options
- `<leader>ak` opens the ACP action palette
- `<leader>aa` opens source-buffer LSP code actions
- `<leader>ah` inserts source-buffer LSP hover documentation
- `<leader>ar` opens source-buffer LSP references
- `<leader>al` opens source-buffer LSP symbols
- `<leader>at` opens source-buffer Tree-sitter nodes

In the output buffer:

- the current line shows ghost-text action hints for references, code blocks, errors, and sections
- `]]` jumps to the next transcript section
- `[[` jumps to the previous transcript section
- `]o` / `[o` jump between output references, code blocks, and problems
- `za` toggles the fold under the cursor
- `zM` closes all transcript folds
- `zR` opens all transcript folds
- `?` opens cursor-aware actions for the current output item
- `<Enter>` opens the local file reference or code block under the cursor
- `K` previews the reference, code block, problem, or section under the cursor
- `gf` opens the local file reference under the cursor
- `<leader>ax` searches output transcript lines
- `<leader>ay` yanks the current output section
- `<leader>ai` inserts the current output section as follow-up prompt context
- `<leader>av` opens the output outline
- `<leader>ab` opens output code blocks
- `<leader>aY` yanks the code block under the cursor
- `<leader>ag` opens output file references
- `<leader>ae` opens output errors/stderr in the location list
- `<leader>ak` opens the ACP action palette
- `<leader>az` toggles the fold under the cursor

In floating ACP pickers:

- `/` filters visible picker rows
- `<C-l>` clears the active picker filter
- source-backed pickers show a live preview beside the picker
- changed-file and output-location pickers use `Q` to export rows to quickfix
- `<Enter>` selects the row under the cursor
- `q` or `<Esc>` closes the picker

In source buffers linked to an ACP session:

- marked context ranges show an ACP lens with session status, diagnostic badges, and `:AcpSourceActions`
- `:AcpSourceActions` focuses the linked chat or opens source refresh, LSP, Tree-sitter, and output workflows
- `:AcpRefreshSource` moves the linked chat's source context to the current cursor or Visual range

The chat-opening and draft commands accept a line range, so opening ACP from
Visual mode preserves the selected lines for `:AcpAddContext`,
`:AcpChatContext`, `:AcpReview`, `:AcpRefreshSource`, and `:AcpFixDiagnostics`.

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
