local M = {}

local utils = require('devcontainers.utils')
local rpc = require('devcontainers.lsp.rpc')
local log = require('devcontainers.log').paths
local cache = require('devcontainers.cache')
local docker = require('devcontainers.docker')

local augroup = vim.api.nvim_create_augroup('devcontainers.paths', { clear = true })

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

local ensure_docker_handlers_loaded = utils.lazy(function()
    if package.loaded['netman'] then -- ok, netman.nvim available
        return false
    end

    -- try to load netman.nvim
    utils.schedule_if_needed()
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

---@param workspace_dir string
---@return table<string, fun(path: string): string?>
local function make_path_mappers(workspace_dir)
    local info = cache.get(workspace_dir)

    ---@type devcontainers.rpc.PerDirection<devcontainer.PathMappings>
    local path_mappings = {
        server2client = {
            { info.remote_dir, workspace_dir },
        },
        client2server = {
            { workspace_dir, info.remote_dir },
        },
    }


    ---@type table<string, fun(path: string): string?>
    local mappers = {}

    for dir, dir_mappings in pairs(path_mappings) do
        mappers[dir] = function(uri)
            local scheme = assert(uri:match(URI_SCHEME_PATTERN), 'URI without scheme')

            if scheme == 'file' then
                -- Try to find matching path mapping and return the path with the remapped prefix
                local path = vim.uri_to_fname(uri)
                for _, mapping in ipairs(dir_mappings) do
                    local from, to = unpack(mapping)
                    local _, end_ = string.find(path, from, 1, true)
                    if end_ then
                        return vim.uri_from_fname(to .. path:sub(end_ + 1))
                    end
                end

                -- If no path mapping matches
                if dir == 'client2server' then
                    log.warn('Invalid path sent to server in container: %s', uri)
                else -- server2client
                    -- fall back to docker URIs translation
                    ensure_docker_handlers_loaded()
                    return docker.uri_from_container_name(info.container_name, vim.fs.abspath(path))
                end
            elseif scheme == 'docker' then
                if dir == 'server2client' then
                    -- We don't expect docker:// paths from within a docker container
                    log.warn('Server sent URI with "docker" scheme: %s', uri)
                else -- client2server
                    -- Sending docker:// buffer to the server - translate to the in-container path
                    local container, path = docker.parse_uri(uri)
                    if not container then
                        log.warn('Could not parse docker URI: %s', uri)
                    elseif container ~= info.container_name then
                        log.warn('Sending docker path with container "%s" to server in container "%s"', container, info.container_name)
                    else
                        return vim.uri_from_fname(assert(path))
                    end
                end
            else
                log.warn('Unsupported scheme: %s', uri)
            end
        end
    end

    return mappers
end

---@param config vim.lsp.ClientConfig
---@param workspace_dir string
---@return vim.lsp.Client?
local function get_lsp_client_by_config(config, workspace_dir)
    local clients = {}
    for _, client in ipairs(vim.lsp.get_clients { name = config.name }) do
        if client.config == config then
            table.insert(clients, client)
        end
    end

    if #clients == 0 then
        log.warn('Could not find %s LSP client for "%s"', config.name, workspace_dir)
    elseif #clients > 1 then
        log.warn('More than one %s LSP client for "%s"', config.name, workspace_dir)
    end

    return clients[1]
end

---@param config vim.lsp.ClientConfig
---@param cmd string[]
---@param workspace_dir string
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.PublicClient
function M.setup(config, cmd, workspace_dir)
    local mappers = make_path_mappers(workspace_dir)
    local rpc_client = rpc.wrap_cmd(config, cmd, lsp_uri_mappings, function(ctx, value)
        local mapper = mappers[ctx.direction]
        if not mapper then
            log.exception('Invalid direction: %s', ctx.direction)
        end
        return map_uri(mapper, ctx, value)
    end)

    local info = cache.get(workspace_dir)

    vim.api.nvim_create_autocmd('BufAdd', {
        desc = 'Attach LSP client to docker:// buffer',
        group = augroup,
        pattern = string.format('docker:/%s*', info.container_name),
        callback = function(o)
            local client = get_lsp_client_by_config(config, workspace_dir)
            if client then
                log.debug('Attaching clinet %s (%s) to buffer %s', client.id, client.config.name, o.buf)
                vim.lsp.buf_attach_client(o.buf, client.id)
            end
        end,
    })

    return rpc_client
end

return M
