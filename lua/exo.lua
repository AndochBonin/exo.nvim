local M = {}
local NS = nil
local AI = require("ai")
local NAV = require("nav")

M.setup = function()
    NS = vim.api.nvim_create_namespace("exoskeleton")
    vim.api.nvim_set_hl(0, "ExoReview", {
        fg = "#ffffff",
        bg = "#000370",
    })
    vim.keymap.set({ "n", "v" }, "<leader>er", "<CMD>ExoReview<CR>", { silent = true })
    vim.keymap.set({ "n", "v" }, "<leader>ee", "<CMD>ExoExplain<CR>", { silent = true })
    vim.keymap.set("n", "<leader>el", "<CMD>ExoListMarks<CR>", { silent = true })
    vim.keymap.set("n", "<leader>ed", "<CMD>ExoDeleteMark<CR>", { silent = true })
    vim.keymap.set("n", "<leader>ep", "<CMD>ExoPrevMark<CR>", { silent = true })
    vim.keymap.set("n", "<leader>en", "<CMD>ExoNextMark<CR>", { silent = true })
    for i = 1, 9 do
        vim.keymap.set(
            "n",
            string.format("<leader>e%d", i),
            string.format("<CMD>ExoJumpToMark %d<CR>", i),
            { silent = true }
        )
    end
end

local function get_visual_selection()
    local selection_start = vim.fn.getpos("'<")
    local selection_end = vim.fn.getpos("'>")

    if selection_start == nil or selection_end == nil then
        return nil
    end

    return {
        start_pos = selection_start,
        end_pos = selection_end,
        text = vim.fn.getregion(selection_start, selection_end, { type = vim.fn.visualmode() }),
    }
end

--- @param code string[]: A list of lines to be reviewed.
--- @param on_done fun(comments: string[])
local review_code = function(code, on_done)
    local code_string = table.concat(code, "\n") .. "\n"
    local file_type = vim.bo.filetype
    local formatted_prompt = AI.create_review_prompt(file_type, code_string)

    AI.get_ollama_response("http://localhost:11434", formatted_prompt, function(ai_response, err)
        if err then
            vim.notify(err, vim.log.levels.ERROR, { title = "Exoskeleton" })
            return
        end
        on_done({ ai_response })
    end)
end

--- @param selection string[]: A list of lines that were selected for a comment.
--- @return string[]
local explain_selection = function(selection)
    --
    local explanation = { "this", "is", "an", "explanation" } -- this will be the comments returned from the llm
    return explanation
end

M.review = function()
    local mode = vim.fn.mode()
    local is_visual = mode == "v" or mode == "V" or mode == "\22" -- \22 is CTRL-V (blockwise)

    if not is_visual then
        vim.notify("No visual selection", vim.log.levels.WARN, { title = "Exoskeleton" })
        return
    end

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    local visual_selection = get_visual_selection()

    if visual_selection == nil then
        vim.notify("No visual selection", vim.log.levels.WARN, { title = "Exoskeleton" })
        return
    end

    local code = visual_selection.text
    local start_pos = visual_selection.start_pos

    local line_num = start_pos[2]
    local col_num = start_pos[3]

    local bufnr = vim.api.nvim_get_current_buf()

    vim.notify("Reviewing selection…", vim.log.levels.INFO, { title = "Exoskeleton" })

    review_code(code, function(review_comments)
        local output_string = table.concat(review_comments, "\n") .. "\n"

        local line = vim.fn.getline(line_num)
        local line_length = vim.fn.strlen(line) -- this is fine i think

        if line_length < 1 then
            vim.notify("Virtual text line empty!", vim.log.levels.ERROR, { title = "Exoskeleton" })
            return
        end

        local ext_mark_id = NAV.place_mark(bufnr, NS, line_num - 1, col_num, output_string, "ExoReview") -- set_extmrk uses row
        vim.notify(
            string.format("Review complete: Jump to extmark %s", ext_mark_id),
            vim.log.levels.INFO,
            { title = "Exoskeleton" }
        )
    end)
end

M.explain = function()
    local mode = vim.fn.mode()
    local is_visual = mode == "v" or mode == "V" or mode == "\22" -- \22 is CTRL-V (blockwise)

    local output_string = ""
    if is_visual then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
        local text_selection = get_visual_selection().text
        output_string = "" .. text_selection[1][2] .. ":" .. text_selection[1][3] .. " to "          -- start of selection
        output_string = output_string ..
        "" .. text_selection[2][2] .. ":" .. text_selection[2][3] .. "\n"                            -- end of selection
    end

    local explanation_lines = explain_selection(nil)
    for _, comment in ipairs(explanation_lines) do
        output_string = output_string .. "- " .. comment .. "\n"
    end

    output_string = output_string .. "\n"
    vim.notify(output_string, vim.log.levels.INFO, { title = "Exoskeleton" })
