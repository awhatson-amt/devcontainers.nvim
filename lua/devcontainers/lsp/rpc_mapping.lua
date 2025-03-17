local M = {}

local meta_model = require('devcontainers.lsp.meta_model')
local OperationTree = require('devcontainers.lsp.operation_tree').OperationTree
local log = require('devcontainers.log').rpc

local model_ctx = meta_model.Context:new(meta_model.load())

---@alias devcontainers.rpc.Direction 'server2client'|'client2server'
---@class devcontainers.rpc.PerDirection<T>: { server2client: T, client2server: T }

---@alias devcontainers.rpc.Mappings devcontainers.rpc.PerDirection<devcontainers.rpc.DirectionMappings>

---@class devcontainers.rpc.DirectionMappings lookups by method
---@field request_params table<string, devcontainers.OperationTree>
---@field request_result table<string, devcontainers.OperationTree>
---@field notification_params table<string, devcontainers.OperationTree>

---@class devcontainers.rpc.MappingContext
---@field method string
---@field direction devcontainers.rpc.Direction
---@field type 'request_params'|'request_result'|'notification_params'
---@field tree devcontainers.OperationTree

---@alias devcontainers.rpc.MappingFn fun(ctx: devcontainers.rpc.MappingContext, value: any)

---@return devcontainers.rpc.DirectionMappings
local function new_dir_mappings()
    return {
        request_params = {},
        request_result = {},
        notification_params = {},
    }
end

---@param item_filter fun(item: devcontainers.LspTypeIter.Item): boolean should only match on basic (leaf) items!
---@return devcontainers.rpc.Mappings
function M.make_mappings(item_filter)
    ---@type devcontainers.rpc.Mappings
    local mappings = {
        server2client = new_dir_mappings(),
        client2server = new_dir_mappings(),
    }

    ---@param method string
    ---@param messageDirection LspMetaModel.MessageDirection
    ---@param data_type LspMetaModel.Type
    ---@param store_to 'request_params'|'request_result'|'notification_params'
    local function add_data_type(method, messageDirection, data_type, store_to)
        ---@type devcontainers.OperationTree[]
        local trees = {}

        for item, visitor in model_ctx:iter_types(data_type) do
            assert(item)
            if item_filter(item) then
                local tree = assert(OperationTree.from_path(model_ctx, visitor.stack))
                table.insert(trees, tree)
            end
        end

        if next(trees) then
            local tree = OperationTree.merged(unpack(trees)):simplified()

            if messageDirection == 'both' or messageDirection == 'clientToServer' then
                assert(not mappings.client2server[store_to][method], method)
                mappings.client2server[store_to][method] = tree
            end
            if messageDirection == 'both' or messageDirection == 'serverToClient' then
                assert(not mappings.server2client[store_to][method], method)
                mappings.server2client[store_to][method] = tree
            end
        end
    end

    for _, request in ipairs(model_ctx.model.requests) do
        -- TODO: request.params/notification.params may be an array of types?
        if request.params then
            add_data_type(request.method, request.messageDirection, request.params, 'request_params')
        end
        add_data_type(request.method, request.messageDirection, request.result, 'request_result')
    end
    for _, notification in ipairs(model_ctx.model.notifications) do
        if notification.params then
            add_data_type(notification.method, notification.messageDirection, notification.params, 'notification_params')
        end
    end

    return mappings
end

--- Timings in milliseconds
M.stats = {
    min = math.huge,
    max = 0,
    total = 0,
    count = 0,
}

function M.show_stats()
    print(string.format(
        'count: %d\nmean: %.3f ms\nmax: %.3f ms\nmin: %.3f ms\n',
        M.stats.count,
        M.stats.total / M.stats.count,
        M.stats.max,
        M.stats.min
    ))
end

---@generic T: function
---@param fn T
---@return T
local function timed(fn)
    return function(...)
        local start = vim.uv.hrtime()
        local value = fn(...)
        local elapsed = vim.uv.hrtime() - start

        local ms = elapsed / 1e6
        M.stats.count = M.stats.count + 1
        M.stats.min = math.min(M.stats.min, ms)
        M.stats.max = math.max(M.stats.max, ms)
        M.stats.total = M.stats.total + ms

        return value
    end
end

