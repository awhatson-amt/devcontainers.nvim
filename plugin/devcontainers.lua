local augroup = vim.api.nvim_create_augroup('devcontainers', { clear = true })

local function get_log_path()
    return require('devcontainers.log')().path
end

vim.api.nvim_create_user_command('DevcontainersLog', function(args)
    vim.cmd { cmd = 'edit', args = { get_log_path() }, mods = args.smods }
end, {})

vim.filetype.add {
    filename = {
        [get_log_path()] = 'devcontainers-log',
    },
}

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
