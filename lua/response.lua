local RESPONSE = {}
local MARKS = require("marks")
local STORE = require("store")
local MAX_REVIEW_CHARS = 60

local function quality_label(quality)
    return quality:sub(1, 1):upper() .. quality:sub(2)
end

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

local function response_title(data)
    if data.kind == "review" then
        return " Review - " .. quality_label(data.response.quality) .. " "
    end
    return " Explain - " .. data.response.title .. " "
end

local function response_lines(data)
    if data.kind == "review" then
        return split_into_fragments(data.body, MAX_REVIEW_CHARS)
    end
    return vim.split(data.body, "\n", { plain = true, trim = false })
end

local function comment_lines(data)
    local comment_string = data.commentstring
    if comment_string == nil or comment_string == "" or not comment_string:find("%s", 1, true) then
        comment_string = "// %s"
    end

    local lines = {}
    for _, line in ipairs(response_lines(data)) do
        table.insert(lines, string.format(comment_string, line))
    end
    return lines
end

local function save_inline(entry, close)
    local data = entry.response
    if not data.allow_inline then
        return
    end

    local bufnr = data.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify("Exo: source buffer is no longer available", vim.log.levels.ERROR, { title = "Exoskeleton" })
        return
    end
    if not vim.bo[bufnr].modifiable then
        vim.notify("Exo: source buffer is not modifiable", vim.log.levels.ERROR, { title = "Exoskeleton" })
        return
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, data.namespace, entry.id, {})
    if #mark < 2 then
        vim.notify("Exo: response mark is no longer available", vim.log.levels.ERROR, { title = "Exoskeleton" })
        return
    end

    local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, mark[1], mark[1], false, comment_lines(data))
    if not ok then
        vim.notify("Exo: could not save inline comment: " .. tostring(err), vim.log.levels.ERROR, { title = "Exoskeleton" })
        return
    end

    close()
end

local function save_file(data, close)
    local path, err = STORE.write_response({
        kind = data.kind,
        title = data.title,
        body = data.body,
        source = data.source,
        bufnr = data.bufnr,
    })
    if err then
        vim.notify(err, vim.log.levels.ERROR, { title = "Exoskeleton" })
        return
    end

    close()
    vim.notify("Response saved to " .. path, vim.log.levels.INFO, { title = "Exoskeleton" })
end

local function open_entry(entry)
    local data = entry.response
    local title = response_title(data)
    local lines = response_lines(data)
    if #lines == 0 then
        lines = { "" }
    end

    local natural_width = 0
    for _, line in ipairs(lines) do
        natural_width = math.max(natural_width, vim.fn.strdisplaywidth(line))
    end
    local width = math.min(math.max(40, natural_width), math.max(20, vim.o.columns - 8))
    local height = math.min(#lines, math.max(1, math.floor(vim.o.lines * 0.7)))
    local source_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"

    local footer = data.allow_inline and " i inline  f file  q close " or " f file  q close "
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.floor((vim.o.columns - width) / 2),
        border = "rounded",
        style = "minimal",
        title = title,
        title_pos = "center",
        footer = { { footer, "Comment" } },
        footer_pos = "center",
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].cursorline = false

    local closed = false
    local autocmd = nil
    local function close()
        if closed then
            return
        end
        closed = true
        if autocmd then
            pcall(vim.api.nvim_del_autocmd, autocmd)
        end
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_win_is_valid(source_win) then
            vim.api.nvim_set_current_win(source_win)
        end
    end

    autocmd = vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        callback = function()
            vim.schedule(close)
        end,
    })

    local map_opts = { buffer = buf, nowait = true, silent = true }
    if data.allow_inline then
        vim.keymap.set("n", "i", function()
            save_inline(entry, close)
        end, map_opts)
    end
    vim.keymap.set("n", "f", function()
        save_file(data, close)
    end, map_opts)
    vim.keymap.set("n", "q", close, map_opts)
    vim.keymap.set("n", "<Esc>", close, map_opts)
end

local function format_entry(entry)
    local data = entry.response
    if data.kind == "review" then
        return "Review - " .. quality_label(data.response.quality)
    end
    return "Explain - " .. data.response.title
end

--- Open the completed response on the current line.
--- @param namespace integer
--- @return boolean handled
RESPONSE.open = function(namespace)
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local entries = MARKS.responses_on_line(bufnr, namespace, row)
    if #entries == 0 then
        return false
    end

    if #entries == 1 then
        open_entry(entries[1])
        return true
    end

    vim.ui.select(entries, {
        prompt = "Exo response:",
        format_item = format_entry,
    }, function(entry)
        if entry ~= nil then
            open_entry(entry)
        end
    end)
    return true
end

return RESPONSE
