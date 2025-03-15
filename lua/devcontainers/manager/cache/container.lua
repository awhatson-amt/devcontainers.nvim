local log = require('devcontainers.log')['cache.container']
local devcontainer_cli = require('devcontainers.manager.devcontainer-cli')
local docker_events = require('devcontainers.manager.docker_events')

--- Mapping from workspace_dir to info
---@class devcontainer.cache.containers: { [string]: devcontainer.up_status.success }
local cache = setmetatable({}, {
    __index = function(cache, workspace_dir)
        log.notify.info('Running devcontainer up to get container id ...')

        local result = devcontainer_cli.devcontainer_up(workspace_dir)
        if not result.ok then
            log.exception('devcontainer up failed: %s', result.error)
        end

        cache[workspace_dir] = result.status
        return rawget(cache, workspace_dir)
    end
})

-- Invalidate entries when containers die
docker_events.subscribe('cache.container.invalidate', function(event)
    if event.Type == 'container' and event.Action == 'die' then
        local id = event.id --[[@as string]]
        log.info('%s died - invalidating cache', id)
        for workspace_dir, info in pairs(cache) do
            if info.containerId == id then
                cache[workspace_dir] = nil
            end
        end
    end
    return false
end)

return cache
