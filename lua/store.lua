local STORE = {}

local RESPONSE_DIRS = {
    explain = "exo-explanations",
    review = "exo-reviews",
}

--- Resolve the git repository root for a buffer, or nil when not in a repo.
--- @param bufnr integer|nil
--- @return string|nil
STORE.git_root = function(bufnr)
    return vim.fs.root(bufnr or 0, ".git")
end

--- Turn a title into a filesystem-safe slug: lowercase, non-alphanumeric runs
--- collapsed to single dashes, trimmed, and capped in length.
--- @param title string
--- @return string
STORE.slugify = function(title)
    local slug = (title or ""):lower()
    slug = slug:gsub("[^%w]+", "-") -- non-alphanumeric runs -> single dash
    slug = slug:gsub("^-+", ""):gsub("-+$", "") -- trim leading/trailing dashes
    if #slug > 60 then
        slug = slug:sub(1, 60):gsub("-+$", "")
    end
    if slug == "" then
        slug = "explanation"
    end
    return slug
end

--- Append a generated response directory to `<root>/.git/info/exclude`, unless it is
--- already present. Silently no-ops if the exclude file cannot be read/written.
--- @param root string
--- @param directory string
local function add_to_git_exclude(root, directory)
    local exclude_path = root .. "/.git/info/exclude"
    local line = directory .. "/"

    local existing = {}
    if vim.fn.filereadable(exclude_path) == 1 then
        existing = vim.fn.readfile(exclude_path)
        for _, l in ipairs(existing) do
            if vim.trim(l) == line then
                return -- already excluded
            end
        end
    end

    table.insert(existing, line)
    pcall(vim.fn.writefile, existing, exclude_path)
end

--- Persist a response to a generated response directory. The folder lives at
--- the git repo root (falling back to cwd when the buffer is not in a repo);
--- on first creation inside a git repo the folder is added to `.git/info/exclude`.
--- @param opts { kind: "review"|"explain", title: string, body: string, source: { file_path: string, start_row: integer, end_row: integer }|nil, bufnr: integer|nil }
--- @return string|nil path, string|nil err
STORE.write_response = function(opts)
    local root = STORE.git_root(opts.bufnr)
    local is_git = root ~= nil
    if not is_git then
        root = vim.fn.getcwd()
    end

    local response_dir = RESPONSE_DIRS[opts.kind]
    if response_dir == nil then
        return nil, "unknown response kind: " .. tostring(opts.kind)
    end

    local dir = root .. "/" .. response_dir
    local existed = vim.fn.isdirectory(dir) == 1

    if vim.fn.mkdir(dir, "p") == 0 and not existed then
        return nil, "could not create " .. dir
    end

    -- Exclude the folder once, when it is first created inside a git repo.
    if is_git and not existed then
        add_to_git_exclude(root, response_dir)
    end

    local filename = STORE.slugify(opts.title) .. "-" .. os.date("%Y%m%d-%H%M%S") .. ".md"
    local path = dir .. "/" .. filename

    local content = { "# " .. opts.title, "" }
    if opts.source ~= nil then
        table.insert(
            content,
            string.format("`%s:%d-%d`", opts.source.file_path, opts.source.start_row, opts.source.end_row)
        )
        table.insert(content, "")
    end
    for _, line in ipairs(vim.split(opts.body, "\n", { plain = true })) do
        table.insert(content, line)
    end

    local ok, err = pcall(vim.fn.writefile, content, path)
    if not ok then
        return nil, "could not write " .. path .. ": " .. tostring(err)
    end

    return path, nil
end

return STORE