end

M.list_marks = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local marks = NAV.list_marks(bufnr, NS)
    local output_string = ""
    for _, mark in pairs(marks) do
        output_string = output_string .. mark[1] .. " line: " .. mark[2] + 1 .. "\n"
    end

    if output_string == "" then
        output_string = "No marks found in buffer"
    end

    vim.notify(output_string, vim.log.levels.INFO, { title = "Exoskeleton" })
end

M.delete_mark = function()
    -- we need to check if there is a mark on the current line
    local bufnr = vim.api.nvim_get_current_buf()
    local line_num = vim.fn.line(".")
    local marks = NAV.list_marks(bufnr, NS)
    local line_marks = {}

    for _, mark in ipairs(marks) do
        if mark[2] + 1 == line_num then -- lua indexing is so stupid, everything is different everywhere
            table.insert(line_marks, mark[1])
        end
    end

    if #line_marks < 1 then
        vim.notify(
            string.format("No marks found on the current line", line_num),
            vim.log.levels.WARN,
            { title = "Exoskeleton" }
        )
        return
    end

    for _, mark in ipairs(line_marks) do
        local ok = NAV.delete_mark(bufnr, NS, mark)
        if not ok then
            vim.notify(string.format("Error deleting mark: %d", mark), vim.log.levels.ERROR, { title = "Exoskeleton" })
        end
    end
end

M.jump_prev_mark = function()
    local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
    row = row - 1 -- extmarks are 0-indexed
    local bufnr = vim.api.nvim_get_current_buf()
    local marks = NAV.list_marks(bufnr, NS)

    if #marks < 1 then
        vim.notify("No marks found in buffer", vim.log.levels.WARN, { title = "Exoskeleton" })
        return
    end

    local found_prev = false
    local prev_mark_row = -math.huge
    local prev_mark_col = nil

    for _, mark in ipairs(marks) do
        local mark_row = mark[2]
        local mark_col = mark[3]
        local row_diff = row - mark_row
        if row_diff > 0 and row_diff < row - prev_mark_row then
            found_prev = true
            prev_mark_row = mark_row
            prev_mark_col = mark_col
        end
    end

    if found_prev then
        vim.api.nvim_win_set_cursor(0, { prev_mark_row + 1, prev_mark_col })
    end
end

M.jump_next_mark = function()
    local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
    row = row - 1 -- extmarks are 0-indexed
    local bufnr = vim.api.nvim_get_current_buf()
    local marks = NAV.list_marks(bufnr, NS)

    if #marks < 1 then
        vim.notify("No marks found in buffer", vim.log.levels.WARN, { title = "Exoskeleton" })
        return
    end

    local found_next = false
    local next_mark_row = math.huge
    local next_mark_col = nil

    for _, mark in ipairs(marks) do
        local mark_row = mark[2]
        local mark_col = mark[3]
        local row_diff = mark_row - row
        if row_diff > 0 and row_diff < next_mark_row - row then
            found_next = true
            next_mark_row = mark_row
            next_mark_col = mark_col
        end
    end

    if found_next then
        vim.api.nvim_win_set_cursor(0, { next_mark_row + 1, next_mark_col })
    end
end

M.jump_to_mark = function(mark_string)
    local mark_id = tonumber(mark_string)
    if mark_id == nil then
        vim.notify(string.format("NaN: %s", mark_id), vim.log.levels.ERROR, { title = "Exoskeleton" })
        return
    end
    -- check if mark is available
    local bufnr = vim.api.nvim_get_current_buf()
    local marks = NAV.list_marks(bufnr, NS)

    for _, mark in ipairs(marks) do
        if mark[1] == mark_id then
            vim.notify(string.format("Jumping to mark %d", mark_id), vim.log.levels.INFO, { title = "Exoskeleton" })
            vim.api.nvim_win_set_cursor(0, { mark[2] + 1, mark[3] })
            return
        end
    end
    vim.notify(string.format("Mark id %d not found", mark_id), vim.log.levels.WARN, { title = "Exoskeleton" })
end

return M
