local M = {}

function M.on_new_config(config, root_dir)
    local manager = require('devcontainers.manager')
    local utils = require('devcontainers.utils')
    local log = require('devcontainers.log')()

    if not manager.is_workspace_dir(root_dir) then
        log.trace('on_new_config(%s): not a workspace dir: %s', config.name, root_dir)
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

    -- Update command to start in devcontainer
    config.cmd = vim.list_extend({ 'devcontainer', 'exec', '--workspace-folder', root_dir }, config.cmd)
    log.trace('on_new_config(%s): cmd=%s', config.name, utils.lazy_inspect(config.cmd))

    -- Setup path mappings
    require('devcontainers.paths').patch_config(config, root_dir)
    log.trace('on_new_config(%s): added path translation', config.name)
end

function M.open_log()
    local log = require('devcontainers.log')()
    vim.cmd.edit(log.path)
end

return M
