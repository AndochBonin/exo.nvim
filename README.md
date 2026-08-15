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
  ready_timeout_ms = 10000, -- how long to wait for the server to come up
  poll_interval_ms = 250,
})
```

### Required OpenCode config

Your OpenCode config (`~/.config/opencode/opencode.json`, or a project
`opencode.json`) **must** define both the model provider Exo reviews with and an
`exo-review` agent. If the `exo-review` agent is missing, the review fails with an
opaque `500 UnknownError` from the server — OpenCode throws before it ever reaches
a model, so the notification/error buffer won't spell out the cause.

A complete config (Ollama provider + the review agent) looks like:

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
    }
  }
}
```

The review focuses on your highlighted selection but is allowed to read the rest
of the project for context: the wildcard permission allows every tool (so any
project-specific tooling works) while `edit` (which covers `edit`/`write`/`patch`)
is denied, guaranteeing a review can never modify your files. The provider/model
must match `ai_model` in `setup` (default `ollama/devstral-small-2`), and that
model must be reachable (e.g. `ollama serve` running).

## Review (visual mode): &lt;leader&gt; er
- Review the visually selected code section. Leaves an extmark labelled "review in progress" at the review site for easy navigation (see below).
- After review comments are left at the review site, extmark label changes to "good" / "okay" / "poor" denoting the quality of the reviewed code.

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
