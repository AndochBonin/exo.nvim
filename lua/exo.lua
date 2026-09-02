local M = {}
local NS = nil
local SERVER = require("server")

-- User-overridable configuration (see `M.setup`). Note: `opencode_url` and
-- `start_command` are independent — if you change the URL/port, update
-- `start_command` to match so the auto-started server binds where we connect.
local config = {
    review_model = "opencode-go/gpt-5.6-luna",
    explain_model = "opencode-go/gpt-5.6-luna",
    opencode_url = "http://localhost:4096",
    review_agent = "exo-review",
    explain_agent = "exo-explain",
    start_command = { "opencode", "serve", "--port", "4096" },
    ready_timeout_ms = 10000,
    poll_interval_ms = 250,
    -- How many times OpenCode re-asks the model when its structured output fails
    -- schema validation. Raise this if you see frequent "structured output" /
    -- schema errors from reviews or explanations.
    retry_count = 4,
    -- Source theme groups for Exo's highlight groups (see `HIGHLIGHTS`).
    -- Override any entry via setup({ highlights = { review_good = "String" } }).
    highlights = {
        review_good = "DiagnosticOk",
        review_okay = "DiagnosticWarn",
        review_poor = "DiagnosticError",
        review_in_progress = "DiagnosticInfo",
        explain_in_progress = "DiagnosticInfo",
        explain_complete = "DiagnosticHint",
        explain_title = "FloatTitle",
        explain_text = "Comment",
    },
}

-- Spec for each Exo highlight group. Badges paint white text over the source
-- theme group's fg color (falling back to `fallback` when the theme does not
-- define the source or it has no fg); float groups link to the source directly.
local BADGE_FG = "#ffffff"
local HIGHLIGHTS = {
    review_good = { group = "ExoReviewGood", source = "DiagnosticOk", fallback = "#5a9e4b" },
    review_okay = { group = "ExoReviewOkay", source = "DiagnosticWarn", fallback = "#c99a2e" },
    review_poor = { group = "ExoReviewPoor", source = "DiagnosticError", fallback = "#b5453c" },
    review_in_progress = { group = "ExoReviewInProgress", source = "DiagnosticInfo", fallback = "#4052d6" },
    explain_in_progress = { group = "ExoExplainInProgress", source = "DiagnosticInfo", fallback = "#4052d6" },
    explain_complete = { group = "ExoExplainComplete", source = "DiagnosticHint", fallback = "#1f8f8f" },
    explain_title = { group = "ExoExplainTitle", source = "FloatTitle", link = true },
    explain_text = { group = "ExoExplainText", source = "Comment", link = true },
}

--- Build the Exo highlight groups from `config.highlights`. Sources the user
--- did not override are registered with `default = true`, so an Exo* group
--- defined elsewhere (colorscheme, :highlight) wins over our default.
--- @param overridden table|nil: the raw `opts.highlights`, or nil
-- The highlighted code looks correct. It derives badge
-- backgrounds from the configured source highlight, preserves
-- existing Exo groups through `default = true` unless
-- explicitly overridden, and applies linked float groups as
-- intended. No meaningful correctness, security, or
-- performance issues are apparent in this range.
local apply_highlights = function(overridden)
    overridden = overridden or {}
    for key, spec in pairs(HIGHLIGHTS) do
        local source = config.highlights[key]
        local hl
        if spec.link then
            hl = { link = source }
        else
            local attrs = vim.api.nvim_get_hl(0, { name = source })
            local bg = attrs.fg ~= nil and string.format("#%06x", attrs.fg) or spec.fallback
            hl = { fg = BADGE_FG, bg = bg }
        end
        if overridden[key] == nil then
            hl.default = true
        end
        vim.api.nvim_set_hl(0, spec.group, hl)
    end
end

--- @param opts table|nil overrides merged over the defaults in `config`
-- The code looks good, but it should check if `SERVER` and
-- `SERVER.stop` exist before calling them in the `VimLeavePre`
-- autocmd to avoid potential nil errors.
M.setup = function(opts)
    opts = opts or {}
    config = vim.tbl_deep_extend("force", config, opts)
    -- `start_command` is a list: replace it wholesale rather than index-merging
    -- (deep-extend would splice a shorter override onto the default's tail).
    if opts.start_command ~= nil then
        config.start_command = opts.start_command
    end

    NS = vim.api.nvim_create_namespace("exoskeleton")

    -- Derive the badge/link colors from the current theme, and re-derive them
    -- whenever the colorscheme changes (a :colorscheme clears our groups).
    local overridden = opts.highlights or {}
    apply_highlights(overridden)
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("exo", { clear = true }),
        callback = function()
            apply_highlights(overridden)
        end,
    })

    vim.keymap.set({ "n", "v" }, "<leader>er", "<CMD>ExoReview<CR>", { silent = true })
    vim.keymap.set({ "n", "v" }, "<leader>ee", "<CMD>ExoExplain<CR>", { silent = true })
    vim.keymap.set("n", "<leader>ed", "<CMD>ExoDeleteMark<CR>", { silent = true })
    vim.keymap.set("n", "<leader>ep", "<CMD>ExoPrevMark<CR>", { silent = true })
    vim.keymap.set("n", "<leader>en", "<CMD>ExoNextMark<CR>", { silent = true })

    -- Stop the opencode server on exit, but only if we started it ourselves.
    vim.api.nvim_create_autocmd("VimLeavePre", {
-- The code looks good but should check if SERVER and
-- SERVER.stop exist before calling them to avoid potential nil
-- errors.
        callback = function()
            SERVER.stop()
        end,
    })
end

M.review = function()
    require("review").review(config, NS)
end

M.explain = function()
    require("explain").explain(config, NS)
end

M.delete_mark = function()
    require("marks").delete_mark(NS)
end

M.jump_prev_mark = function()
    require("marks").jump_prev_mark(NS)
end

M.jump_next_mark = function()
    require("marks").jump_next_mark(NS)
end

return M
