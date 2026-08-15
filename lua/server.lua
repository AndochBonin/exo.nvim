local SERVER = {}
local curl = require("plenary.curl")

-- Handle for a server process this plugin spawned (a `vim.system` object), or
-- nil if we never started one. `started_by_us` guards `stop()` so we never kill
-- a server the user launched manually. `starting` guards against spawning a
-- second process while a start is already in flight.
local handle = nil
local started_by_us = false
local starting = false

--- Check whether an opencode server is reachable at `base_url`.
--- Any HTTP response (regardless of status code) means the server is up; only a
--- transport failure (curl `on_error`) means it is down. This keeps readiness
--- independent of the exact status/route of the endpoint we probe.
--- @param base_url string
--- @param callback fun(up: boolean)
SERVER.ping = function(base_url, callback)
    curl.get(base_url .. "/session", {
        timeout = 1000,
        callback = function()
            vim.schedule(function()
                callback(true)
            end)
        end,
        on_error = function()
            vim.schedule(function()
                callback(false)
            end)
        end,
    })
end

--- Spawn the opencode server. Tracks the process handle so it can be stopped on
--- Neovim exit. Returns true if the process was spawned, false on spawn failure.
--- @param start_command string[]
--- @return boolean ok
--- @return string|nil err
SERVER.start = function(start_command)
    local ok, result = pcall(vim.system, start_command, { text = true }, function()
        -- Process exited; drop the handle so `stop()` becomes a no-op.
        handle = nil
        started_by_us = false
    end)

    if not ok then
        return false, tostring(result)
    end

    handle = result
    started_by_us = true
    return true
end

--- Ensure a reachable opencode server, starting one if needed, then invoke
--- `callback(true)` once it responds. If it cannot be started/reached within the
--- timeout, invoke `callback(false, err)`.
--- @param base_url string
--- @param start_command string[]
--- @param opts { ready_timeout_ms: integer|nil, poll_interval_ms: integer|nil }|nil
--- @param callback fun(ok: boolean, err: string|nil)
SERVER.ensure_ready = function(base_url, start_command, opts, callback)
    opts = opts or {}
    local ready_timeout_ms = opts.ready_timeout_ms or 10000
    local poll_interval_ms = opts.poll_interval_ms or 250

    SERVER.ping(base_url, function(up)
        if up then
            callback(true)
            return
        end

        if not starting then
            starting = true
            local ok, err = SERVER.start(start_command)
            if not ok then
                starting = false
                callback(false, "failed to spawn opencode server: " .. (err or "unknown error"))
                return
            end
        end

        local deadline = vim.uv.now() + ready_timeout_ms

        local function poll()
            SERVER.ping(base_url, function(ready)
                if ready then
                    starting = false
                    callback(true)
                elseif vim.uv.now() >= deadline then
                    starting = false
                    callback(false, "opencode server did not become ready in time")
                else
                    vim.defer_fn(poll, poll_interval_ms)
                end
            end)
        end

        vim.defer_fn(poll, poll_interval_ms)
    end)
end

--- Stop the server if (and only if) this plugin started it. Safe to call when
--- nothing was started.
SERVER.stop = function()
    if handle and started_by_us then
        pcall(function()
            handle:kill(15) -- SIGTERM
        end)
    end
    handle = nil
    started_by_us = false
    starting = false
end

return SERVER
