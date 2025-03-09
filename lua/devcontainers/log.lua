local file = assert(io.open('/tmp/devcontainers.nvim.log', 'w'))

---@param module string
return function(module)
    local prefix = string.format('[%s] ', module)
    ---@param fmt string
    ---@vararg any
    return function(fmt, ...)
        file:write(prefix, string.format(fmt, ...), '\n')
        file:flush()
    end
end
