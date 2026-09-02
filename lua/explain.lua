local EXPLAIN = {}
local AI = require("ai")
local NAV = require("nav")
local SERVER = require("server")
local STORE = require("store")
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

    -- Closing the input window (by any path: keymaps, :q, <C-w>c, …) must take
    -- the header window down with it and always land in normal mode — the
    -- input opens in insert mode, and non-keymap close paths skip stopinsert.
    local closed = false
    local win_closed_autocmd = nil
    local function close()
        if closed then
            return
        end
        closed = true
        if win_closed_autocmd then
            pcall(vim.api.nvim_del_autocmd, win_closed_autocmd)
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

        local function run_explain()
            AI.get_opencode_explanation(
                config.opencode_url,
                config.explain_model,
                prompt,
                { agent = config.explain_agent, retry_count = config.retry_count },
                function(response, err)
                    if err then
                        vim.notify(err, vim.log.levels.ERROR, { title = "Exoskeleton" })
                        return
                    end

                    local path, write_err = STORE.write_explanation({
                        title = response.title,
                        body = response.explanation,
                        source = selection_info,
                        bufnr = bufnr,
                    })
                    if write_err then
                        vim.notify(write_err, vim.log.levels.ERROR, { title = "Exoskeleton" })
                        return
                    end

                    -- Append a single one-line index entry; selecting it opens the
                    -- saved explanation file.
                    local location = selection_info ~= nil and string.format("%s:%d-%d", file_path, start_row, end_row)
                        or "(no selection)"
                    vim.fn.setqflist({}, "a", {
                        title = "Exo",
                        items = {
                            { filename = path, lnum = 1, text = response.title .. "  —  " .. location },
                        },
                    })

                    if ext_mark_id ~= nil then
                        NAV.update_mark(
                            ext_mark_id,
                            bufnr,
                            ns,
                            nil,
                            nil,
                            " Explanation Saved - :copen to open ",
                            "ExoExplainComplete"
                        )
                    end

                    vim.notify("Explanation saved - run :copen to open", vim.log.levels.INFO, { title = "Exoskeleton" })
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
