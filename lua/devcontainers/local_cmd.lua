local M = {}

---@alias devcontainers.local_cmd.RootDirectory string
---@alias devcontainers.local_cmd.ClientName string

--- First by client name because matching it is faster, then we will iterate over directories
---@type table<devcontainers.local_cmd.ClientName, table<devcontainers.local_cmd.RootDirectory, devcontainers.ClientCmd>>
local storage = {}

---@param root_dir string
---@param client_name string
---@param cmd devcontainers.ClientCmd
function M.set(root_dir, client_name, cmd)
    storage[client_name] = storage[client_name] or {}
    storage[client_name][vim.fs.normalize(root_dir)] = cmd
end

---@param dir string
---@param client_name string
---@return devcontainers.ClientCmd?
function M.get(dir, client_name)
    local client_storage = storage[client_name]
    if not client_storage then
        return
    end
    dir = vim.fs.normalize(dir)
    for root_dir, cmd in pairs(client_storage) do
        if vim.startswith(dir, root_dir) then
            return cmd
        end
    end
end

return M
