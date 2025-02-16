local file = assert(io.open('/tmp/devcontainers.nvim.log', 'w'))

---@param fmt string
---@vararg any
return function(fmt, ...)
    file:write(string.format(fmt, ...), '\n')
    file:flush()
end
