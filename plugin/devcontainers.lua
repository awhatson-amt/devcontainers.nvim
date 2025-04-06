local augroup = vim.api.nvim_create_augroup('devcontainers', { clear = true })

local log_filetype_added = false

vim.api.nvim_create_user_command('DevcontainersLog', function(args)
    -- Delay requiring the log module so that user has time to configure logging settings before its loaded
    local log_path = require('devcontainers.log')().path
    if not log_filetype_added then
        log_filetype_added = true
        vim.filetype.add {
            filename = {
                [log_path] = 'devcontainers-log',
            },
        }
    end
    vim.cmd { cmd = 'edit', args = { log_path }, mods = args.smods }
end, {})

vim.api.nvim_create_autocmd({ 'BufNew', 'BufReadPre', 'BufReadPost', 'BufAdd' }, {
    group = augroup,
    pattern = 'docker://*',
    callback = function(args)
        local log = require('devcontainers.log').plugin
        log.trace('%s matched docker:// for buf=%s', args.event, args.buf)
        if args.event == 'BufNew' then
            vim.bo[args.buf].buftype = 'nofile'
        elseif args.event == 'BufAdd' then
            vim.bo[args.buf].modifiable = false
        end
    end
})
