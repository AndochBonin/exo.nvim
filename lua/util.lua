local UTIL = {}

--- Read the last visual selection (the `'<`/`'>` marks). Returns nil if the
--- marks are unavailable, otherwise the start/end positions and the selected
--- text (respecting the current visual mode: charwise, linewise, blockwise).
--- @return { start_pos: integer[], end_pos: integer[], text: string[] }|nil
UTIL.get_visual_selection = function()
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

return UTIL
