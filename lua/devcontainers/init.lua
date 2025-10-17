local M = {}

---@param opts? devcontainers.Config
function M.setup(opts)
    opts = opts or {}
    require('devcontainers.config').setup(opts)
end

--- Handler for lspconfig on_new_config callback to start LSP client in devcontainer.
---
--- This will check whether the devcontainers.json exists and will try to start the container.
--- If the container starts, the client configuration will be updated to run inside the container
--- with proper path mapping for all RPC communication.
---
---@param config vim.lsp.ClientConfig
---@param root_dir string
function M.on_new_config(config, root_dir)
    local manager = require('devcontainers.manager')
    local utils = require('devcontainers.utils')
    local cli = require('devcontainers.cli')
    local log = require('devcontainers.log')()

    log.trace('on_new_config(%s): root_dir=%s, cmd=%s, cmd_env=%s', config.name, root_dir, utils.lazy_inspect_oneline(config.cmd), utils.lazy_inspect_oneline(config.cmd_env))

    local workspace_dir = manager.find_workspace_dir(root_dir)
    if not workspace_dir then
        log.debug('on_new_config(%s): not a workspace dir: %s', config.name, root_dir)
        return
    end

    if type(config.cmd) ~= 'table' then
        log.notify.error('Could not attach: config.cmd is not a table: %s at %s', config.name, root_dir)
        return
    end

    if config.cmd[1] == 'devcontainer' then
        log.notify.error('Could not attach: config.cmd already starts with "devcontainer": %s at %s', config.name, root_dir)
        return
    end

    local success = manager.ensure_up(workspace_dir)
    if not success then
        log.error('Could not start devcontainer for %s in %s', config.name, root_dir)
        return
    end

    -- Un-sanitize command.
    -- nvim-lspconfig calls vim.fn.exepath on cmd[1], but in devcontainer we want to use what is available in PATH.
    config.cmd[1] = vim.fs.basename(config.cmd[1])

    -- Test whether this server can even be started inside devcontainer, otherwise leave the config as-is
    -- TODO: make the test configurable, allow users to exclude/include certain LSPs
    local test_cmd = vim.list_slice(config.cmd --[[@as string[] ]])
    table.insert(test_cmd, '--help')
    log.trace('Testing %s LSP in devcontainer "%s" with cmd: %s', config.name, root_dir, utils.lazy_inspect_oneline(test_cmd))
    local ok = pcall(cli.exec, workspace_dir, test_cmd, { timeout = 3000 })
    if not ok then
        log.error('Could not start %s LSP in devcontainer, falling back to local: %s', config.name, root_dir)
        return
    end

    -- Update command to start in devcontainer
    config.cmd = cli.cmd(workspace_dir, 'exec', unpack(config.cmd --[[@as string[] ]]))
    log.debug('on_new_config(%s): cmd=%s', config.name, utils.lazy_inspect_oneline(config.cmd))

    -- Setup path mappings
    config.cmd = require('devcontainers.paths').setup(config, workspace_dir)
    log.debug('on_new_config(%s): added path translation', config.name)
end

---@return boolean
---@return string?
local function validate_cmd(cmd)
    if type(cmd) ~= 'table' or type(cmd[1]) ~= 'string' then
        return false, '`cmd` must be non-empty string[]'
    end
    if cmd[1] == 'devcontainers' then
        return false, '`cmd` should not run `devcontainer` cli'
    end
    return true
end

---@class devcontainers.make_cmd.opts
---@field no_local_fallback? boolean Run server without container as a fallback
---@field before_start? fun(config: vim.lsp.ClientConfig) callback invoked (in coroutine) after devcontainer up but before server start, can error() to stop

