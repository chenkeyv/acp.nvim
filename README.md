# acp.nvim

Minimal Agent Client Protocol client for Neovim.

This plugin provides an editor-native ACP chat surface:

- dedicated ACP tab by default
- side panel for open ACP sessions
- iconized session sidebar with current-session highlighting, status badges, transcript counts, and source context
- floating session picker with transcript, source, status, and change previews
- native session close controls from commands, actions, and the session sidebar
- command-style ACP action palette for discovering session and global workflows
- searchable floating pickers for actions, sessions, output, history, diagnostics, LSP, and Tree-sitter workflows
- source preview windows for diagnostics, LSP location, symbol, code-action, inlay-hint, selection-range, and Tree-sitter pickers
- plain output buffer for streamed agent responses
- shared Nerd Font iconography across prompt ribbons, sessions, source overlays, output signs, maps, pickers, and action chips
- iconized output dashboard with source, model, context window, transcript metrics, and key workflow hints
- animated dashboard activity badge with run status and live transcript counts
- live transcript metrics for sections, code blocks, source locations, and changes
- output-visible run status for active prompts, tools, and completion
- live output winbar/title with status, model, context, item position, and changed-file counts
- cursor-aware output breadcrumb showing the active transcript section
- cursor-following output context ribbon with progress, skyline, section span, and item orientation
- cursor-aware current-section highlighting in the output buffer
- cursor-aware current-item highlighting for references, code blocks, and problems
- unified output item picker for references, code blocks, and problems with previews
- searchable output transcript picker with progress, context previews, and jump-to-line navigation
- persistent floating output map with progress rails, previews, quickfix export, summary counts, and live section/problem/code/reference navigation
- ambient output skyline HUD with Nerd Font pulse rails, injection, status, and problem signals
- current-section yank action with a short visual pulse in the output buffer
- follow-up prompt drafting from the current output section
- direct `gf` navigation from transcript file references into source
- inline reference highlights with icon signs and right-aligned badges
- context-aware `<Enter>` action for opening transcript references and code blocks
- cursor-aware output action picker for item-specific transcript workflows
- hover-style `K` inspector for output references, code blocks, problems, and sections with winbar status and close keymaps
- cursor-aware code-block yank action that copies fenced output without Markdown fences
- searchable output code-block picker with language-aware previews and scratch buffers
- quickfix export for fenced output code blocks
- code-block scratch buffers with winbar actions, Tree-sitter/filetype status, Tree-sitter scope drafting/navigation, output return, and yank/close keymaps
- animated virtual code-block lenses with language-to-filetype mapping, line count, injection status, and action hints
- searchable output location picker for jumping from transcript file references into source
- quickfix export for transcript file references
- Neovim highlight groups and virtual badges for transcript sections, tools, terminal output, and errors
- tool and terminal virtual headers with activity labels and action hints
- animated tool, terminal, stderr, and file-write activity cards in the output gutter
- sign-column markers for transcript sections, references, code blocks, run status, tools, files, and errors
- native statuscolumn transcript rail with section, code, reference, and problem markers
- right-aligned output timeline badges with section index and transcript progress
- per-section right-aligned summary badges for line, word, and code-block counts
- native output diagnostics and location-list navigation for transcript errors and stderr
- iconized virtual section ribbons for scanning long output without changing transcript text
- ghost-text output hints with live transcript counts, motion badges, and animated busy status
- cursor-sensitive ghost-text action chips for references, code blocks, errors, and sections
- optional Tree-sitter Markdown/code-fence language injection with injected-language ranges, body highlights, and animated injection badges
- floating output outline with progress markers for jumping across long transcripts
- native folds for collapsing transcript sections
- non-blocking adapter startup and session creation
- floating slash-command picker for adapter-advertised commands
- native slash-command and `@workflow` completion in the prompt buffer
- optional `blink.cmp` source for slash-command and `@workflow` prompt completion with scoped labels and documentation
- prompt-buffer session ribbon with linked-source diagnostics, ghost text, and draft statistics while composing
- prompt-focused action picker with source, LSP, Tree-sitter, output, and session workflows
- smart context drafting that combines source, Tree-sitter, diagnostics, and available LSP signals
- floating session config picker for adapter-advertised model, mode, and reasoning options
- per-session prompt history recall
- searchable, previewable plain-text transcript history with section/code/location metrics under Neovim state
- saved transcript replay into a new chat draft
- adapter-backed session listing and restoration with metadata previews
- async LSP code-action picker for drafting focused fix/refactor prompts
- async LSP code-lens picker with source previews and quickfix export
- async LSP document-color picker with source-buffer swatches and quickfix export
- async LSP document-link picker with source badges and quickfix export
- async LSP folding-range picker with structural source overlays and quickfix export
- async LSP prepare-rename draft workflow with a native rename prompt
- async smart-context insertion for source, hover, signature, inlay hints, and semantic ranges
- async LSP hover context insertion for source-cursor documentation
- async LSP signature-help insertion for call-site context
- async LSP inlay-hint picker for hidden type and parameter context
- async LSP selection-range picker for semantic source context
- async LSP incoming/outgoing call-hierarchy pickers with quickfix export
- async LSP supertype/subtype hierarchy pickers with quickfix export
- async LSP document-highlight marks for read/write source occurrences
- async LSP references picker with quickfix export for focused usage context
- async LSP declaration picker with quickfix export for API declaration context
- async LSP definition picker with quickfix export for source-cursor navigation context
- async LSP implementation picker with quickfix export for interface and abstract API context
- async LSP type-definition picker with quickfix export for typed source context
- async LSP workspace-symbol search with quickfix export and source previews
- async LSP document-symbol picker with quickfix export for focused symbol context
- Tree-sitter node picker for adding syntax-aware focused context
- editor context insertion from the source buffer, bounded Tree-sitter node text, LSP clients, and diagnostics
- visual/range context capture for selected code
- source-buffer virtual marks showing the code linked to an open ACP session
- source-buffer diagnostic badges for linked context ranges
- source-context refresh for moving a live session to the current cursor or range
- source-buffer action lens for focusing the linked chat and adding source/LSP/Tree-sitter context
- context and review draft commands for source/Visual-mode workflows
- LSP diagnostic fix drafts from the current buffer or visual range
- quickfix export for source diagnostics from ACP diagnostic workflows
- workspace diagnostics picker across loaded project buffers with source previews and quickfix export
- floating permission chooser with winbar status, highlighted fields, and numbered actions
- floating terminal command approval with command/cwd/output-limit details and live output in tool calls
- floating batch file-write review with winbar status, highlighted diff previews, and apply/cancel keys before edits
- previewed changed-file picker with quickfix export for files written by the agent
- floating diagnostics picker for drafting focused fixes
- floating Markdown input prompt for completion-friendly editing
- native `:checkhealth acp` diagnostics for adapter commands and metadata
- `codex-acp` and `claude-agent-acp` adapter presets
- basic ACP JSON-RPC, session, prompt, permission, terminal, and file read/write support

