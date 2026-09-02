local M = {}
local NS = nil
local SERVER = require("server")

-- User-overridable configuration (see `M.setup`). Note: `opencode_url` and
-- `start_command` are independent — if you change the URL/port, update
-- `start_command` to match so the auto-started server binds where we connect.
local config = {
    ai_model = "ollama/devstral-small-2",
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
}

--- @param opts table|nil overrides merged over the defaults in `config`
-- Minor comment about hardcoded hex colors. Code quality is
-- otherwise good.
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
    vim.api.nvim_set_hl(0, "ExoReviewGood", {
        fg = "#ffffff",
        bg = "#5a9e4b", -- will move these colors out into vars that can be overriden by opts or something
    })
    vim.api.nvim_set_hl(0, "ExoReviewOkay", {
        fg = "#ffffff",
        bg = "#c99a2e",
    })
    vim.api.nvim_set_hl(0, "ExoReviewPoor", {
        fg = "#ffffff",
        bg = "#b5453c",
    })
    vim.api.nvim_set_hl(0, "ExoReviewInProgress", {
        fg = "#ffffff",
        bg = "#4052D6",
    })
    vim.api.nvim_set_hl(0, "ExoExplainInProgress", {
        fg = "#ffffff",
        bg = "#4052D6", -- blue, matches the review progress style
    })
    vim.api.nvim_set_hl(0, "ExoExplainComplete", {
        fg = "#ffffff",
        bg = "#1f8f8f", -- teal, denotes a finished explanation
    })
    vim.api.nvim_set_hl(0, "ExoExplainTitle", {
        fg = "#1f8f8f", -- teal, matches the explain accent
        bold = true,
    })
    vim.api.nvim_set_hl(0, "ExoExplainText", {
        fg = "#1f8f8f", -- teal, matches the title
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
