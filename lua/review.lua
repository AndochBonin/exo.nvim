local REVIEW = {}
local AI = require("ai")
local MARKS = require("marks")
local NAV = require("nav")
local SERVER = require("server")
local UTIL = require("util")

--- @param config table: plugin configuration (see `exo.M.setup`).
--- @param code string[]: A list of lines to be reviewed.
--- @param file_path string: Path of the buffer being reviewed.
--- @param start_line integer: First (1-indexed) line of the highlighted range.
--- @param end_line integer: Last (1-indexed) line of the highlighted range.
--- @param on_done fun(result: table|nil, err: string|nil)
--- @return fun() cancel
local review_code = function(config, code, file_path, start_line, end_line, on_done)
    local code_string = table.concat(code, "\n") .. "\n"
    local file_type = vim.bo.filetype
    local formatted_prompt = AI.create_review_prompt(file_type, code_string, file_path, start_line, end_line)
    local cancelled = false
    local finished = false
    local ready_cancel = nil
    local ai_cancel = nil

    local function finish(result, err)
        if cancelled or finished then
            return
        end
        finished = true
        on_done(result, err)
    end

    local function cancel()
        if cancelled or finished then
            return
        end
        cancelled = true
        if ready_cancel then
            ready_cancel()
        end
        if ai_cancel then
            ai_cancel()
        end
    end

    local function run_review()
        if cancelled then
            return
        end

        ai_cancel = AI.get_opencode_response(
            config.opencode_url,
            config.review_model,
            formatted_prompt,
            { agent = config.review_agent, retry_count = config.retry_count },
            function(result, err)
                finish(result, err)
            end
        )

        if cancelled and ai_cancel then
            ai_cancel()
        end
    end

    -- Make sure a server is reachable first; start one if it isn't, then review.
    ready_cancel = SERVER.ensure_ready(config.opencode_url, config.start_command, {
        ready_timeout_ms = config.ready_timeout_ms,
        poll_interval_ms = config.poll_interval_ms,
    }, function(ok, err)
        if cancelled then
            return
        end
        if not ok then
            finish(nil, "could not start opencode server: " .. (err or "unknown error"))
            return
        end
        run_review()
    end)

    return cancel
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
    local comment_string = vim.bo.commentstring

    vim.notify("Reviewing selection…", vim.log.levels.INFO, { title = "Exoskeleton" })

    local review_highlights = {
        good = "ExoReviewGood",
        okay = "ExoReviewOkay",
        poor = "ExoReviewPoor",
        progress = "ExoReviewInProgress",
        failed = "ExoRequestFailed",
    }

    local line = vim.fn.getline(line_num)
    local line_length = vim.fn.strlen(line) -- this is fine i think

    if line_length < 1 then
        vim.notify("Virtual text line empty!", vim.log.levels.ERROR, { title = "Exoskeleton" })
        return
    end

    local ext_mark_id =
        NAV.place_mark(bufnr, ns, line_num - 1, col_num, " Reviewing ", review_highlights["progress"])

    local cancel = review_code(config, code, file_path, line_num, end_line_num, function(result, err)
        MARKS.unregister_pending(bufnr, ns, ext_mark_id)

        if err then
            NAV.update_mark(
                ext_mark_id,
                bufnr,
                ns,
                nil,
                nil,
                " Request failed ",
                review_highlights.failed
            )
            vim.notify(err, vim.log.levels.ERROR, { title = "Exoskeleton" })
            return
        end

        if result == nil then
            return
        end

        local quality_label = result.quality:sub(1, 1):upper() .. result.quality:sub(2)
        local updated = NAV.update_mark(
            ext_mark_id,
            bufnr,
            ns,
            nil,
            nil,
            " Review Complete - " .. quality_label .. " ",
            review_highlights[result.quality]
        )
        if not updated then
            return
        end

        local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, ext_mark_id, {})
        if #mark < 2 then
            return
        end

        MARKS.register_response(bufnr, ns, ext_mark_id, {
            kind = "review",
            namespace = ns,
            response = result,
            title = "Code Review - " .. quality_label,
            body = result.comment,
            source = { file_path = file_path, start_row = line_num, end_row = end_line_num },
            bufnr = bufnr,
            commentstring = comment_string,
            allow_inline = true,
        })

        -- Append the review location to the shared "Exo" quickfix list.
        vim.fn.setqflist({}, "a", {
            title = "Exo",
            items = {
                { bufnr = bufnr, lnum = mark[1] + 1, text = "Code Review - " .. quality_label },
            },
        })

        vim.notify(
            "Review Complete - press Enter to view",
            vim.log.levels.INFO,
            { title = "Exoskeleton" }
        )
    end)
    MARKS.register_pending(bufnr, ns, ext_mark_id, cancel)
end

return REVIEW
