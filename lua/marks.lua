local MARKS = {}
local NAV = require("nav")
local PENDING = {}
local RESPONSES = {}

local function pending_for(bufnr, namespace, create)
    local by_buffer = PENDING[bufnr]
    if by_buffer == nil then
        if not create then
            return nil
        end
        by_buffer = {}
        PENDING[bufnr] = by_buffer
    end

    local by_namespace = by_buffer[namespace]
    if by_namespace == nil and create then
        by_namespace = {}
        by_buffer[namespace] = by_namespace
    end
    return by_namespace
end

local function response_for(bufnr, namespace, create)
    local by_buffer = RESPONSES[bufnr]
    if by_buffer == nil then
        if not create then
            return nil
        end
        by_buffer = {}
        RESPONSES[bufnr] = by_buffer
    end

    local by_namespace = by_buffer[namespace]
    if by_namespace == nil and create then
        by_namespace = {}
        by_buffer[namespace] = by_namespace
    end
    return by_namespace
end

--- Associate a cancellation callback with an in-progress extmark.
--- @param bufnr integer
--- @param namespace integer
--- @param mark_id integer
--- @param cancel fun()
MARKS.register_pending = function(bufnr, namespace, mark_id, cancel)
    pending_for(bufnr, namespace, true)[mark_id] = cancel
end

--- Remove the cancellation callback for a completed operation.
--- @param bufnr integer
--- @param namespace integer
--- @param mark_id integer
MARKS.unregister_pending = function(bufnr, namespace, mark_id)
    local by_namespace = pending_for(bufnr, namespace, false)
    if by_namespace == nil then
        return
    end

    by_namespace[mark_id] = nil
end

--- Store the completed response associated with an extmark.
--- @param bufnr integer
--- @param namespace integer
--- @param mark_id integer
--- @param response table
MARKS.register_response = function(bufnr, namespace, mark_id, response)
    response_for(bufnr, namespace, true)[mark_id] = response
end

--- Remove a completed response associated with an extmark.
--- @param bufnr integer
--- @param namespace integer
--- @param mark_id integer
MARKS.unregister_response = function(bufnr, namespace, mark_id)
    local by_namespace = response_for(bufnr, namespace, false)
    if by_namespace == nil then
        return
    end

    by_namespace[mark_id] = nil
end

--- @param bufnr integer
--- @param namespace integer
--- @param row integer: zero-indexed buffer row
--- @return table[]: entries with id, row, column, and response fields
MARKS.responses_on_line = function(bufnr, namespace, row)
    local by_namespace = response_for(bufnr, namespace, false)
    if by_namespace == nil then
        return {}
    end

    local responses = {}
    for _, mark in ipairs(NAV.list_marks(bufnr, namespace)) do
        if mark[2] == row and by_namespace[mark[1]] ~= nil then
            table.insert(responses, {
                id = mark[1],
                row = mark[2],
                column = mark[3],
                response = by_namespace[mark[1]],
            })
        end
    end
    return responses
end

-- The highlighted cancellation logic looks good: it safely
-- handles missing entries, removes the callback before
-- invoking it to prevent re-entrant double cancellation, and
-- protects deletion from callback errors with `pcall`. No
-- meaningful correctness issues found.
local function cancel_pending(bufnr, namespace, mark_id)
    local by_namespace = pending_for(bufnr, namespace, false)
    local cancel = by_namespace and by_namespace[mark_id]
    if cancel == nil then
        return
    end

    -- Remove first so a re-entrant delete cannot cancel the same operation twice.
    by_namespace[mark_id] = nil
    pcall(cancel)
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
        cancel_pending(bufnr, ns, mark)
        MARKS.unregister_response(bufnr, ns, mark)
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

return MARKS