## Requirements

- Neovim nightly
- An ACP adapter binary on `PATH`
- A Nerd Font in your terminal for the icon UI

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

Optional `blink.cmp` prompt completion:

```lua
require("blink.cmp").setup({
	completion = {
		ghost_text = { enabled = true },
	},
	sources = {
		default = { "lsp", "path", "buffer", "acp" },
		providers = {
			acp = require("acp.blink").provider(),
		},
	},
})
```

The ACP source is enabled only in ACP prompt buffers. Completion items include
workflow or adapter-command scope labels plus plaintext documentation. `<C-Space>`
prefers this source when it is configured and falls back to the native
`completefunc` completion otherwise.

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
- `:AcpOutputMap` opens a persistent floating output map for sections and transcript items
- `:AcpOutputSearch` opens every non-empty output line with context previews
- `:AcpOutputItems` opens references, code blocks, and problems from the current output
- `:AcpOutputItemsQuickfix` sends output references, code blocks, and problems to quickfix
- `:AcpOutputYank` yanks the current output section into the unnamed register
- `:AcpOutputDraft` inserts the current output section as follow-up prompt context
- `:AcpOutputOpen` opens the local file reference or code block under the output cursor
- `:AcpOutputInspect` opens a floating preview for the output item under the cursor
- `:AcpOutputActions` opens cursor-aware actions for the current output item
- `:AcpOutputHelp` opens all output-buffer workflows with a live stats preview
- `:AcpOutputNextItem` / `:AcpOutputPrevItem` jump between output references, code blocks, and problems
- `:AcpCodeBlocks` opens fenced code blocks from the current output with language-aware previews
- `:AcpCodeBlocksQuickfix` sends fenced output code blocks to quickfix
- `:AcpCodeBlockYank` yanks the fenced code block under the output cursor
- `:AcpOutputLocations` opens local file references from the current output with source previews
- `:AcpOutputQuickfix` sends local file references from the current output to quickfix
- `:AcpOutputProblems` opens transcript errors and stderr as native diagnostics in the location list
- `:AcpDiagnostics` opens a picker for source-buffer diagnostics
- `:AcpDiagnosticsQuickfix` sends source-buffer diagnostics to quickfix
- `:AcpWorkspaceDiagnostics` opens diagnostics across loaded project buffers
- `:AcpWorkspaceDiagnosticsQuickfix` sends loaded-buffer diagnostics to quickfix
- `:AcpCommands` opens a picker for slash commands advertised by the current ACP session
- `:AcpConfig` opens a picker for config options advertised by the current ACP session
- `:AcpCodeActions` opens an LSP code-action picker for the source buffer or range
- `:AcpCodeLens` opens an LSP code-lens picker for the source buffer
- `:AcpCodeLensQuickfix` sends LSP code lenses to quickfix
- `:AcpDocumentColors` shows LSP document colors as source-buffer swatches
- `:AcpDocumentColorsQuickfix` sends LSP document colors to quickfix
- `:AcpClearDocumentColors` clears source-buffer document-color swatches
- `:AcpDocumentLinks` opens an LSP document-link picker for the source buffer
- `:AcpDocumentLinksQuickfix` sends LSP document links to quickfix
- `:AcpClearDocumentLinks` clears source-buffer document-link badges
- `:AcpFoldingRanges` opens an LSP folding-range picker for the source buffer
- `:AcpFoldingRangesQuickfix` sends LSP folding ranges to quickfix
- `:AcpClearFoldingRanges` clears source-buffer folding-range overlays
- `:AcpRename` prompts for a new symbol name and drafts an LSP prepare-rename request
- `:AcpSmartContext` inserts source context plus available LSP hover, signature, inlay hints, and semantic ranges
- `:AcpHover` inserts LSP hover documentation for the source cursor
- `:AcpSignature` inserts LSP signature help for the source cursor
- `:AcpInlayHints` opens LSP inlay hints for the source cursor or captured range
- `:AcpSelectionRanges` opens LSP semantic selection ranges for the source cursor
- `:AcpCallers` opens an LSP incoming-call picker for the source cursor
- `:AcpCallersQuickfix` sends incoming LSP calls for the source cursor to quickfix
- `:AcpCallees` opens an LSP outgoing-call picker for the source cursor
- `:AcpCalleesQuickfix` sends outgoing LSP calls for the source cursor to quickfix
- `:AcpSupertypes` opens an LSP supertype picker for the source cursor
- `:AcpSupertypesQuickfix` sends LSP supertypes for the source cursor to quickfix
- `:AcpSubtypes` opens an LSP subtype picker for the source cursor
- `:AcpSubtypesQuickfix` sends LSP subtypes for the source cursor to quickfix
- `:AcpHighlights` shows LSP read/write highlights in the linked source buffer
- `:AcpClearHighlights` clears source-buffer LSP highlight marks
- `:AcpReferences` opens an LSP references picker for the source cursor
- `:AcpReferencesQuickfix` sends LSP references for the source cursor to quickfix
- `:AcpDeclarations` opens an LSP declaration picker for the source cursor
- `:AcpDeclarationsQuickfix` sends LSP declarations for the source cursor to quickfix
- `:AcpDefinitions` opens an LSP definition picker for the source cursor
- `:AcpDefinitionsQuickfix` sends LSP definitions for the source cursor to quickfix
- `:AcpImplementations` opens an LSP implementation picker for the source cursor
- `:AcpImplementationsQuickfix` sends LSP implementations for the source cursor to quickfix
- `:AcpTypeDefinitions` opens an LSP type-definition picker for the source cursor
- `:AcpTypeDefinitionsQuickfix` sends LSP type definitions for the source cursor to quickfix
- `:AcpWorkspaceSymbols [query]` opens an LSP workspace-symbol picker; without a query it uses the source cursor word
- `:AcpWorkspaceSymbolsQuickfix [query]` sends LSP workspace symbols to quickfix
- `:AcpSymbols` opens an LSP document-symbol picker for the source buffer
- `:AcpSymbolsQuickfix` sends LSP document symbols for the source buffer to quickfix
- `:AcpTreeSitter` opens a Tree-sitter node picker for the source cursor
- `:AcpHistory` opens saved transcript history with transcript metrics
- `:AcpRestore [adapter]` lists adapter-backed sessions with metadata previews and restores the selected session
- `:AcpHistoryDraft [adapter]` opens saved transcript history and drafts a new chat from the selected transcript
- `:AcpAddContext` inserts source-buffer context into the current prompt
- `:AcpRefreshSource` updates the linked source context to the current cursor or range
- `:AcpFixDiagnostics [adapter]` opens chat with a diagnostics-focused draft prompt
- `:AcpHealth [adapter]` checks the adapter command and prompt metadata wiring
- `:checkhealth acp` checks configured adapter commands and prompt metadata wiring

