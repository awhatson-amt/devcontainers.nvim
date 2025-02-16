local M = {}

local log = require('devcontainers.log')

---@class devcontainers.Mapper
local Mapper = {}
Mapper.__index = Mapper

---@return devcontainers.Mapper
function Mapper:new()
    return setmetatable({}, self)
end

local function inspect(tbl)
    return vim.inspect(tbl, { newline = '' }):gsub(' +', ' ')
end

---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.Dispatchers
function Mapper:wrap_server_to_client(dispatchers)
    ---@type vim.lsp.rpc.Dispatchers
    return {
        notification = function(method, params)
            log('server2client:notification(%s, %s)', method, inspect(params))
            return dispatchers.notification(method, params)
        end,
        server_request = function(method, params)
            log('server2client:server_request(%s, %s)', method, inspect(params))
            return dispatchers.server_request(method, params)
        end,
        on_exit = function(code, signal)
            log('server2client:on_exit(%s, %s)', code, signal)
            return dispatchers.on_exit(code, signal)
        end,
        on_error = function(code, err)
            log('server2client:on_exit(%s, %s)', code, inspect(err))
            return dispatchers.on_error(code, err)
        end,
    }
end

---@param rpc vim.lsp.rpc.PublicClient
---@return vim.lsp.rpc.PublicClient
function Mapper:wrap_client_to_server(rpc)
    ---@type vim.lsp.rpc.PublicClient
    return {
        request = function(method, params, callback, notify_reply_callback)
            log('client2server:request(%s, %s)', method, inspect(params))
            return rpc.request(method, params, callback, notify_reply_callback)
        end,
        notify = function(method, params)
            log('client2server:notify(%s, %s)', method, inspect(params))
            return rpc.notify(method, params)
        end,
        is_closing = function()
            log('client2server:is_closing')
            return rpc.is_closing()
        end,
        terminate = function()
            log('client2server:terminate')
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
function Mapper:patch_config(config)
    log('patch_config(%s)', config.name)
    local start_rpc = cmd_to_rpc(config)
    config.cmd = function(dispatchers)
        dispatchers = self:wrap_server_to_client(dispatchers)
        local rpc = start_rpc(dispatchers)
        return self:wrap_client_to_server(rpc)
    end
end

---@param config vim.lsp.ClientConfig
---@param root_dir string
function Mapper:on_new_config(config, root_dir)
    self:patch_config(config)
end


local mapper = Mapper:new()

function M.setup()
    log('setup')

    local lspconfig_util = require('lspconfig.util')

    lspconfig_util.on_setup = lspconfig_util.add_hook_before(lspconfig_util.on_setup, function(config)
        log('on_setup(%s)', config.name)

        config.on_new_config = lspconfig_util.add_hook_after(config.on_new_config, function(config, root_dir)
            log('on_new_config(%s, %s)', config.name, root_dir)

            mapper:on_new_config(config, root_dir)
        end)
    end)
end

return M
