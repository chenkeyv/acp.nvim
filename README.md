# acp.nvim

Minimal Agent Client Protocol client for Neovim.

This plugin provides an editor-native ACP chat surface:

- dedicated ACP tab by default
- output buffer for streamed agent responses
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

## Commands

- `:AcpChat [codex|claude_code]` opens the default dedicated tab layout
- `:AcpChatTab [adapter]` opens the dedicated tab layout
- `:AcpChatFloat [adapter]` opens a floating output/input layout
- `:AcpChatWindow [adapter]` opens a split-window layout
- `:AcpSend` sends the current prompt
- `:AcpStop` stops the current agent process
- `:AcpHealth [adapter]` checks whether the adapter command is available

In the prompt buffer:

- `<Enter>` inserts a newline
- `<C-Enter>` sends the prompt
- `<C-s>` also sends the prompt as a terminal-compatible fallback

## Status

This is an early minimal ACP client. Terminal operations, session switching, and
rich diff approval UI are not implemented yet.
