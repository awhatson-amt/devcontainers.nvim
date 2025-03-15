local M = {}

local devcontainer_cli = require('devcontainers.manager.devcontainer-cli')
local log = require('devcontainers.log').manager
local utils = require('devcontainers.utils')
local cache = require('devcontainers.manager.cache')

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

---@param dir string
---@return boolean
function M.is_workspace_dir(dir)
    return vim.uv.fs_stat(vim.fs.joinpath(dir, '.devcontainer')) ~= nil
end

--- Check if a container is already running, if not then spawn it
---@param workspace_dir string
---@param opts? devcontainer.ensure_up.opts
---@return devcontainer.up_status.success?
function M.ensure_up(workspace_dir, opts)
    opts = opts or {}
    assert(coroutine.running())

    local start
    if not pending_ups[workspace_dir] then
        pending_ups[workspace_dir] = {}

        -- Run the operation in separate thread
        start = coroutine.wrap(function()
            local result = devcontainer_cli.ensure_up(workspace_dir, opts)
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
    table.insert(pending_ups[workspace_dir], coroutine.running())
    if start then
        start()
    end
    return coroutine.yield()
end

--- Get path to workspace folder inside the container
---@param workspace_dir string host directory for which the devcontainer runs
function M.get_workspace_folder(workspace_dir)
    -- Try to re-use information from running container
    local cached_info = rawget(cache.container, workspace_dir)
    if cached_info then
        assert(cached_info.remoteWorkspaceFolder)
        log.trace('Returing workspace_dir from cache: %s => %s', workspace_dir, cached_info.remoteWorkspaceFolder)
        return cached_info.remoteWorkspaceFolder
    end
    return cache.configuration[workspace_dir].workspaceFolder
end

---@param workspace_dir string
---@return devcontainer.up_status.success
function M.get_container_info(workspace_dir)
    return cache.container[workspace_dir]
end

return M
