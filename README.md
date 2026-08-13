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
- one host-relative vertical stack of chat, turn/status, and prompt floats, with
  tool-aware chat styling and icons
- streamed agent messages and plans
- Codex CLI-style command, tool, exploration, and file-change cells
- model and reasoning-effort selectors from the server catalog
- token usage, turn status, interruption, and follow-up queueing or steering
- current-file and visual/range context
- command, file-change, and permission-profile approval prompts
- Codex `request_user_input` questions and basic MCP elicitation when enabled
  by the server's negotiated capabilities
- review, context compaction, login, and a read-only unified diff view
- Blink completion in the prompt for Codex commands, skills, installed apps,
  workspace files, loaded-buffer words, paths, and dictionaries
- transactional Lua hot reloads that preserve the Codex process, thread, tab,
  prompt draft, and active turn

Codex app-server owns command execution, file changes, sandboxing, and policy.
This plugin sends prompts/editor context and displays the server's events and
approval requests; it does not implement a second filesystem or terminal tool
runner.

## Requirements

- Neovim nightly 0.13-dev or newer; stable releases are intentionally unsupported
- a recent Codex CLI on `PATH`
- an authenticated Codex session (`codex login` or `:AcpLogin`)
- [blink.cmp](https://github.com/Saghen/blink.cmp) for prompt completion

The included ACP Tree-sitter grammar is optional. With `nvim-treesitter` on the
runtime path, acp.nvim registers its local parser. Run `:AcpInstallParser` to
compile or update it from the grammar bundled with the plugin. Chats retain the
`acp` filetype without it, but transcript and injected-language highlighting are
disabled until the ACP parser is available.

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
		instruction_height = 4,
		sessions_width = 30,
	},
	performance = {
		stream_interval_ms = 25,
		semantic_debounce_ms = 200,
		cursor_interval_ms = 16,
	},
})
```

`command = "codex"` is also accepted and expands to the default app-server
command. A command table is used exactly as supplied.

The sessions list remains a native left split. On the right, a blank normal host
owns three sibling floats stacked vertically: the borderless chat, the compact
borderless turn panel, and the bordered prompt. This leaves the prompt as the
stack's only visible border. The surfaces never overlap, so
the transcript contains no composer-protection spacer rows. One host-relative
geometry keeps their widths and edges aligned as the tab resizes.
`input_height` includes the prompt frame, while `input_padding` controls the
vertical gap below the stack. A blank two-column native gutter pads transcript
text without showing fold or sign markers. Model, reasoning, remaining-context
percentage and window size, and attached-context metadata sit on the prompt's
lower-left border, while the send and steer hints remain on the lower-right.
Model/reasoning and remaining context are kept ahead of other metadata and key
hints when space is tight. A blank top row separates the turn content from the
chat, while the current status stays anchored to the bottom and steer or queued
follow-ups fill upward immediately above it. The panel grows with its content up
to `instruction_height`, including the spacer and status rows; pending entries
expand and collapse it without changing its width. The active status icon spins
in place during a turn and stops on completion, error, close, or reload. Queued
entries disappear when their turn starts, while steer entries disappear when the
continuation begins producing output. Transient status and queue details stay in
this panel instead of being repeated elsewhere.

The chat transcript uses the custom `acp` filetype rather than Markdown, while
the editable prompt uses `acp-prompt`. This keeps their styling and filetype
options independent and lets `FileType acp` customizations target only chats.
Semantic icons for people, tools, changes, warnings, and errors are written
directly into the transcript text. The chat therefore needs no sign column or
icon-bearing extmarks; set `vim.g.have_nerd_font = false` to write compact text
fallbacks instead. acp.nvim does not attach Neovim diagnostics to the chat
buffer, so warnings and errors remain ordinary native transcript cells without
diagnostic underlines, signs, or virtual text.

ANSI-decorated app-server log messages are normalized before they enter the
transcript. Transport timestamps remain block metadata, while log levels,
module names, escaped multiline messages, and common process-error wrappers
become native notice, warning, or error blocks. Failures already represented by
command or tool action cells are not repeated as server-log blocks.

The visible chat remains one native buffer, backed by ordered logical blocks
for user prompts, agent responses, plans, individual actions, notices, warnings,
and errors. Top-level cells have one blank separator, matching the compact Codex
CLI rhythm, while the tree rows inside an action remain contiguous. Fenced code
is indexed as a child of its owning prompt or response. Every live row carries
an explicit role, action span, owning block, and semantic range; navigation,
search, previews, folds, diagnostics, and highlights consume that structure
directly. Rendered transcript text is never reparsed into chat structure. File
references and inline code remain lexical leaf detection because the app server
delivers them inside prose, but they never determine chat ownership or cell
boundaries.

The repository ships a lightweight `acp` Tree-sitter grammar and queries for
role headers, command/tool/exploration cells, tree branches, and fenced-code
injection. The logical block model remains authoritative: Tree-sitter adds idle
syntax control and language injection but never reconstructs streaming state
from rendered text.

Large transcripts use indexed block lookup and cache references, code blocks,
and problem metadata per logical block, plus one model-wide semantic snapshot for
each transcript revision. During a response, streamed deltas are
coalesced at `stream_interval_ms`; each flush replaces only the active block's
tail and refreshes decorations only through that block. Unchanged history is
not reparsed, the ACP parser and language injection remain paused until the
turn ends, and typing or scrolling can defer the final semantic refresh by
`semantic_debounce_ms`. Cursor-only updates are capped by `cursor_interval_ms`.
Every transcript mutation returns the chat to its final line, so manual
scrolling remains available only until the next content update arrives.
The chat window disables editor indent guides and wrapped-line indentation, and
the output and sessions buffers keep no undo history. Each command or tool gets
one level-two Codex-style cell; compatible read/list/search commands coalesce
under a single `Exploring` or `Explored` cell. Multiline command, MCP, and
dynamic-tool content shows its first row, a `... +N lines` omission marker, and
its final three rows. Shell-command rows remain complete and wrap to the current
chat-window width; command output and tool previews shorten past 120 display
columns. The same policy applies while a command is streaming and after it
completes. `<Enter>` or `K` opens the complete command or tool transcript in a
focused detail float. Action previews start open and remain manually foldable;
warnings and failures stay visible in the transcript.

Command cells apply live Bash token highlighting even while ACP language
injection is paused during a turn. Exploration verbs and tool methods use
distinct Search, Read, List, and Edit highlights; file-change verbs use Edit.
Untyped command and action text keeps the editor's normal text color. These
structural highlights do not depend on the optional ACP parser.

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
| `:AcpOutput`, `:AcpOutputSearch`, `:AcpOutputMap` | Open the transcript outline, searchable lines, or persistent live map |
| `:AcpOutputItems[Quickfix]` | Browse references, code blocks, and problems or export them to quickfix |
| `:AcpOutputOpen`, `:AcpOutputInspect`, `:AcpOutputActions` | Open, preview, or choose actions for the item under the chat cursor |
| `:AcpOutputYank`, `:AcpOutputDraft` | Yank or draft a follow-up from the current transcript section |
| `:AcpOutputNextItem`, `:AcpOutputPrevItem` | Move between references, code blocks, and problems |
| `:AcpCodeBlocks[Quickfix]` | Browse fenced code blocks or export them to quickfix |
| `:AcpCodeBlockYank`, `:AcpCodeBlockDraft` | Yank or draft the fenced block under the cursor |
| `:AcpOutputLocations`, `:AcpOutputQuickfix` | Browse local transcript references or export them to quickfix |
| `:AcpOutputProblems` | Open transcript errors and warnings in the location list |
| `:AcpOutputHelp` | Open the cursor-aware transcript workflow selector |
| `:AcpActions` | Open the native action selector |
| `:AcpLogin` | Inspect account state or start ChatGPT login |
| `:AcpInstallParser` | Compile or update the optional ACP Tree-sitter parser |
| `:AcpSend` | Send the prompt buffer |
| `:AcpStop` | Interrupt the active turn |
| `:AcpClose` | Close the Codex tab without stopping app-server |
| `:AcpReload` | Reload plugin Lua while preserving the current Codex session and tab |

The prompt also accepts `/model`, `/reasoning`, `/review`, `/compact`,
`/status`, `/clear [name]`, `/new`, `/threads`, `/login`, and `/reload`.
`/clear` resets the visible transcript and starts a fresh chat in the same ACP
tab; an optional name is applied to the new thread. Like `/new`, it is disabled
while a turn is active.

With Blink installed, completion opens automatically after `/`, `$`, and `@`:

- `/` lists the current documented Codex command catalog plus acp.nvim's local
  prompt commands.
- `$` lists enabled skills from `skills/list` and callable installed apps from
  `app/installed`.
- `@` searches the active Codex workspace through `fuzzyFileSearch` and sends
  accepted files or directories as structured mentions.
- ordinary words retain Blink's configured sources. acp.nvim explicitly keeps
  the built-in buffer and path sources enabled for `acp-prompt`; buffer words
  come from all loaded, listed file buffers and paths resolve from the Codex
  workspace rather than the prompt buffer's `acp://` name.