In the sessions panel:

- session rows show status, changed-file count, transcript counts, and linked source context when available
- `<Enter>` focuses the session under the cursor
- `x` closes the session under the cursor
- `<leader>ak` opens the ACP action palette

In the prompt buffer:

- prompts show a virtual session ribbon with adapter, model, status, linked-source diagnostics, source, and blink-completion state
- empty prompts show ghost-text workflow hints for actions and `@context` completion; non-empty prompts show draft stats
- `?` opens composer-focused actions with source context preview
- `<Enter>` inserts a newline
- `<C-Enter>` sends the prompt
- `<C-s>` also sends the prompt as a terminal-compatible fallback
- `<M-p>` / `<M-n>` recall previous/next prompts for the current session
- `<C-Space>` opens blink/native ACP prompt completion for slash commands and `@context`/`@smart-context`/`@diagnostics`/`@workspace-diagnostics`/`@code-lens`/`@colors`/`@links`/`@folds`/`@rename`/`@signature`/`@inlay-hints`/`@selection`/`@callers`/`@callees`/`@supertypes`/`@subtypes`/`@output` workflows
- `<leader>ac` inserts source-buffer context into the prompt
- `<leader>ax` searches output transcript lines
- `<leader>am` opens a persistent output map with progress rails, item counts, previews, and quickfix export
- `<leader>aO` opens output references, code blocks, and problems
- `<leader>ay` yanks the current output section
- `<leader>ai` inserts the current output section as follow-up prompt context
- `<leader>av` opens the output outline
- `<leader>ab` opens output code blocks
- `<leader>aB` sends output code blocks to quickfix
- `<leader>aY` yanks the code block under the cursor
- `<leader>ag` opens output file references
- `<leader>ae` opens output errors/stderr in the location list
- `<leader>ad` opens source-buffer diagnostics
- `<leader>aD` sends source-buffer diagnostics to quickfix
- `<leader>af` previews the current session's changed files
- `<leader>a/` opens advertised ACP slash commands
- `<leader>ao` opens advertised ACP config options
- `<leader>ak` opens the ACP action palette
- `<leader>aa` opens source-buffer LSP code actions
- `<leader>ah` inserts source-buffer LSP hover documentation
- `<leader>aH` shows source-buffer LSP read/write highlights
- `<leader>ar` opens source-buffer LSP references
- `<leader>aR` sends source-buffer LSP references to quickfix
- `<leader>aC` opens source-buffer LSP declarations
- `<leader>aG` opens source-buffer LSP definitions
- `<leader>aI` opens source-buffer LSP implementations
- `<leader>aT` opens source-buffer LSP type definitions
- `<leader>aw` opens LSP workspace symbols for the source cursor word
- `<leader>al` opens source-buffer LSP symbols
- `<leader>aL` sends source-buffer LSP symbols to quickfix
- `<leader>at` opens source-buffer Tree-sitter nodes

