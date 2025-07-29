local M = {}

---@vararg table
---@return table
function M.flatten(...)
    return vim.iter({ ... }):flatten(math.huge):totable()
end

function M.bind(fn, ...)
    local args = { ... }
    return function(...)
		local call_args = {}
		vim.list_extend(call_args, args)
		vim.list_extend(call_args, { ... })
        return fn(unpack(call_args))
    end
end

-- Wrap `fn` caching the result of its call. It won't recompute
-- `fn` unless `recompute_cond` returns true.
function M.cached(fn, recompute_cond)
    local cached
    return function(...)
        if cached == nil or recompute_cond(cached) then
            cached = fn(...)
            assert(cached ~= nil, 'cached: fn returned nil')
        end
        return cached
    end
end

-- Lazily evaluate a function, caching the result of the first call
-- for all subsequent calls ever.
function M.lazy(fn)
    return M.cached(fn, function()
        return false
    end)
end

---Create a callback that will resume currently running coroutine
---@return function
function M.coroutine_resume()
    local co = assert(coroutine.running())
    return function(...)
        local ret = { coroutine.resume(co, ...) }
        -- Re-raise errors with correct traceback
        local ok, err = unpack(ret)
        if not ok then
            if type(err) == 'string' then
                err = debug.traceback(co, err)
            end
            error(err)
        end
        return unpack(ret, 2)
    end
end

---@generic T
---@param fn T
---@param warning? string
---@return T
function M.as_coroutine(fn, warning)
    local co, is_main = coroutine.running()
    if not (co and not is_main) then
        log.warn('Not called from coroutine so wrapping%s', warning and (': ' .. warning) or '')
        fn = coroutine.wrap(fn)
    end
    return fn
end

--- Ensure we end up in a state in which we can use full API
---@async
function M.schedule()
    vim.schedule(M.coroutine_resume())
    coroutine.yield()
end

---@async
function M.schedule_if_needed()
    if vim.in_fast_event() then
        M.schedule()
    end
end

---@param opts? { prompt?: string, default?: string, completion?: string, highlight?: function }
function M.ui_input(opts)
    vim.ui.input(opts, M.coroutine_resume())
    return coroutine.yield()
end

---@class devcontainers.LazyToString
---@field args any[]
---@field tostring fun(value, ...): string
local LazyToString = {}

function LazyToString:__tostring()
    return self.tostring(vim.F.unpack_len(self.args))
end

--- Create wrapper that converts a value to string only when __tostring metamethod is invoked
---@param tostring fun(value, ...): string
function M.lazy_tostring(tostring, ...)
    return setmetatable({ tostring = tostring, args = vim.F.pack_len(...) }, LazyToString)
end

--- Create wrapper that calls vim.inspect lazily, only when __tostring metamethod is invoked
---@param value any
---@param opts? vim.inspect.Opts
function M.lazy_inspect(value, opts)
    return M.lazy_tostring(vim.inspect, value, opts)
end

local inspect_oneline = { newline = ' ', indent = '' }

---@param value any
---@param opts? vim.inspect.Opts
function M.lazy_inspect_oneline(value, opts)
    return M.lazy_inspect(value, opts and vim.tbl_extend('error', inspect_oneline, opts) or inspect_oneline)
end

---@generic T
---@param fn T
---@param on_time_ms fun(time_ms: number, ...)
---@return T
function M.timed(fn, on_time_ms)
    return function(...)
        local start = vim.uv.hrtime()
        local ret = { xpcall(fn, debug.traceback, ...) }
        local elapsed = vim.uv.hrtime() - start
        on_time_ms(elapsed / 1e6, ...)
        local ok = ret[1]
        if not ok then
            error(ret[2])
        end
        return unpack(ret, 2)
    end
end

--- Sync wrapper for vim.system that uses coroutine resume if running in a coroutine
---@param cmd string[] Command to execute
---@param opts? vim.SystemOpts
---@return vim.SystemCompleted
function M._system(cmd, opts)
    if coroutine.running() then
        local resume = M.coroutine_resume()
        vim.system(cmd, opts, resume)
        local result = vim.F.pack_len(coroutine.yield())
        M.schedule_if_needed()
        return vim.F.unpack_len(result)
    else
        return vim.system(cmd, opts):wait()
    end
end

M.system = M.timed(M._system, function(time_ms, cmd, _opts)
    local log = require('devcontainers.log')()
    log.trace('Command took %.3f ms: %s', time_ms, table.concat(cmd, ' '))
end)

---@param val number
function M.human_unit(val)
    -- local mid, prefixes = 7 {'a', 'f', 'p', 'n', 'μ', 'm', '', 'k', 'M', 'G', 'T', 'P', 'E'}
    -- Use only the ones that are "well-known"
    local mid, prefixes = 5, {'p', 'n', 'μ', 'm', '', 'k', 'M', 'G', 'T'}
    local magnitude = math.log10(math.abs(val))
    local i = math.floor(magnitude / 3) + mid
    local multiplier = math.pow(10, (i - mid) * 3)
    return val / multiplier, prefixes[i]
end

---@class devcontainers.Stats
local Stats = {}
Stats.__index = Stats

---@return devcontainers.Stats
function M.new_stats()
    return setmetatable({ min = math.huge, max = 0, total = 0, count = 0 }, Stats)
end

---@param ns number time in nanoseconds (result of vim.uv.hrtime)
function Stats:update(ns)
    -- we can keep using nanoseconds - max `number` integer precision is 2^53-1,
    -- so it won't wrap for 104.25 days of uptime
    self.total = self.total + ns
    self.count = self.count + 1
    self.min = math.min(self.min, ns)
    self.max = math.max(self.max, ns)
end

---@param fn function
function Stats:timeit(fn, ...)
    local start = vim.uv.hrtime()
    local ret = vim.F.pack_len(fn(...))
    self:update(vim.uv.hrtime() - start)
    return vim.F.unpack_len(ret)
end

---@generic T: function
---@param fn T
---@return T
function Stats:wrap_fn(fn)
    return function(...)
        return self:timeit(fn, ...)
    end
end

local function format_time(ns)
    return string.format('%.3f %ss', M.human_unit(ns / 1e9))
end

function Stats:__tostring()
    return string.format(
        'count=%d, mean=%s, min=%s, max=%s',
        self.count,
        format_time(self.total / self.count),
        format_time(self.min),
        format_time(self.max))
end

-- Not really needed right know
-- local function freeze(tbl)
--     return setmetatable({}, {
--         __index = tbl,
--         __newindex = function(_)
--             error('Attempt to modify read-only table')
--         end
--     })
-- end
--
-- local function deep_freeze(tbl)
--     local new = {}
--     for key, val in pairs(tbl) do
--         if type(val) == 'table' then
--             val = deep_freeze(val)
--         end
--         new[key] = val
--     end
--     return freeze(new)
-- end

return M
