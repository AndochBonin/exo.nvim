-- lowkey this file is pointless

local NAV = {}

NAV.list_marks = function(bufnr, namespace)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
    return marks
end

NAV.place_mark = function(bufnr, namespace, row, column, text, highlight)
    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace, row, column, {
        virt_text = {{ text, highlight }},
        virt_text_pos = "eol",
    })
    return mark_id
end

NAV.delete_mark = function(bufnr, namespace, id)
    return vim.api.nvim_buf_del_extmark(bufnr, namespace, id)
end

return NAV
