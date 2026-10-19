# Exo

(README is ai generated)
Neovim workflow for working with AI — meant to improve speed while still maintaining control

## Setup

Reviews run through a local OpenCode server (`opencode serve` on `localhost:4096`).
If no server is reachable when you start a review, Exo starts one for you using
`start_command` (default `opencode serve --port 4096`), waits for it to become
ready, then runs the review. A server Exo started is stopped when you quit
Neovim; a server you started yourself is left running.

Overrides are passed to `setup`:

```lua
require("exo").setup({
  opencode_url = "http://localhost:4096",
  -- Keep start_command in sync with opencode_url's port.
  start_command = { "opencode", "serve", "--port", "4096" },
  review_model = "opencode-go/deepseek-v4-flash",
  explain_model = "opencode-go/deepseek-v4-flash",
  review_agent = "exo-review",
  explain_agent = "exo-explain",
  ready_timeout_ms = 10000, -- how long to wait for the server to come up
  poll_interval_ms = 250,
  -- Remap the theme group any Exo highlight derives from. Badge groups are
  -- white text over the source group's fg; the float groups link directly.
  highlights = {
    review_good = "DiagnosticOk",
    explain_complete = "DiagnosticHint",
    explain_text = "Comment",
  },
})
```

### Highlights

Exo's labels follow your colorscheme instead of hardcoding colors:

- **Badges** (`ExoReviewGood`/`Okay`/`Poor`, `ExoReviewInProgress`,
  `ExoExplainInProgress`, `ExoExplainComplete`, `ExoRequestFailed`) — white text
  on the fg color of a theme group (`DiagnosticOk`/`Warn`/`Error`/`Info`/`Hint`
  by default). If the theme doesn't define the source group, the previous fixed
  color is used.
- **Explain float** (`ExoExplainTitle`, `ExoExplainText`) — link to
  `FloatTitle` and `Comment`.

Every source is overridable via `setup({ highlights = { ... } })` with the keys
`review_good`, `review_okay`, `review_poor`, `review_in_progress`,
`explain_in_progress`, `explain_complete`, `request_failed`, `explain_title`,
`explain_text`.
Colors re-derive automatically when you switch `:colorscheme`.

### Required OpenCode config

Models come from a provider connected to your OpenCode install — e.g. opencode go
via `opencode auth login`. Known providers need no `provider` block in the config;
run `opencode models` to list the exact `provider/model` IDs you can use.

Your OpenCode config (`~/.config/opencode/opencode.json`, or a project
`opencode.json`) **must** define an `exo-review` agent (for reviews) and an
`exo-explain` agent (for explanations). If a referenced agent is missing, the
request fails with an opaque `500 UnknownError` from the server — OpenCode throws
before it ever reaches a model, so the notification/error buffer won't spell out
the cause.

A complete config (both agents) looks like:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "agent": {
    "exo-review": {
      "permission": { "*": "allow", "edit": "deny" }
    },
    "exo-explain": {
      "permission": { "*": "allow", "edit": "deny" }
    }
  }
}
```

Both agents are read-only: the wildcard permission allows every tool (so any
project-specific tooling — including a web-search/`webfetch` tool, which explain
relies on — works) while `edit` (which covers `edit`/`write`/`patch`) is denied,
guaranteeing neither a review nor an explanation can modify your files. Review
focuses on your highlighted selection but may read the rest of the project for
context; explain may read the project and search the web. The `provider/model`
IDs must match `review_model` / `explain_model` in `setup` (default
`opencode-go/deepseek-v4-flash` for both), and the provider must be authenticated
(e.g. your opencode go key connected via `opencode auth login`).

## Review (visual mode): &lt;leader&gt; er
- Review the visually selected code section. Leaves an extmark labelled "review in progress" at the review site for easy navigation.
- When the response is ready, the extmark label changes to "good" / "okay" / "poor" and the response is available by pressing `<CR>` on its line.
- Review text is not inserted automatically. From the response float, press `i` to insert it as inline comments or `f` to save it under `exo-reviews/`.
- If review generation fails, its mark is retained as `Request failed` and the error is reported normally.

## Explain: &lt;leader&gt; ee
- Opens a centered floating window with a text input field. When you trigger it
  from a visual selection, the window shows the selection details (file name,
  start/end rows); Explain also works from normal mode with no selection (a general question).
- Type your question and press Enter. The window closes and an extmark labelled
  "Explaining" is left at the selection site or the original cursor line.
- The agent explains your question in the context of the project (and may search
  the web). When it finishes, the explanation is loaded into the quickfix list
  (open it with `:copen`), a notification fires, and the extmark changes to
  "Explanation Complete".
- The response is available by pressing `<CR>` on the extmark's line. From the response float, press `f` to save it under `exo-explanations/`; explanations without a selection cannot be inserted as inline comments.
- If explanation generation fails, its mark is retained as `Request failed` and the error is reported normally.

## Response float
- Press `<CR>` on a completed Exo extmark to open its read-only response float. If multiple responses share the line, choose one from the selection menu.
- Press `i` to save the response as inline comments, `f` to save it as a Markdown file, or `q` / `<Esc>` to close the float.
- Inline comments are inserted above the extmark and use the buffer's `commentstring`. The response body is used as-is, one commented line per response line.
- Saving closes the float but keeps the extmark and response available.

## Previous extmark (normal mode): &lt;leader&gt; ep
- Jumps to the closest extmark above the cursor

## Next extmark (normal mode): &lt;leader&gt; en
- Jumps to the closest extmark below the cursor

## Delete extmark(s) (normal mode): &lt;leader&gt; ed
- Deletes all extmarks on the cursor line
- Deleting a review or explanation mark while it is in progress silently cancels the AI request and all of its result side effects. The OpenCode server remains available for other operations.

## maybe some more
- complete, etc
