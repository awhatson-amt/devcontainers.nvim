local M = {}

local log = require('devcontainers.log')['cache']
local docker = require('devcontainers.docker')
local cli = require('devcontainers.cli')

---@class devcontainer.cache.Entry
---@field workspace_dir string
---@field container_id string
---@field container_name string
---@field remote_user string
---@field remote_dir string
---@field config_path string

---@class devcontainer.cache.PartialResults
---@field up? devcontainer.up_status.success
---@field read_configuration? devcontainer.cli.Config
---@field inspect? devcontainer.docker.Inspect

---@async
---@param workspace_dir string
---@param partial_results? devcontainer.cache.PartialResults
---@return devcontainer.cache.Entry
local function fetch(workspace_dir, partial_results)
    partial_results = partial_results or {}

    log.info('Fetching info for workspace directory: %s', workspace_dir)

    local up = partial_results.up
    if not up then
        log.debug('Running "devcontainer up" ...')
        local result = cli.devcontainer_up(workspace_dir)
        if not result.ok then
            log.exception('devcontainer up failed: %s', result.error)
        end
        up = assert(result.status) --[[@as devcontainer.up_status.success]]
    end

    local read_configuration = partial_results.read_configuration
    if not read_configuration then
        log.debug('Running "devcontainer read-configuration" ...')
        read_configuration = cli.read_configuration(workspace_dir)
    end

    local inspect = partial_results.inspect
    if not inspect then
        log.debug('Running "docker inspect" ...')
        inspect = docker.inspect(up.containerId)
    end

    return {
        workspace_dir = workspace_dir,
        container_id = up.containerId,
        container_name = inspect.Name,
        remote_user = up.remoteUser,
        remote_dir = up.remoteWorkspaceFolder,
        config_path = read_configuration.configuration.configFilePath.path,
    }
end

---@class devcontainer.Cache: { [string]: devcontainer.cache.Entry }
local cache = {}

setmetatable(cache, {
    __index = function(_, workspace_dir)
        return M.get(workspace_dir)
    end
})

---@param workspace_dir string
---@return devcontainer.cache.Entry?
function M.check(workspace_dir)
    return rawget(cache, workspace_dir)
end

---@async
---@param workspace_dir string
---@return devcontainer.cache.Entry
function M.get(workspace_dir)
    local entry = M.check(workspace_dir)
    if not entry then
        entry = fetch(workspace_dir)
        cache[workspace_dir] = entry
    end
    return entry
end

---@async
---@param workspace_dir string
---@param partial_results? devcontainer.cache.PartialResults
---@return devcontainer.cache.Entry
function M.fetch(workspace_dir, partial_results)
    local entry = fetch(workspace_dir, partial_results)
    cache[workspace_dir] = entry
    return entry
end

function M.clear(workspace_dir)
    log.debug('clear: %s', workspace_dir)
    cache[workspace_dir] = nil
end

-- Invalidate entries when containers die
docker.events.subscribe('cache.invalidate', function(event)
    if event.Type == 'container' and event.Action == 'die' then
        local id = event.id --[[@as string]]
        log.info('%s died - invalidating cache', id)
        for workspace_dir, entry in pairs(cache) do
            if entry.container_id == id then
                M.clear(workspace_dir)
            end
        end
    end
    return false
end)

return M
