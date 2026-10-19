# AGENTS.md

Neovim plugin (Lua) that sends a visual selection to a local OpenCode server for AI code review (`<leader>er`) or explanation (`<leader>ee`), rendering results as extmarks and quickfix entries.

## Verify (no test suite)

There are no tests, linter, formatter, or CI configs in this repo. Verification is:

```sh
nvim --headless "+lua require('exo'); print('ok')" +qa   # modules load without error
```

plus manually exercising `:ExoReview` / `:ExoExplain` in a real Neovim session against a running `opencode serve --port 4096` (models come from an authenticated provider — opencode go by default, so no local model server is needed).

## Architecture

- `plugin/load_exo.lua` — defines `:ExoReview` `:ExoExplain` `:ExoDeleteMark` `:ExoPrevMark` `:ExoNextMark` (lazy-require on invocation). Keymaps (`<leader>e*`) are created inside `lua/exo.lua` `setup()`, not at load.
- `lua/exo.lua` — hub: config defaults, highlight groups, keymaps, `VimLeavePre` server shutdown. All features go through it.
- Flow for review and explain: `lua/server.lua` `ensure_ready` (ping `/api/session`; if down, spawn `start_command` and poll) → `lua/ai.lua` `get_opencode_response` drives the OpenCode **v2** session API: `POST /api/session` (id is `data.id` — every v2 body is wrapped in `{data:...}`), then `POST /api/session/<id>/agent` and `/model` to select, then `POST /api/session/<id>/prompt` (asynchronous — it schedules the agent loop and returns the queued user message, not the reply), then poll `GET /api/session/<id>/message` until an `idle` message appears (`outcome` succeeded|failed|interrupted; the message list is newest-first), then DELETE the session. v2 has **no `json_schema`/structured-output**: the system prompt (which asks for a strict JSON object) is prepended to the prompt text, and the assistant's reply text is parsed with `parse_json_object` (first `{` … last `}`), with a per-feature fallback (review → whole reply as the comment; explain → first line = title, rest = body). The v2 HTTP API is under the `/api` prefix and requires HTTP Basic auth — `build_headers` reads the password from `$OPENCODE_SERVER_PASSWORD` (the same var `opencode serve` uses to enable auth; falls back to `$OPENCODE_PASSWORD`, username from `$OPENCODE_SERVER_USERNAME` default `opencode`). Export it in the shell that launches Neovim so both the plugin and a plugin-started server see the same value. Per-feature system prompts and parsers live in `ai.lua`. `review.lua` and `explain.lua` store completed responses against their extmarks; `response.lua` displays them in read-only floats and handles explicit inline/file export via `store.lua`.
- Explain's prompt float is **two stacked windows** in `explain.lua` forming one coherent box: a `focusable = false`, non-modifiable header buffer (rounded border, ` Explain ` title on top) above the input buffer, whose all-`─` top border overdraws the header's bottom border to form a flat divider (sides break at it — no junction glyphs). A `WinClosed` autocmd on the input window closes the header no matter how the input is closed, and closing always runs `stopinsert` so any exit path (`:q`, second `<Esc>`, `<C-w>c`, Enter) lands in normal mode; the first `<Esc>` in insert mode only enters normal mode. Both windows share `width = max(header natural width, input natural width)` and the input buffer's whole content is the prompt.
- Float geometry gotchas (verified on nvim 0.12): `row`/`col` anchor the window's **outer frame including borders**, and 8-element `border` arrays are applied in **clockwise ring order** (`topleft, top, topright, right, bottomright, bottom, bottomleft, left`) — not the old `{top, right, bottom, left, corners}` order. Overlapping same-zindex floats don't reliably overdraw each other; use explicit `zindex`.
- `lua/nav.lua` / `lua/marks.lua` — extmark placement/jump/delete in namespace `exoskeleton`.
- Highlights: `exo.lua` derives badge groups (white fg) from `Diagnostic*` fg colors and links the float groups to `FloatTitle`/`Comment`; re-derived on every `ColorScheme` event. Sources are per-key overridable via `setup({ highlights = ... })`, including the shared `request_failed` badge.

## Gotchas

- Modules are required by **bare names** (`require("review")`, `require("ai")`) because files sit flat in `lua/` — not `require("exo.review")`. Keep that convention; the flat generic names (`ai`, `server`, `store`, `nav`, `util`) can also collide with other plugins' modules.
- `plenary.nvim` (`plenary.curl`) is a hard dependency but declared nowhere — no plugin manifest exists.
- `opencode_url` and `start_command` are independent config values; changing one port requires changing both. `setup()` replaces `start_command` wholesale on purpose (`tbl_deep_extend` would splice a shorter list onto the default's tail).
- Review and explain each have their own model key (`review_model` / `explain_model`, both default `opencode-go/deepseek-v4-flash`); there is no shared `ai_model`. Model IDs must exist in the connected provider — run `opencode models` for exact IDs.
- OpenCode config **must** define the `exo-review` and `exo-explain` agents; models come from the authenticated provider (no `provider` block needed for known providers). A missing agent surfaces as an opaque `500 UnknownError` — OpenCode throws before reaching a model. Errors show a short notification; the full response body is echoed into `:messages`.
- The plugin only kills the OpenCode server it started itself (`started_by_us` guard in `server.lua`); never change that behavior.
- `exo-explanations/` is **generated output** (explain results written to the git root, auto-added to `.git/info/exclude` by `store.lua`) — do not treat it as docs to maintain or commit it.

## Git

Default branch is `dev`; changes go through PRs. Working tree may contain uncommitted WIP — check `git status` before assuming file contents are committed/stable.