---@generic T
---@param value T
---@param fn devcontainers.rpc.MappingFn
---@param ctx devcontainers.rpc.MappingContext .tree can be nil
---@return T
local function apply(value, fn, ctx)
    if value ~= nil and ctx.tree ~= nil then
        local ok, new_value = pcall(ctx.tree.apply, ctx.tree, function(v)
            return fn(ctx, v)
        end, value)
        if ok then
            value = new_value
        else
            local err = new_value
            log.error('%s:\nmethod=%s, direction=%s type=%s, tree=%s,\nvalue=%s', err, ctx.method, ctx.direction, ctx.type, ctx.tree, vim.inspect(value))
        end
    end
    return value
end

apply = timed(apply)

---@param dispatchers vim.lsp.rpc.Dispatchers
---@param mappings devcontainers.rpc.DirectionMappings
---@param fn devcontainers.rpc.MappingFn
---@return vim.lsp.rpc.Dispatchers
function M.wrap_server_to_client(dispatchers, mappings, fn)
    ---@type vim.lsp.rpc.Dispatchers
    return {
        notification = function(method, params)
            log.trace('server2client:notification:%s', method)
            params = apply(params, fn, {
                method = method,
                direction = 'server2client',
                type = 'notification_params',
                tree = mappings.notification_params[method]
            })
            return dispatchers.notification(method, params)
        end,
        server_request = function(method, params)
            log.trace('server2client:request:%s', method)
            params = apply(params, fn, {
                method = method,
                direction = 'server2client',
                type = 'request_params',
                tree = mappings.request_params[method]
            })
            local result, err = dispatchers.server_request(method, params)
            if not err then
                log.trace('server2client:response:%s', method)
                result = apply(result, fn, {
                    method = method,
                    direction = 'client2server', -- reversed
                    type = 'request_result',
                    tree = mappings.request_result[method]
                })
            end
            return result, err
        end,
        on_exit = function(code, signal)
            log.trace('server2client:on_exit: code=%s signal=%s', code, signal)
            return dispatchers.on_exit(code, signal)
        end,
        on_error = function(code, err)
            log.trace('server2client:on_error: code=%s err=%s', code, err)
            return dispatchers.on_error(code, err)
        end,
    }
end

---@param rpc vim.lsp.rpc.PublicClient
---@param mappings devcontainers.rpc.DirectionMappings
---@param fn devcontainers.rpc.MappingFn
---@return vim.lsp.rpc.PublicClient
function M.wrap_client_to_server(rpc, mappings, fn)
    ---@type vim.lsp.rpc.PublicClient
    return {
        request = function(method, params, callback, notify_reply_callback)
            log.trace('client2server:request:%s', method)
            params = apply(params, fn, {
                method = method,
                direction = 'client2server',
                type = 'request_params',
                tree = mappings.request_params[method]
            })
            return rpc.request(method, params, function(err, result)
                log.trace('client2server:response:%s', method)
                if not err then
                    result = apply(result, fn, {
                        method = method,
                        direction = 'server2client', -- reversed
                        type = 'request_result',
                        tree = mappings.request_result[method]
                    })
                end
                return callback(err, result)
            end, notify_reply_callback)
        end,
        notify = function(method, params)
            log.trace('client2server:notify:%s', method)
            params = apply(params, fn, {
                method = method,
                direction = 'client2server',
                type = 'notification_params',
                tree = mappings.notification_params[method]
            })
            return rpc.notify(method, params)
        end,
        is_closing = function()
            log.trace('client2server:is_closing')
            return rpc.is_closing()
        end,
        terminate = function()
            log.trace('client2server:terminate')
            return rpc.terminate()
        end,
    }
end

---@param config vim.lsp.ClientConfig
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.PublicClient
local function cmd_to_rpc(config)
    local cmd = config.cmd
    if type(cmd) == 'function' then
        return cmd
    end
    return function(dispatchers)
        return vim.lsp.rpc.start(cmd, dispatchers, {
            cwd = config.cmd_cwd,
            env = config.cmd_env,
            detached = config.detached,
        })
    end
end

---@param config vim.lsp.ClientConfig
---@param mappings devcontainers.rpc.Mappings
---@param fn devcontainers.rpc.MappingFn
function M.patch_config(config, mappings, fn)
    local start_rpc = cmd_to_rpc(config)
    config.cmd = function(dispatchers)
        dispatchers = M.wrap_server_to_client(dispatchers, mappings.server2client, fn)
        local rpc = start_rpc(dispatchers)
        return M.wrap_client_to_server(rpc, mappings.client2server, fn)
    end
end

return M
