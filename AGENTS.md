# AGENTS.md

## Repository expectations

- This is a Neovim plugin. Keep runtime code under `lua/acp/` and plugin loading code under `plugin/`.
- Keep ACP adapter behavior owned by this plugin. In particular, Codex metadata detection belongs in `lua/acp/`, not in a user's Neovim dotfiles.
- Prefer small, local Lua modules over growing `lua/acp/ui.lua` when adding reusable helpers.
- After changing Lua code, run:

  ```sh
  NVIM_LOG_FILE=/tmp/acp.nvim-nvim.log nvim --headless -u tests/minimal_init.lua -c "luafile tests/acp_spec.lua" -c "qa!"
  ```
