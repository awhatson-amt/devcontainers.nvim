local M = {}

-- Later processed by system umask
local perms_rw = tonumber('666', 8)
local _perms_rwx = tonumber('777', 8)

---@type table<string, integer>
M.file_descriptors = {}

vim.api.nvim_create_autocmd('VimLeave', {
    group = vim.api.nvim_create_augroup('devcontainers.log.fsio', { clear = true }),
    callback = function()
        for _, fd in pairs(M.file_descriptors) do
            pcall(vim.uv.fs_close, fd)
        end
    end
})

-- Flush periodically in case of some slow buffering (does not seem to be needed?)
M.flush_timeout_ms = 500
local flush_timer = vim.uv.new_timer()
local flush_pending = false
local flush_pending_fds = {}

local function no_op() end

local function flush()
    for fd, _ in pairs(flush_pending_fds) do
        -- use async version as we don't need to wait
        pcall(vim.uv.fs_fsync, fd, no_op)
        flush_pending_fds[fd] = nil
    end
    flush_pending = false
end

local function flush_later(fd)
    flush_pending_fds[fd] = true
    if flush_pending then
        return
    end
    flush_pending = true
    flush_timer:start(M.flush_timeout_ms, 0, flush)
end

---@param path string
function M.open(path)
    if M.file_descriptors[path] then
        return M.file_descriptors[path]
    end
    local fd = vim.uv.fs_open(path, 'a', perms_rw)
    if fd then
        M.file_descriptors[path] = fd
        -- add newline when starting new log to make it easier to find the start
        M.write(fd, '\n')
    else
        vim.notify_once(string.format('Could not create log file "%s"', path), vim.log.levels.ERROR)
    end
    return fd
end

function M.write(fd, text)
    vim.uv.fs_write(fd, text)
    flush_later(fd)
end

return M
