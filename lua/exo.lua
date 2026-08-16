local M = {}
local NS = nil
local AI = require("ai")
local NAV = require("nav")
local SERVER = require("server")
local MAX_NUM_CHARS = 60

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
        bg = "#1fff0f", -- will move these colors out into vars that can be overriden by opts or something
    })
    vim.api.nvim_set_hl(0, "ExoReviewOkay", {
        fg = "#ffffff",
        bg = "#f6bb00",
    })
    vim.api.nvim_set_hl(0, "ExoReviewPoor", {
        fg = "#ffffff",
        bg = "#ff160c",
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

--- Greedy word-wrap: split text into fragments of at most max_chars, never
--- breaking a word. A single word longer than max_chars becomes its own fragment.
--- @param text string
--- @param max_chars integer
--- @return string[]
local function split_into_fragments(text, max_chars)
    local fragments = {}
    local current = ""

    for word in text:gmatch("%S+") do
        if current == "" then
            current = word
        elseif #current + 1 + #word <= max_chars then
            current = current .. " " .. word
        else
            table.insert(fragments, current)
            current = word
        end
    end

    if current ~= "" then
        table.insert(fragments, current)
    end

    return fragments
end

--- @param code string[]: A list of lines to be reviewed.
--- @param file_path string: Path of the buffer being reviewed.
--- @param start_line integer: First (1-indexed) line of the highlighted range.
--- @param end_line integer: Last (1-indexed) line of the highlighted range.
--- @param on_done fun(result)
local review_code = function(code, file_path, start_line, end_line, on_done)
    local code_string = table.concat(code, "\n") .. "\n"
    local file_type = vim.bo.filetype
    local formatted_prompt = AI.create_review_prompt(file_type, code_string, file_path, start_line, end_line)

    local function run_review()
        AI.get_opencode_response(
            config.opencode_url,
            config.ai_model,
            formatted_prompt,
            { agent = config.review_agent },
            function(result, err)
                if err then
                    vim.notify(err, vim.log.levels.ERROR, { title = "Exoskeleton" })
                    return
                end
                on_done(result)
            end
        )
    end

    -- Make sure a server is reachable first; start one if it isn't, then review.
    SERVER.ensure_ready(config.opencode_url, config.start_command, {
        ready_timeout_ms = config.ready_timeout_ms,
        poll_interval_ms = config.poll_interval_ms,
    }, function(ok, err)
        if not ok then
            vim.notify(
                "could not start opencode server: " .. (err or "unknown error"),
                vim.log.levels.ERROR,
                { title = "Exoskeleton" }
            )
            return
        end
        run_review()
    end)
end

--- Open a centered floating input window for an explain request. Shows the
--- selection details (when any) and a read-only disclaimer, then calls
--- `on_submit(question)` with the typed prompt when the user presses <Enter>.
--- @param selection_info { file_path: string, start_row: integer, end_row: integer }|nil
--- @param on_submit fun(question: string)
local function open_explain_window(selection_info, on_submit)
    -- Width first so the separator can span the full content area.
    local width = math.min(80, math.floor(vim.o.columns * 0.6))

    local header = { "Explain", "" }
    if selection_info then
        table.insert(header, "File:  " .. selection_info.file_path)
        table.insert(header, string.format("Lines: %d-%d", selection_info.start_row, selection_info.end_row))
    else
        table.insert(header, "No selection — asking a general question.")
    end
    table.insert(header, "Explain is read-only — your files will not be edited.")
    table.insert(header, "Type your question, then press <Enter>. <Esc>/q cancels.")
    table.insert(header, string.rep("─", width))

    -- The input line sits right after the separator (0-indexed == #header).
    local input_line = #header
    local lines = vim.deepcopy(header)
    table.insert(lines, "")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = "wipe"

    local height = #lines
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        border = "rounded",
        style = "minimal",
        title = " Explain ",
        title_pos = "center",
    })

    local closed = false
    local function close()
        if closed then
            return
        end
        closed = true
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    local function submit()
        -- Everything from the input line to the end of the buffer is the prompt.
        local input_lines = vim.api.nvim_buf_get_lines(buf, input_line, -1, false)
        local question = vim.trim(table.concat(input_lines, "\n"))
        close()
        if question == "" then
            vim.notify("Explain: empty prompt", vim.log.levels.WARN, { title = "Exoskeleton" })
            return
        end
        on_submit(question)
    end

    vim.api.nvim_win_set_cursor(win, { input_line + 1, 0 })
    vim.cmd("startinsert")

    local map_opts = { buffer = buf, nowait = true, silent = true }
    vim.keymap.set({ "i", "n" }, "<CR>", function()
        vim.cmd("stopinsert")
        submit()
    end, map_opts)
    vim.keymap.set("n", "<Esc>", close, map_opts)
    vim.keymap.set("n", "q", close, map_opts)
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
    local end_pos = visual_selection.end_pos

    local line_num = start_pos[2]
    local col_num = start_pos[3]
    local end_line_num = end_pos[2]

    local bufnr = vim.api.nvim_get_current_buf()

    local file_path = vim.fn.expand("%:.")
    if file_path == nil or file_path == "" then
        file_path = "[unnamed buffer]"
    end

    vim.notify("Reviewing selection…", vim.log.levels.INFO, { title = "Exoskeleton" })

    local review_highlights = {
        good = "ExoReviewGood",
        okay = "ExoReviewOkay",
        poor = "ExoReviewPoor",
        progress = "ExoReviewInProgress",
    }

    local line = vim.fn.getline(line_num)
    local line_length = vim.fn.strlen(line) -- this is fine i think

    if line_length < 1 then
        vim.notify("Virtual text line empty!", vim.log.levels.ERROR, { title = "Exoskeleton" })
        return
    end

    local ext_mark_id =
        NAV.place_mark(bufnr, NS, line_num - 1, col_num, "review in progress", review_highlights["progress"])

    review_code(code, file_path, line_num, end_line_num, function(result)
        NAV.update_mark(
            ext_mark_id,
            bufnr,
            NS,
            nil,
            nil,
            "code quality: " .. result.quality,
            review_highlights[result.quality]
        )

        local new_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, ext_mark_id, {})
        local new_mark_row = new_mark[1]

        local review_comments = {}
        local comment_string = vim.bo.commentstring

        if comment_string == nil then
            comment_string = "// %s"
        end

        for _, fragment in ipairs(split_into_fragments(result.comment, MAX_NUM_CHARS)) do
            table.insert(review_comments, string.format(comment_string, fragment))
        end

        vim.api.nvim_buf_set_lines(0, new_mark_row, new_mark_row, false, review_comments)

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

    local bufnr = vim.api.nvim_get_current_buf()
    local file_path = vim.fn.expand("%:.")
    if file_path == nil or file_path == "" then
        file_path = "[unnamed buffer]"
    end
    local file_type = vim.bo.filetype

    -- Selection is optional: explain can answer a general question with none.
    local selection_info = nil
    local code_string = nil
    local start_row, end_row, col

    if is_visual then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
        local visual_selection = get_visual_selection()
        if visual_selection ~= nil and #visual_selection.text > 0 then
            start_row = visual_selection.start_pos[2]
            end_row = visual_selection.end_pos[2]
            col = visual_selection.start_pos[3]
            code_string = table.concat(visual_selection.text, "\n")
            selection_info = { file_path = file_path, start_row = start_row, end_row = end_row }
        end
    end

    open_explain_window(selection_info, function(question)
        local prompt = AI.create_explain_prompt(question, file_type, code_string, file_path, start_row, end_row)

        local ext_mark_id = nil
        if selection_info ~= nil then
            ext_mark_id = NAV.place_mark(bufnr, NS, start_row - 1, col, "Explaining", "ExoExplainInProgress")
        end

        vim.notify("Explaining…", vim.log.levels.INFO, { title = "Exoskeleton" })

        local function run_explain()
            AI.get_opencode_explanation(
                config.opencode_url,
                config.ai_model,
                prompt,
                { agent = config.explain_agent },
                function(explanation, err)
                    if err then
                        vim.notify(err, vim.log.levels.ERROR, { title = "Exoskeleton" })
                        return
                    end

                    local qf_title = selection_info ~= nil
                            and string.format("Exo Explain: %s:%d-%d", file_path, start_row, end_row)
                        or "Exo Explain"

                    local items = {}
                    for _, line in ipairs(vim.split(explanation, "\n", { plain = true })) do
                        local item = { text = line }
                        if selection_info ~= nil then
                            item.bufnr = bufnr
                            item.lnum = start_row
                        end
                        table.insert(items, item)
                    end
                    vim.fn.setqflist({}, "r", { title = qf_title, items = items })

                    if ext_mark_id ~= nil then
                        NAV.update_mark(
                            ext_mark_id,
                            bufnr,
                            NS,
                            nil,
                            nil,
                            "Explanation Complete: :copen to read",
                            "ExoExplainComplete"
                        )
                    end

                    vim.notify(
                        "Explanation complete — run :copen to read",
                        vim.log.levels.INFO,
                        { title = "Exoskeleton" }
                    )
                end
            )
        end

        -- Make sure a server is reachable first; start one if it isn't, then explain.
        SERVER.ensure_ready(config.opencode_url, config.start_command, {
            ready_timeout_ms = config.ready_timeout_ms,
            poll_interval_ms = config.poll_interval_ms,
        }, function(ok, err)
            if not ok then
                vim.notify(
                    "could not start opencode server: " .. (err or "unknown error"),
                    vim.log.levels.ERROR,
                    { title = "Exoskeleton" }
                )
                return
            end
            run_explain()
        end)
    end)
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

    local bufnr = vim.api.nvim_get_current_buf()
    local marks = NAV.list_marks(bufnr, NS)

    for _, mark in ipairs(marks) do
        if mark[1] == mark_id then
            vim.api.nvim_win_set_cursor(0, { mark[2] + 1, mark[3] })
            return
        end
    end
    vim.notify(string.format("Mark ID %d not found", mark_id), vim.log.levels.WARN, { title = "Exoskeleton" })
end

return M
