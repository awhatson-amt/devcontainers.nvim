local log = require('devcontainers.log')['cache.configuration']
local devcontainer_cli = require('devcontainers.manager.devcontainer-cli')

-- FIXME: this cache would need invalidation based on devcontainer.json

-- ---@type table<string, uv_timer_t>
-- local dir_cache_clear = {}
-- local dir_cache_clear_period = 3 * 1000

---@class devcontainers.WorkspaceConfig
---@field workspaceFolder string

---@class devcontainers.cache.configuration: { [string]: devcontainers.WorkspaceConfig }
local cache = setmetatable({}, {
    __index = function(cache, workspace_dir)
        log.trace('Getting configuration for: %s', workspace_dir)

        local config = devcontainer_cli.get_configuration(workspace_dir)
        cache[workspace_dir] = config

        -- -- Clear cache after short time
        -- if dir_cache_clear[workspace_dir] then
        --     dir_cache_clear[workspace_dir]:stop()
        -- else
        --     dir_cache_clear[workspace_dir] = vim.uv.new_timer()
        -- end
        -- log.trace('Starting clear cache timer for: %s', workspace_dir)
        -- dir_cache_clear[workspace_dir]:start(dir_cache_clear_period, 0, function()
        --     log.trace('Clearing workspace_dir cache for: %s', workspace_dir)
        --     cache[workspace_dir] = nil
        --     if dir_cache_clear[workspace_dir] then
        --         dir_cache_clear[workspace_dir]:stop()
        --         dir_cache_clear[workspace_dir] = nil
        --     end
        -- end)

        return rawget(cache, workspace_dir)
    end
})

return cache