- dictionary words come from the prompt buffer's `'dictionary'` files. When
  none are configured, macOS's `/usr/share/dict/words` is used when available.

Blink remains optional at runtime: the prompt still sends normally when it is
not installed, but none of these completion menus are available.

Codex tab keymaps:

- `<C-s>` starts a turn when idle or steers the active turn
- `<C-CR>` sends from the prompt, using `follow_up` when a turn is active
- `i` focuses the prompt from output
- `n`, `t`, `d`, `m`, `r`, and `s` select new chat, sessions, diff, model,
  reasoning, and stop from output
- `]]` / `[[` move between transcript sections; `]o` / `[o` move between
  action cells, references, code blocks, and problems
- `<Enter>` opens the item under the cursor and `K` previews it; on a command or
  tool cell either key shows its complete output in a floating detail window.
  `gf` opens a local file reference and `?` opens context-aware actions
- `za`, `zM`, and `zR` toggle, close, and open the native transcript folds
- `<leader>ax`, `<leader>am`, `<leader>aO`, and `<leader>av` open transcript
  search, the persistent output map, unified items, and the section outline
- `<leader>ay` / `<leader>ai` yank or draft the current section;
  `<leader>ab` / `<leader>aB` browse or quickfix code blocks, and
  `<leader>aY` yanks the current block
- `<leader>ag` opens local output references and `<leader>ae` opens transcript
  problems in the location list; `<leader>az` toggles the current fold
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

Run `:checkhealth acp` to verify Neovim, the Codex executable, direct app-server
configuration, and ACP Tree-sitter parser status.

```sh
NVIM_LOG_FILE=/tmp/acp.nvim-nvim.log nvim --headless -u tests/minimal_init.lua \
  -c "luafile tests/acp_spec.lua" -c "qa!"

XDG_CACHE_HOME=/tmp/acp-tree-sitter-cache tree-sitter test \
  --grammar-path tree-sitter-acp
```
