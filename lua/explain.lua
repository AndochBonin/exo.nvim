local EXPLAIN = {}
local AI = require("ai")
local MARKS = require("marks")
local NAV = require("nav")
local SERVER = require("server")
local UTIL = require("util")

--- Namespace for highlights inside the explain input float (kept separate from the
--- exoskeleton extmark namespace used on source buffers).
local FLOAT_NS = vim.api.nvim_create_namespace("exo_explain_float")

--- Open a centered explain prompt: one coherent box with two sections — a
--- bordered non-modifiable header (" Explain " title on top, selection info)
--- above the input window, joined by the input window's flat ─ top border.
--- Calls `on_submit(question)` with the typed prompt on <Enter>.
--- @param selection_info { file_path: string, start_row: integer, end_row: integer }|nil
--- @param on_submit fun(question: string)
local function open_explain_window(selection_info, on_submit)
    local header = {}
    if selection_info then
        table.insert(header, "File:  " .. selection_info.file_path)
        table.insert(header, string.format("Lines: %d-%d", selection_info.start_row, selection_info.end_row))
    else
        table.insert(header, "No selection — asking a general question.")
    end

    -- Both windows share one width: the max of each window's natural width, so
    -- their outer edges always align.
    local natural_header = 0
    for _, line in ipairs(header) do
        natural_header = math.max(natural_header, vim.fn.strdisplaywidth(line))
    end
    local natural_input = math.min(80, math.floor(vim.o.columns * 0.6))
    local width = math.max(natural_header, natural_input)

    -- Read-only header block, tinted with the explain accent.
    local header_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(header_buf, 0, -1, false, header)
    vim.bo[header_buf].bufhidden = "wipe"
    for lnum = 0, #header - 1 do
        vim.api.nvim_buf_set_extmark(header_buf, FLOAT_NS, lnum, 0, { line_hl_group = "ExoExplainText" })
    end
    vim.bo[header_buf].modifiable = false

    -- Input buffer: everything typed here is the prompt.
    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
    vim.bo[input_buf].bufhidden = "wipe"

    -- Float row/col anchor the outer frame (borders included). Total unit:
    -- top border + header rows + divider + input row + bottom border.
    local total_height = #header + 4
    local row = math.floor((vim.o.lines - total_height) / 2)
    local col = math.floor((vim.o.columns - (width + 2)) / 2)

    -- Header: full rounded border with the title on top. Its bottom border row
    -- is the same screen row as the input window's top border (see below),
    -- which overdraws it — the seam renders as a single flat ─ line. Cannot
    -- take focus.
    local header_win = vim.api.nvim_open_win(header_buf, false, {
        relative = "editor",
        width = width,
        height = #header,
        row = row + 1,
        col = col,
        border = "rounded",
        style = "minimal",
        focusable = false,
        zindex = 50,
        title = { { " Explain ", "ExoExplainTitle" } },
        title_pos = "center",
    })

    -- Input: its top border is a flat ─ divider, drawn over the header's bottom
    -- border (higher zindex wins the shared row). NOTE: nvim 0.12 applies
    -- border arrays in clockwise ring order —
    -- { topleft, top, topright, right, bottomright, bottom, bottomleft, left }.
    local win = vim.api.nvim_open_win(input_buf, true, {
        relative = "editor",
        width = width,
        height = 1,
        row = row + #header + 2,
        col = col,
        border = { "─", "─", "─", "│", "╯", "─", "╰", "│" },
        style = "minimal",
        zindex = 51,
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = false

    -- Closing the input window (by any path: keymaps, :q, <C-w>c, …) must take
    -- the header window down with it and always land in normal mode — the
    -- input opens in insert mode, and non-keymap close paths skip stopinsert.
    local closed = false
    local win_closed_autocmd = nil
    local resize_autocmds = {}

    local function required_height()
        local content_width = vim.api.nvim_win_get_width(win)
        local height = 0
        for _, line in ipairs(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)) do
            local display_width = vim.fn.strdisplaywidth(line)
            height = height + math.max(1, math.ceil(display_width / content_width))
        end
        return math.max(1, height)
    end

    local function resize_input()
        if closed or not vim.api.nvim_win_is_valid(win) then
            return
        end

        -- Keep the input's top edge fixed and cap its content rows so the
        -- bottom border remains inside the editor. Once capped, normal float
        -- scrolling reveals additional wrapped input rows.
        local max_height = math.max(1, vim.o.lines - (row + #header + 2) - 2)
        local height = math.min(required_height(), max_height)
        if vim.api.nvim_win_get_height(win) ~= height then
            vim.api.nvim_win_set_height(win, height)
        end
    end

    local function close()
        if closed then
            return
        end
        closed = true
        if win_closed_autocmd then
            pcall(vim.api.nvim_del_autocmd, win_closed_autocmd)
        end
        for _, autocmd in ipairs(resize_autocmds) do
            pcall(vim.api.nvim_del_autocmd, autocmd)
        end
        vim.cmd.stopinsert()
        for _, w in ipairs({ header_win, win }) do
            if vim.api.nvim_win_is_valid(w) then
                vim.api.nvim_win_close(w, true)
            end
        end
    end
    win_closed_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        callback = function()
            -- The closed window is still mid-teardown inside this event; doing
            -- our own window teardown synchronously here silently no-ops, so
            -- run it on the next event-loop tick instead.
            vim.schedule(close)
        end,
    })
    for _, event in ipairs({ "TextChangedI", "TextChangedP", "TextChanged" }) do
        table.insert(resize_autocmds, vim.api.nvim_create_autocmd(event, {
            buffer = input_buf,
            callback = resize_input,
        }))
    end
    table.insert(resize_autocmds, vim.api.nvim_create_autocmd("VimResized", {
        callback = resize_input,
    }))

    local function submit()
        -- Everything in the input buffer is the prompt.
        local input_lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
        local question = vim.trim(table.concat(input_lines, "\n"))
        close()
        if question == "" then
            vim.notify("Explain: empty prompt", vim.log.levels.WARN, { title = "Exoskeleton" })
            return
        end
        on_submit(question)
    end

    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    resize_input()
    vim.cmd("startinsert")

    local map_opts = { buffer = input_buf, nowait = true, silent = true }
    vim.keymap.set({ "i", "n" }, "<CR>", submit, map_opts)
    vim.keymap.set("i", "<Esc>", vim.cmd.stopinsert, map_opts)
    vim.keymap.set("n", "<Esc>", close, map_opts)
    vim.keymap.set("n", "q", close, map_opts)
end

--- @param config table: plugin configuration (see `exo.M.setup`).
--- @param ns integer: the exoskeleton extmark namespace.
EXPLAIN.explain = function(config, ns)
    local mode = vim.fn.mode()
    local is_visual = mode == "v" or mode == "V" or mode == "\22" -- \22 is CTRL-V (blockwise)

    local bufnr = vim.api.nvim_get_current_buf()
    -- Capture the cursor line now; with no selection the extmark is placed here,
    -- and by submit time the cursor has moved through the input float.
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
    local file_path = vim.fn.expand("%:.")
    if file_path == nil or file_path == "" then
        file_path = "[unnamed buffer]"
    end
    local file_type = vim.bo.filetype
    local comment_string = vim.bo.commentstring

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

        -- With a selection, mark the selection's first line; otherwise mark the
        -- line the cursor was on when explain was invoked. The label sits at EOL.
        local mark_row = selection_info ~= nil and (start_row - 1) or (cursor_row - 1)
        local mark_col = selection_info ~= nil and col or 0
        local ext_mark_id = NAV.place_mark(bufnr, ns, mark_row, mark_col, " Explaining ", "ExoExplainInProgress")

        vim.notify("Explaining…", vim.log.levels.INFO, { title = "Exoskeleton" })

        local cancelled = false
        local finished = false
        local ready_cancel = nil
        local ai_cancel = nil

        local function finish(response, err)
            if cancelled or finished then
                return
            end
            finished = true
            MARKS.unregister_pending(bufnr, ns, ext_mark_id)

            if err then
                NAV.update_mark(
                    ext_mark_id,
                    bufnr,
                    ns,
                    nil,
                    nil,
                    " Request failed ",
                    "ExoRequestFailed"
                )
                vim.notify(err, vim.log.levels.ERROR, { title = "Exoskeleton" })
                return
            end

            if response == nil then
                return
            end

            local updated = NAV.update_mark(
                ext_mark_id,
                bufnr,
                ns,
                nil,
                nil,
                " Explanation Complete ",
                "ExoExplainComplete"
            )
            if not updated then
                return
            end

            local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, ext_mark_id, {})
            if #mark < 2 then
                return
            end

            MARKS.register_response(bufnr, ns, ext_mark_id, {
                kind = "explain",
                namespace = ns,
                response = response,
                title = response.title,
                body = response.explanation,
                source = selection_info,
                bufnr = bufnr,
                commentstring = comment_string,
                allow_inline = selection_info ~= nil,
            })

            vim.fn.setqflist({}, "a", {
                title = "Exo",
                items = {
                    { bufnr = bufnr, lnum = mark[1] + 1, text = "Code Explanation - " .. response.title },
                },
            })

            vim.notify("Explanation Complete - press Enter to view", vim.log.levels.INFO, { title = "Exoskeleton" })
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

        local function run_explain()
            if cancelled then
                return
            end

            ai_cancel = AI.get_opencode_explanation(
                config.opencode_url,
                config.explain_model,
                prompt,
                { agent = config.explain_agent, retry_count = config.retry_count },
                function(response, err)
                    finish(response, err)
                end
            )

            if cancelled and ai_cancel then
                ai_cancel()
            end
        end

        -- Make sure a server is reachable first; start one if it isn't, then explain.
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
            run_explain()
        end)
        MARKS.register_pending(bufnr, ns, ext_mark_id, cancel)
    end)
end

return EXPLAIN
