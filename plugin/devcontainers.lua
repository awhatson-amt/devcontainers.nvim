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