In the output buffer:

- the current line shows a virtual context ribbon with transcript progress, section span, and current/nearby output item
- the current line shows ghost-text action chips for references, code blocks, errors, and sections
- fenced code blocks show injected-language badges, body highlights, and animated motion markers
- `]]` jumps to the next transcript section
- `[[` jumps to the previous transcript section
- `]o` / `[o` jump between output references, code blocks, and problems
- `za` toggles the fold under the cursor
- `zM` closes all transcript folds
- `zR` opens all transcript folds
- `?` opens cursor-aware actions for the current output item
- `<leader>a?` opens all output-buffer workflows with a live stats preview
- `<Enter>` opens the local file reference or code block under the cursor
- `K` previews the reference, code block, problem, or section under the cursor
- `gf` opens the local file reference under the cursor
- `<leader>ax` searches output transcript lines
- `<leader>am` opens a persistent output map; inside it, `K` previews an entry and `Q` exports entries to quickfix
- `<leader>aO` opens output references, code blocks, and problems
- `<leader>ay` yanks the current output section
- `<leader>ai` inserts the current output section as follow-up prompt context
- `<leader>av` opens the output outline
- `<leader>ab` opens output code blocks
- `<leader>aY` yanks the code block under the cursor
- `<leader>ag` opens output file references
- `<leader>ae` opens output errors/stderr in the location list
- `<leader>aD` sends source-buffer diagnostics to quickfix
- `<leader>ak` opens the ACP action palette
- `<leader>az` toggles the fold under the cursor

In code-block scratch buffers:

- `<leader>at` opens a Tree-sitter scope picker for the code under the cursor
- `<leader>ai` drafts the current Tree-sitter scope, or the whole code block, into the ACP prompt
- `gO` returns to the originating output code block
- `<leader>aY` yanks the entire code block
- `q` closes the scratch tab

In floating ACP pickers:

- picker winbars show the active title, row counts, filter query, and core keys
- `/` filters visible picker rows and shows the active match count
- `<C-l>` clears the active picker filter
- source-backed pickers show a live preview beside the picker
- action pickers show a live workflow preview with scope, key, and detail metadata
- changed-file, diagnostics, workspace-diagnostics, LSP-code-lens, LSP-call-hierarchy, LSP-reference, LSP-declaration, LSP-definition, LSP-implementation, LSP-type-definition, LSP-workspace-symbol, LSP-symbol, output-location, output-code-block, and output-item pickers use `Q` to export rows to quickfix
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
