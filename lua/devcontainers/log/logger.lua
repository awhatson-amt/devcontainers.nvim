local M = {}

---@alias devcontainers.LogLevel 'trace'|'debug'|'info'|'warn'|'error'|'off'

---@class devcontainers.Logger.Config
---@field level? devcontainers.LogLevel
---@field path? string defaults to <stdpath-log>/<plugin_name>.log
---@field timestamp? string timestamp format used when logging to file
---@field timestamp_append? 'ms'|'us' append milli-/microseconds after formatted timestamp
---@field max_length? integer trim messages longer than given length

--- Wrapper around vim.notify that also logs
---@class devcontainers.Logger.Notify
---@field trace fun(...)
---@field debug fun(...)
---@field info fun(...)
---@field warn fun(...)
---@field error fun(...)
---@field trace_once fun(...)
---@field debug_once fun(...)
---@field info_once fun(...)
---@field warn_once fun(...)
---@field error_once fun(...)

---@class devcontainers.Logger
---@field name string defaults to ''
---@field notify_title? string
---@field prefix string
---@field level integer
---@field path string
---@field timestamp string
---@field timestamp_ms boolean
---@field timestamp_us boolean
---@field max_length integer
---@field notify devcontainers.Logger.Notify
---@field trace fun(...)
---@field debug fun(...)
---@field info fun(...)
---@field warn fun(...)
---@field error fun(...)
---@field exception fun(...) invokes error(string.format(...)) + logs to file as ERROR
---@field _fd? integer file descriptor
---@field _file_ok? boolean file open status
local Logger = {}
Logger.__index = Logger
M.Logger = Logger

---@type table<devcontainers.LogLevel, integer>
Logger.levels = {
    trace = vim.log.levels.TRACE,
    debug = vim.log.levels.DEBUG,
    info = vim.log.levels.INFO,
    warn = vim.log.levels.WARN,
    error = vim.log.levels.ERROR,
    off = vim.log.levels.OFF,
}

---@type table<integer, devcontainers.LogLevel>
Logger.level2name = {}
for name, value in pairs(Logger.levels) do
    Logger.level2name[value] = name
end

---@type table<integer, string>
Logger.level2name_upper = {}
for name, value in pairs(Logger.levels) do
    Logger.level2name_upper[value] = name:upper()
end

---@param level integer
---@return string?
function Logger:_log(level, ...)
    -- Return early if there is nothing to do
    if level < self.level then
        return
    end

    local n = select('#', ...)
    if n == 0 then
        error('Missing arguments to log()')
    end

    -- Avoid calling string.format if there are no format args
    local msg = assert(n == 1 and select(1, ...) or string.format(...))

    if #msg > self.max_length then
        msg = string.format('%s…', msg:sub(1, self.max_length - 1))
    end

    local fsio = require('devcontainers.log.fsio')

    if self._file_ok == nil then -- lazy open file
        self._fd = fsio.open(self.path)
        self._file_ok = self._fd ~= nil
    end

    if self._fd then -- log if file is ok
        local sec, us = vim.uv.gettimeofday()
        local timestamp = os.date(self.timestamp, sec)

        local timestamp_append
        if self.timestamp_ms then
            timestamp_append = string.format('.%03d', math.floor(us / 1000))
        elseif self.timestamp_us then
            timestamp_append = string.format('.%06d', us)
        end

        local text = string.format('[%s%s|%s] %s%s\n', timestamp, timestamp_append or '', self.level2name_upper[level], self.prefix, msg)
        fsio.write(self._fd, text)
    end

    return msg
end

function Logger:_notify(level, ...)
    local msg = self:_log(level, ...)
    vim.notify(msg, level, { title = self.notify_title })
end

function Logger:_notify_once(level, ...)
    local msg = self:_log(level, ...)
    vim.notify_once(msg, level, { title = self.notify_title })
end

---@param plugin_name string
---@param name string
---@param config devcontainers.Logger.Config
---@return devcontainers.Logger
function Logger:new(plugin_name, name, config)
    local o = setmetatable({
        name = assert(name),
        level = assert(self.levels[config.level]),
        timestamp = assert(config.timestamp),
        timestamp_ms = config.timestamp_append == 'ms',
        timestamp_us = config.timestamp_append == 'us',
        max_length = config.max_length,
        path = assert(config.path),
    }, self)

    o.prefix = o.name == '' and '' or string.format('%s: ', o.name)
    o.notify_title = o.name == '' and plugin_name or string.format('%s.%s', plugin_name, o.name)
    o.notify = {}

    -- Pre-compute log functions
    for level, value in pairs(self.levels) do
        if level ~= 'off' then
            o[level] = function(...)
                return o:_log(value, ...)
            end
            o.notify[level] = function(...)
                return o:_notify(value, ...)
            end
            o.notify[level .. '_once'] = function(...)
                return o:_notify_once(value, ...)
            end
        end
    end
    o.exception = function(...)
        error(o.error(...))
    end

    return o
end

---@param level devcontainers.LogLevel|integer
function Logger:set_level(level)
    if type(level) ~= 'number' then
        level = assert(self.levels[level], 'Invalid value for log level')
    end
    self.level = level
end

---@param level devcontainers.LogLevel|integer
function Logger:level_enabled(level)
    if type(level) ~= 'number' then
        level = assert(self.levels[level], 'Invalid value for log level')
    end
    return level >= self.level
end

local default_config = {
    level = 'warn',
    timestamp = '%F %H:%M:%S',
    timestamp_append = 'us',
    max_length = 512,
}

---@class devcontainers.LoggerRegistry: { [string]: devcontainers.Logger }
---@overload fun(name?: string): devcontainers.Logger

---@param plugin_name string
---@param config? devcontainers.Logger.Config
---@return devcontainers.LoggerRegistry
function M.make_registry(plugin_name, config)
    vim.validate('plugin_name', plugin_name, 'string')
    vim.validate('config', config, 'table', true)
    config = vim.tbl_extend('force', default_config, {
        path = vim.fs.joinpath(vim.fn.stdpath('log'), plugin_name .. '.log')
    }, config or {})
    return setmetatable({}, {
        __index = function(t, name)
            t[name] = Logger:new(plugin_name, name, config)
            return assert(rawget(t, name))
        end,
        __call = function(t, name)
            name = name or ''
            return t[name]
        end,
    })
end

return M
