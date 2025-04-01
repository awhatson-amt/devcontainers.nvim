local M = {}

function M.setup()
    -- TODO: config
end

function M.on_new_config(config, root_dir)
    local manager = require('devcontainers.manager')
    local utils = require('devcontainers.utils')
    local cli = require('devcontainers.cli')
    local log = require('devcontainers.log')()

    log.trace('on_new_config(%s): root_dir=%s, cmd=%s, cmd_env=%s', config.name, root_dir, utils.lazy_inspect_oneline(config.cmd), utils.lazy_inspect_oneline(config.cmd_env))

    if not manager.is_workspace_dir(root_dir) then
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

    local success = manager.ensure_up(root_dir)
    if not success then
        log.error('Could not start devcontainer for %s in %s', config.name, root_dir)
        return
    end

    -- Un-sanitize command.
    -- nvim-lspconfig calls vim.fn.exepath on cmd[1], but in devcontainer we want to use what is available in PATH.
    config.cmd[1] = vim.fs.basename(config.cmd[1])

    -- Test whether this server can even be started inside devcontainer, otherwise leave the config as-is
    -- TODO: make the test configurable, allow users to exclude/include certain LSPs
    local test_cmd = vim.list_slice(config.cmd)
    table.insert(test_cmd, '--help')
    log.trace('Testing %s LSP in devcontainer "%s" with cmd: %s', config.name, root_dir, utils.lazy_inspect_oneline(test_cmd))
    local ok = pcall(cli.exec, root_dir, test_cmd, { timeout = 3000 })
    if not ok then
        log.error('Could not start %s LSP in devcontainer, falling back to local: %s', config.name, root_dir)
        return
    end

    -- Update command to start in devcontainer
    config.cmd = cli.cmd(root_dir, 'exec', unpack(config.cmd))
    log.debug('on_new_config(%s): cmd=%s', config.name, utils.lazy_inspect_oneline(config.cmd))

    -- Setup path mappings
    require('devcontainers.paths').patch_config(config, root_dir)
    log.debug('on_new_config(%s): added path translation', config.name)
end

return M
