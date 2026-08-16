# Exo

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
  ai_model = "ollama/devstral-small-2",
  review_agent = "exo-review",
  explain_agent = "exo-explain",
  ready_timeout_ms = 10000, -- how long to wait for the server to come up
  poll_interval_ms = 250,
})
```

### Required OpenCode config

Your OpenCode config (`~/.config/opencode/opencode.json`, or a project
`opencode.json`) **must** define the model provider Exo uses plus an `exo-review`
agent (for reviews) and an `exo-explain` agent (for explanations). If a referenced
agent is missing, the request fails with an opaque `500 UnknownError` from the
server — OpenCode throws before it ever reaches a model, so the notification/error
buffer won't spell out the cause.

A complete config (Ollama provider + both agents) looks like:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama",
      "options": { "baseURL": "http://localhost:11434/v1" },
      "models": { "devstral-small-2": { "name": "devstral-small-2" } }
    }
  },
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
context; explain may read the project and search the web. The provider/model must
match `ai_model` in `setup` (default `ollama/devstral-small-2`), and that model
must be reachable (e.g. `ollama serve` running).

## Review (visual mode): &lt;leader&gt; er
- Review the visually selected code section. Leaves an extmark labelled "review in progress" at the review site for easy navigation (see below).
- After review comments are left at the review site, extmark label changes to "good" / "okay" / "poor" denoting the quality of the reviewed code.

## Explain: &lt;leader&gt; ee
- Opens a centered floating window with a text input field. When you trigger it
  from a visual selection, the window shows the selection details (file name,
  start/end rows); it also shows a disclaimer that explain mode is read-only and
  will not edit your files. Explain also works from normal mode with no selection
  (a general question).
- Type your question and press Enter. The window closes and, if you had a
  selection, an extmark labelled "Explaining" is left at the selection site.
- The agent explains your question in the context of the project (and may search
  the web). When it finishes, the explanation is loaded into the quickfix list
  (open it with `:copen`), a notification fires, and the extmark changes to
  "Explanation Complete: :copen to read".

## List extmarks (normal mode): &lt;leader&gt; el
- Vim notification showing extmark ids and line positions

## Jump to extmark (normal mode): &lt;leader&gt; e[1-9]
- Jumps to the provided extmark id - only works for 1-9 range (if you have more extmarks than that you need to start dealing with your code reviews)

## Previous extmark (normal mode): &lt;leader&gt; ep
- Jumps to the closest extmark above the cursor

## Next extmark (normal mode): &lt;leader&gt; en
- Jumps to the closest extmark below the cursor

## Delete extmark(s) (normal mode): &lt;leader&gt; ed
- Deletes all extmarks on the cursor line

## maybe some more
- explain, document, complete, etc
