# AGENTS.md

Neovim plugin (Lua) that sends a visual selection to a local OpenCode server for AI code review (`<leader>er`) or explanation (`<leader>ee`), rendering results as extmarks and quickfix entries.

## Verify (no test suite)

There are no tests, linter, formatter, or CI configs in this repo. Verification is:

```sh
nvim --headless "+lua require('exo'); print('ok')" +qa   # modules load without error
```

plus manually exercising `:ExoReview` / `:ExoExplain` in a real Neovim session against a running `opencode serve --port 4096` (and `ollama serve` for the default model).

## Architecture

- `plugin/load_exo.lua` — defines `:ExoReview` `:ExoExplain` `:ExoDeleteMark` `:ExoPrevMark` `:ExoNextMark` (lazy-require on invocation). Keymaps (`<leader>e*`) are created inside `lua/exo.lua` `setup()`, not at load.
- `lua/exo.lua` — hub: config defaults, highlight groups, keymaps, `VimLeavePre` server shutdown. All features go through it.
- Flow for review and explain: `lua/server.lua` `ensure_ready` (ping `/session`; if down, spawn `start_command` and poll) → `lua/ai.lua` `get_opencode_response` (POST `/session`, then POST `/session/<id>/message`, then DELETE the session). Responses come back as structured output (`json_schema` + `retryCount`); per-feature schemas, system prompts, and response parsers live in `ai.lua`. `review.lua` inserts comment lines into the buffer; `explain.lua` saves to a file via `store.lua`.
- `lua/nav.lua` / `lua/marks.lua` — extmark placement/jump/delete in namespace `exoskeleton`.

## Gotchas

- Modules are required by **bare names** (`require("review")`, `require("ai")`) because files sit flat in `lua/` — not `require("exo.review")`. Keep that convention; the flat generic names (`ai`, `server`, `store`, `nav`, `util`) can also collide with other plugins' modules.
- `plenary.nvim` (`plenary.curl`) is a hard dependency but declared nowhere — no plugin manifest exists.
- `opencode_url` and `start_command` are independent config values; changing one port requires changing both. `setup()` replaces `start_command` wholesale on purpose (`tbl_deep_extend` would splice a shorter list onto the default's tail).
- OpenCode config **must** define the provider plus `exo-review` and `exo-explain` agents. A missing agent surfaces as an opaque `500 UnknownError` — OpenCode throws before reaching a model. Errors show a short notification; the full response body is echoed into `:messages`.
- The plugin only kills the OpenCode server it started itself (`started_by_us` guard in `server.lua`); never change that behavior.
- `exo-explanations/` is **generated output** (explain results written to the git root, auto-added to `.git/info/exclude` by `store.lua`) — do not treat it as docs to maintain or commit it.

## Git

Default branch is `dev`; changes go through PRs. Working tree may contain uncommitted WIP — check `git status` before assuming file contents are committed/stable.
