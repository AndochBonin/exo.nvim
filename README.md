# Exo

Neovim workflow for working with AI — meant to improve speed while still maintaining control

<<<<<<< HEAD
## Setup

Reviews run through a local OpenCode server (`opencode serve` on `localhost:4096`).
The review focuses on your highlighted selection but is allowed to read the rest
of the project for context. To grant that read-only access, add an `exo-review`
agent to your OpenCode config (project or global `opencode.json`):

```json
{
  "agent": {
    "exo-review": {
      "permission": { "*": "allow", "edit": "deny" }
    }
  }
}
```

The wildcard allows every tool (so any project-specific tooling works) while
`edit` (which covers `edit`/`write`/`patch`) is denied, guaranteeing a review can
never modify your files.

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
