local REVIEW = {}
local AI = require("ai")
local NAV = require("nav")
local SERVER = require("server")
local UTIL = require("util")
local MAX_NUM_CHARS = 60

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

--- @param config table: plugin configuration (see `exo.M.setup`).
--- @param code string[]: A list of lines to be reviewed.
--- @param file_path string: Path of the buffer being reviewed.
--- @param start_line integer: First (1-indexed) line of the highlighted range.
--- @param end_line integer: Last (1-indexed) line of the highlighted range.
--- @param on_done fun(result)
local review_code = function(config, code, file_path, start_line, end_line, on_done)
    local code_string = table.concat(code, "\n") .. "\n"
    local file_type = vim.bo.filetype
    local formatted_prompt = AI.create_review_prompt(file_type, code_string, file_path, start_line, end_line)

    local function run_review()
        AI.get_opencode_response(
            config.opencode_url,
            config.ai_model,
            formatted_prompt,
            { agent = config.review_agent, retry_count = config.retry_count },
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

--- @param config table: plugin configuration (see `exo.M.setup`).
--- @param ns integer: the exoskeleton extmark namespace.
REVIEW.review = function(config, ns)
    local mode = vim.fn.mode()
    local is_visual = mode == "v" or mode == "V" or mode == "\22" -- \22 is CTRL-V (blockwise)

    if not is_visual then
        vim.notify("No visual selection", vim.log.levels.WARN, { title = "Exoskeleton" })
        return
    end

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    local visual_selection = UTIL.get_visual_selection()

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
        NAV.place_mark(bufnr, ns, line_num - 1, col_num, " Reviewing ", review_highlights["progress"])

    review_code(config, code, file_path, line_num, end_line_num, function(result)
        local quality_label = result.quality:sub(1, 1):upper() .. result.quality:sub(2)
        NAV.update_mark(
            ext_mark_id,
            bufnr,
            ns,
            nil,
            nil,
            " Review Complete - " .. quality_label .. " ",
            review_highlights[result.quality]
        )

        local new_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, ext_mark_id, {})
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

        -- Append the review location to the shared "Exo" quickfix list.
        vim.fn.setqflist({}, "a", {
            title = "Exo",
            items = {
                { bufnr = bufnr, lnum = line_num, text = "Code Review - " .. quality_label },
            },
        })

        vim.notify(
            "Review Complete - run :copen to view",
            vim.log.levels.INFO,
            { title = "Exoskeleton" }
        )
    end)
end

return REVIEW
