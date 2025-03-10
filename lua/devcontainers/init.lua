local M = {}

function M.setup()
    local rpc = require('devcontainers.lsp.rpc_mapping')
    local log = require('devcontainers.log')('init')

    ---@param item devcontainers.LspTypeIter.Item
    local function is_uri(item)
        return item.kind == 'base' and (item.name == 'URI' or item.name == 'DocumentUri')
    end
    local mappings = rpc.make_mappings(is_uri)

    ---@param ctx devcontainers.rpc.MappingContext
    ---@param uri string
    ---@return string
    local function map_fn(ctx, uri)
        log('%s:%s:%s: "%s" ', ctx.method, ctx.direction, ctx.type, uri)
        return uri
    end

    local lspconfig_util = require('lspconfig.util')

    lspconfig_util.on_setup = lspconfig_util.add_hook_after(lspconfig_util.on_setup, function(config)
        config.on_new_config = lspconfig_util.add_hook_after(config.on_new_config, function(config, root_dir)
            rpc.patch_config(config, mappings, map_fn)
        end)
    end)
end

return M
