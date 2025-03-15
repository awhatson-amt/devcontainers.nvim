local M = {}

local utils = require('devcontainers.utils')
local rpc = require('devcontainers.lsp.rpc_mapping')
local log = require('devcontainers.log').paths
local manager = require('devcontainers.manager')

local URI_SCHEME_PATTERN = '^([a-zA-Z]+[a-zA-Z0-9.+-]*):.*'
-- -- file://host/path
-- local FILE_URI_PATTERN = '^file://([^/]*)/(.*)'

---@param item devcontainers.LspTypeIter.Item
local function item_is_uri(item)
    return item.kind == 'base' and (item.name == 'URI' or item.name == 'DocumentUri')
end

local lsp_uri_mappings = rpc.make_mappings(item_is_uri)

---@param ctx devcontainers.rpc.MappingContext
local function context_to_string(ctx)
    return string.format('%s:%s:%s: %s', ctx.method, ctx.direction, ctx.type, ctx.tree)
end

local context_to_string_mt = { __tostring = context_to_string }

---@type devcontainers.rpc.MappingFn
---@param map_fn fun(path: string): string? must return an URI or nil, use vim.uri_encode and (vim.uri_from_fname or vim.uri_encode)
---@param ctx devcontainers.rpc.MappingContext
---@param value any
local function map_uri(map_fn, ctx, value)
    local mt = getmetatable(ctx)
    assert(mt == nil or mt == context_to_string_mt) -- currently we assume these are temporary tables
    setmetatable(ctx, context_to_string_mt)

    if type(value) ~= 'string' or not value:match(URI_SCHEME_PATTERN) then
        log.error('%s : not an URI: %s', ctx, vim.inspect(value))
        return
    end
    ---@cast value string

    local new_value = map_fn(value)

    if new_value then
        if log:level_enabled(log.levels.trace) then
            log.trace('%s : map uri: "%s" => "%s"', ctx, value, new_value)
        else
            log.debug('map uri: "%s" => "%s"', ctx, value, new_value)
        end
        value = new_value
    end

    return value
end

--- List of tuples (from, to), first has highest priority
---@alias devcontainer.PathMappings { [1]: string, [2]: string }[]

-- TODO: make proper cache
---@param container_id string
local function get_container_name(container_id)
    local result = utils.system {'docker', 'inspect', container_id}
    local data = result.code == 0 and vim.json.decode(result.stdout)
    local name = data and #data == 1 and data[1].Name
    if not name then
        log.exception('Could not resolve container %s', container_id)
    end
    return name
end

local ensure_docker_handlers_loaded = utils.lazy(function()
    if package.loaded['netman'] then -- ok, netman.nvim available
        return false
    end

    -- try to load netman.nvim
    -- utils.schedule_if_needed()
    if pcall(require, 'netman') then
        return false
    end

    -- check for theoretical other plugins that could handle this
    local autocmds = vim.api.nvim_get_autocmds { event = 'BufReadCmd', pattern = 'docker://*' }
    if next(autocmds) then
        return false
    end

    log.notify.warn('No handlers for "docker://" buffers: install netman.nvim or similar plugin')
    return true
end)

---@param config vim.lsp.ClientConfig
---@param workspace_dir string
function M.patch_config(config, workspace_dir)
    local container_dir = manager.get_workspace_folder(workspace_dir)

    ---@type devcontainers.rpc.PerDirection<devcontainer.PathMappings>
    local path_mappings = {
        server2client = {
            { container_dir, workspace_dir },
        },
        client2server = {
            { workspace_dir, container_dir },
        },
    }

    local mappers = {}

    for dir, _ in pairs(path_mappings) do
        mappers[dir] = function(uri)
            local scheme = assert(uri:match(URI_SCHEME_PATTERN), 'URI without scheme')

            if scheme == 'file' then
                local path = vim.uri_to_fname(uri)
                local dir_mappings = path_mappings[dir]
                for _, mapping in ipairs(dir_mappings) do
                    local from, to = unpack(mapping)
                    local _, end_ = string.find(path, from, 1, true)
                    if end_ then
                        return vim.uri_from_fname(to .. path:sub(end_ + 1))
                    end
                end

                if dir == 'client2server' then
                    log.warn('Invalid path sent to server in container: %s', uri)
                else -- server2client
                    -- fall back to docker URIs translation
                    ensure_docker_handlers_loaded()
                    local container_info = manager.get_container_info(workspace_dir)
                    local container_name = get_container_name(container_info.containerId)
                    return string.format('docker://%s%s', container_name, vim.fs.abspath(path))
                end
            elseif scheme == 'docker' then
                if dir == 'server2client' then
                    log.warn('Server sent URI with "docker" scheme: %s', uri)
                else -- client2server
                end
            else
                log.warn('Unsupported scheme: %s', uri)
            end
        end
    end

    rpc.patch_config(config, lsp_uri_mappings, function(ctx, value)
        local mapper = mappers[ctx.direction]
        if not mapper then
            log.exception('Invalid direction: %s', ctx.direction)
        end
        return map_uri(mapper, ctx, value)
    end)
end

return M

