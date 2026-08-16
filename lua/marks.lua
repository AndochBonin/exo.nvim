local MARKS = {}
local NAV = require("nav")

--- @param ns integer: the exoskeleton extmark namespace.
MARKS.list_marks = function(ns)
    local bufnr = vim.api.nvim_get_current_buf()
    local marks = NAV.list_marks(bufnr, ns)
    local output_string = ""
    for _, mark in pairs(marks) do
        local details = mark[4]
        local label = ""
        if details and details.virt_text and details.virt_text[1] then
            label = vim.trim(details.virt_text[1][1])
        end
        output_string = output_string .. string.format("[%d]: line %d %s\n", mark[1], mark[2] + 1, label)
    end

    if output_string == "" then
        output_string = "No marks found in buffer"
    end

    vim.notify(output_string, vim.log.levels.INFO, { title = "Exoskeleton" })
end

--- @param ns integer: the exoskeleton extmark namespace.
MARKS.delete_mark = function(ns)
    local bufnr = vim.api.nvim_get_current_buf()
    local line_num = vim.fn.line(".")
    local marks = NAV.list_marks(bufnr, ns)
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
        local ok = NAV.delete_mark(bufnr, ns, mark)
        if not ok then
            vim.notify(string.format("Error deleting mark: %d", mark), vim.log.levels.ERROR, { title = "Exoskeleton" })
        end
    end
end

--- @param ns integer: the exoskeleton extmark namespace.
MARKS.jump_prev_mark = function(ns)
    local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
    row = row - 1 -- extmarks are 0-indexed
    local bufnr = vim.api.nvim_get_current_buf()
    local marks = NAV.list_marks(bufnr, ns)

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

--- @param ns integer: the exoskeleton extmark namespace.
MARKS.jump_next_mark = function(ns)
    local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
    row = row - 1 -- extmarks are 0-indexed
    local bufnr = vim.api.nvim_get_current_buf()
    local marks = NAV.list_marks(bufnr, ns)

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

--- @param ns integer: the exoskeleton extmark namespace.
--- @param mark_string string: the mark id to jump to (as typed by the user).
MARKS.jump_to_mark = function(ns, mark_string)
    local mark_id = tonumber(mark_string)
    if mark_id == nil then
        vim.notify(string.format("NaN: %s", mark_id), vim.log.levels.ERROR, { title = "Exoskeleton" })
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local marks = NAV.list_marks(bufnr, ns)

    for _, mark in ipairs(marks) do
        if mark[1] == mark_id then
            vim.api.nvim_win_set_cursor(0, { mark[2] + 1, mark[3] })
            return
        end
    end
    vim.notify(string.format("Mark ID %d not found", mark_id), vim.log.levels.WARN, { title = "Exoskeleton" })
end

return MARKS
