--- Docker events observer
local M = {}

local class = require('devcontainers.class')
local config = require('devcontainers.config')
local log = require('devcontainers.log')['docker.events']
local utils = require('devcontainers.utils')

---@class devcontainers.docker.Event
---@field Type string
---@field Action string
---@field Actor table
---@field scope string
---@field time number
---@field timeNano number

---@class devcontainers.docker.ContainerEvent: devcontainers.docker.Event
---@field Type 'container'
---@field id string
---@field from string

--- Return true to unsubscribe
---@alias devcontainers.docker.EventCallback fun(event: devcontainers.docker.Event): boolean

---@class devcontainers.docker.EventListener
---@field proc vim.SystemObj
---@field buf string[]
---@field subscribers table<string, devcontainers.docker.EventCallback>
local EventListener = class('EventListener')
M.EventListener = EventListener

local SIG = {
  KILL = 9, -- Kill signal
  TERM = 15, -- Termination signal
}

---@type fun(): boolean
M.is_supported = utils.lazy(function()
    local cmd = utils.flatten(config.docker_cmd, 'events', '--help')
    local ret = vim.system(cmd):wait()
    local supported = ret.code == 0
    if not supported then
        log.notify.warn('`docker events` not supported')
    end
    return supported
end)

---@return devcontainers.docker.EventListener
function EventListener:new()
    local obj = setmetatable({
        buf = {},
        subscribers = {},
    }, self)
    obj:restart()
    return obj
end

function EventListener:_kill()
    if self.proc then
        self.proc:kill(SIG.TERM)
        self.proc:wait(100)
        self.proc = nil
    end
end

function EventListener:restart()
    self:_kill()
    local cmd = utils.flatten(config.docker_cmd, 'events', '--format', 'json')
    local on_stdout = vim.schedule_wrap(function(err, data)
        self:_on_stdout(err, data)
    end)
    local on_exit = vim.schedule_wrap(function(out)
        self:_on_exit(out)
    end)
    self.proc = vim.system(cmd, { text = true, stdout = on_stdout }, on_exit)
end

---@param err? string
---@param data? string
function EventListener:_on_stdout(err, data)
    if err or not data then
        log.error('stdout error: %s', err)
        return
    end
    while true do
        local newline = data:find('\n', 1, true)
        if not newline then
            break
        end
        table.insert(self.buf, data:sub(1, newline - 1))
        data = data:sub(newline + 1)
        local line = table.concat(self.buf)
        self.buf = {}
        self:_on_line(line)
    end
    table.insert(self.buf, data)
end

---@param line string
function EventListener:_on_line(line)
    local ok, event = pcall(vim.json.decode, line)
    if not ok then
        log.error('could not decode JSON: %s', vim.inspect(line))
        return
    else
        self:_on_event(event)
    end
end

---@param event devcontainers.docker.Event
function EventListener:_on_event(event)
    log.trace('event %s', utils.lazy_inspect_oneline(event))
    for id, cb in pairs(self.subscribers) do
        local ok, err = pcall(cb, event)
        if not ok then
            log.error('callback with id=%s failed: %s', id, err)
            self.subscribers[id] = nil
        end
    end
end

---@param id string
---@param cb? devcontainers.docker.EventCallback
function EventListener:subscribe(id, cb)
    self.subscribers[id] = cb
    if cb ~= nil then
        log.trace('subscribed: %s', id)
    else
        log.trace('unsubscribed: %s', id)
    end
end

---@param out vim.SystemCompleted
function EventListener:_on_exit(out)
    log.error('exit: code=%s signal=%s stderr:\n%s', out.code, out.signal, out.stderr)
end

---@type devcontainers.docker.EventListener?
M._event_listener = nil

---@return devcontainers.docker.EventListener
function M.get()
    if not M._event_listener then
        M._event_listener = EventListener:new()
    end
    return M._event_listener
end

---@param id string unique identifier for this observer, replaces previous one if it exists
---@param cb? devcontainers.docker.EventCallback pass nil to unsubscribe
---@return boolean result false if not supported
function M.subscribe(id, cb)
    if not M.is_supported() then
        return false
    end
    M.get():subscribe(id, cb)
    return true
end

return M
