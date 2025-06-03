---@class devcontainers.Config
local default = {
    ---@type devcontainers.Logger.Config?
    log = {
        level = 'warn',
    },
    ---@type string?
    lsp_version = '3.17',
    ---@type string|string[]?
    docker_cmd = 'docker',
    ---@type string|string[]?
    devcontainers_cli_cmd = 'devcontainer',
    --- Filter automiatically-added LSP protocol extensions
    ---@type devcontainers.lsp.ExtensionsFilter?
    lsp_extensions_filter = nil,
}

---@type devcontainers.Config
local config = vim.deepcopy(default, true)

---@class devcontainers.config: devcontainers.Config
local M = {}

function M.setup(opts)
    local new = vim.tbl_deep_extend('force', default, opts or {})
    for key, _ in pairs(config) do
        config[key] = nil
    end
    for key, val in pairs(new) do
        config[key] = val
    end
end

---@type devcontainers.config
return setmetatable(M, {
    __index = config,
    __newindex = function()
        error('Trying to modify config table. Use config.setup().')
    end,
})
