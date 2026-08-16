local EXPLAIN = {}
local AI = require("ai")
local NAV = require("nav")
local SERVER = require("server")
local UTIL = require("util")

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

--- @param config table: plugin configuration (see `exo.M.setup`).
--- @param ns integer: the exoskeleton extmark namespace.
EXPLAIN.explain = function(config, ns)
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
        local visual_selection = UTIL.get_visual_selection()
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
            ext_mark_id = NAV.place_mark(bufnr, ns, start_row - 1, col, "Explaining", "ExoExplainInProgress")
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
                            ns,
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

return EXPLAIN