---@param get_cmd fun(config: vim.lsp.ClientConfig): string[]
---@param opts? devcontainers.make_cmd.opts
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers, config: vim.lsp.ClientConfig): vim.lsp.rpc.PublicClient
local function make_lsp_cmd(get_cmd, opts)
    opts = opts or {}

    ---@param dispatchers vim.lsp.rpc.Dispatchers
    ---@param config vim.lsp.ClientConfig
    ---@return vim.lsp.rpc.PublicClient
    return function(dispatchers, config)
        vim.validate('config.root_dir', config.root_dir, 'string', 'At this point config.root_dir should have already been resolved')

        local cmd = get_cmd(config)
        vim.validate('cmd', cmd, validate_cmd)

        local manager = require('devcontainers.manager')
        local utils = require('devcontainers.utils')
        local cli = require('devcontainers.cli')
        local log = require('devcontainers.log')()
        local paths = require('devcontainers.paths')
        local rpc = require('devcontainers.lsp.rpc')

        log.trace('make_cmd()(%s): root_dir=%s, cmd=%s, cmd_env=%s', config.name, config.root_dir, utils.lazy_inspect_oneline(cmd), utils.lazy_inspect_oneline(config.cmd_env))

        -- Store some debug information in the config
        if config._devcontainers then
            log.exception('Client has already been wrapped in devcontainers.lsp_cmd: name=%s root_dir=%', config.name, config.root_dir)
        end
        config._devcontainers = {}---@diagnostic disable-line:inject-field

        -- Make fallback cmd that tries to start client without container
        local function make_local_fallback_cmd(reason)
            if opts.no_local_fallback then
                log.exception('could start in devcontainer: name=%s, root_dir=%s: %s', config.name, config.root_dir, reason)
            end
            log.warn('falling back to local cmd: name=%s, root_dir=%s: %s', config.name, config.root_dir, reason)
            config._devcontainers.cmd = cmd
            return rpc.cmd_to_rpc(config, cmd)(dispatchers)
        end

        local workspace_dir = manager.find_workspace_dir(config.root_dir)
        if not workspace_dir then
            return make_local_fallback_cmd('not a workspace dir')
        end

        local final_cmd = cli.cmd(workspace_dir, 'exec', unpack(cmd))
        config._devcontainers.original_cmd = cmd
        config._devcontainers.cmd = final_cmd

        local rpc_client, resolve = rpc.make_stub()

        ---@async
        ---@return vim.lsp.rpc.PublicClient
        local function initialize_devcontainer()
            local success = manager.ensure_up(workspace_dir)
            if not success then
                log.exception('Could not start devcontainer for %s in %s', config.name, config.root_dir)
            end

            if opts.before_start then
                opts.before_start(config)
            end

            return paths.setup(config, final_cmd, workspace_dir)(dispatchers)
        end

        -- Start a couroutine that will resolve our stub when devcontainer starts (or fails)
        coroutine.wrap(function()
            local ok, rpc_or_err = xpcall(initialize_devcontainer, debug.traceback)
            if ok then
                resolve(rpc_or_err)
            else
                log.notify.error('LSP setup failed: %s', rpc_or_err or '?')
                resolve(nil, rpc_or_err) ---@diagnostic disable-line:param-type-mismatch
            end
        end)()

        return rpc_client
    end
end

---@alias devcontainers.ClientCmd string[]|(fun(config: vim.lsp.ClientConfig): string[])

--- Make `cmd` for vim.lsp.config that will start LSP server using the given command inside a devcontainer
---
--- This uses the function variant of `vim.lsp.ClientConfig.cmd`, to inspect the client configuration before
--- the LSP server is spawned. If there is no `.devcontainer/` in `root_dir` then `cmd` will be run locally
--- without starting devcontainer. Otherwise a devcontainer will be started if needed and when it's up the LSP
--- server will be run inside it with whole RPC communication translated to fix filesystem paths.
---
--- Example usage:
--- ```lua
--- vim.lsp.config('clangd', { cmd = require('devcontainers').lsp_cmd({ 'clangd' }) })
--- ```
---
--- This integrates with `devcontainers.local_cmd` to allow using different `cmd` dynamically when the started
--- language server's `root_dir` is under specific directory, e.g.
--- ```lua
--- require('devcontainers.local_cmd').set('/some/root/dir', 'clangd', { 'clangd', '--query-driver=/usr/bin/arm-none-eabi-*' })
--- ```
--- Combined with 'exrc' option you can have per-directory local commands (just put the above in .nvim.lua).
---
---@param cmd devcontainers.ClientCmd
---@param opts? devcontainers.make_cmd.opts
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers, config: vim.lsp.ClientConfig): vim.lsp.rpc.PublicClient
function M.lsp_cmd(cmd, opts)
    return make_lsp_cmd(function(config)
        -- TODO: is there any way to just use the built-in 'exrc`? Using .nvim/lsp/*.lua doesn't seem to work
        -- Try to resolve local command registered for this directory
        local local_cmd = require('devcontainers.local_cmd')
        local used_cmd = local_cmd.get(config.root_dir, config.name) or cmd

        -- If it is a function that call it
        if vim.is_callable(used_cmd) then
            return used_cmd(config)
        end

        return used_cmd
    end, opts)
end

return M
