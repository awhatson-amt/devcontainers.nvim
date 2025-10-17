local M = {}

local cli = require('devcontainers.cli')
local log = require('devcontainers.log').manager
local utils = require('devcontainers.utils')
local cache = require('devcontainers.cache')

---@class devcontainer.ensure_up.opts
---@field confirm? boolean ask before starting devcontainer
---@field test_cmd? string[] use custom command for testing if container is running

---@class devcontainer.up_status.success
---@field outcome 'success'
---@field containerId string
---@field remoteUser string
---@field remoteWorkspaceFolder string

---@class devcontainer.up_status.error
---@field outcome 'error'
---@field message string
---@field description string

---@alias devcontainer.up_status devcontainer.up_status.success|devcontainer.up_status.error

---@type table<string, thread[]> threads to notify after ensure_up completed
local pending_ups = {}

---@param dir? string defaults to current buffer's directory
---@return string? workspace directory containsing .devcontainers/ directory
function M.find_workspace_dir(dir)
    if dir == nil then
        local name = vim.api.nvim_buf_get_name(0)
        if name ~= "" then
            dir = vim.fs.dirname(name)
        else
            dir = vim.fn.getcwd(0)
        end
    end

    local workspace_dir = vim.fs.root(dir, { ".devcontainer" })
    log.trace('find_workspace_dir(%s): %s', dir, workspace_dir)
    return workspace_dir
end

---@async
---@param workspace_dir string
---@param opts? devcontainer.ensure_up.opts
---@return devcontainer.cache.Entry|false
local function ensure_up(workspace_dir, opts)
    opts = opts or {}
    assert(coroutine.running())

    local short_dir = utils.bind(utils.lazy(vim.fn.pathshorten), workspace_dir)

    -- If we already have this information then the container has already been started
    local cached = cache.check(workspace_dir)
    if cached then
        return cached
    end

    -- Check if container exists
    if not cli.container_is_running(workspace_dir) then
        -- Offer to start it or proceed without asking
        if opts.confirm then
            local input = utils.ui_input {
                prompt = string.format('Devcontainer for %s not running, start? [y/N]: ', short_dir()),
            }
            if not (input and vim.tbl_contains({'y', 'yes'}, input:lower())) then
                return false
            end
        end
    end

    -- Start the devcontainer
    log.trace('devcontainer_up: %s', workspace_dir)
    local result = cli.devcontainer_up(workspace_dir)

    if result.ok then
        -- Fetch the rest of information avoiding repeating devcontainer-up
        return cache.fetch(workspace_dir, { up = result.status --[[@as devcontainer.up_status.success]] })
    else
        return false
    end
end

--- Check if a container is already running, if not then spawn it
---@async
---@param workspace_dir string
---@param opts? devcontainer.ensure_up.opts
---@return devcontainer.cache.Entry|false
function M.ensure_up(workspace_dir, opts)
    opts = opts or {}
    assert(coroutine.running())

    local start
    if not pending_ups[workspace_dir] then
        pending_ups[workspace_dir] = {}

        -- Run the operation in separate thread
        start = coroutine.wrap(function()
            local result = ensure_up(workspace_dir, opts)
            utils.schedule()

            -- Resume all pending coroutines
            local pending = pending_ups[workspace_dir] or {}
            pending_ups[workspace_dir] = nil
            for _, co in ipairs(pending) do
                local ok, err = coroutine.resume(co, result)
                if not ok then
                    log.notify.error('Pending ensure_up failed:\n%s', debug.traceback(co, err))
                end
            end
        end)
    end

    -- Add caller thread to observers and wait
    local co = assert(coroutine.running())
    table.insert(pending_ups[workspace_dir], co)
    if start then
        start()
    end
    return coroutine.yield()
end

return M
