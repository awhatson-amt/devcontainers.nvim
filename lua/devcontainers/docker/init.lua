local M = {}

local config = require('devcontainers.config')
local utils = require('devcontainers.utils')
local log = require('devcontainers.log').docker

---@class devcontainer.docker.Inspect: table
---@field Id string
---@field Created string
---@field Path string
---@field Args string[]
---@field State table
---@field Image string
---@field Name string starts with "/"

---@param name_or_id string
---@return devcontainer.docker.Inspect
function M.inspect(name_or_id)
    local cmd = utils.flatten(config.docker_cmd, 'inspect', '--format', 'json', name_or_id)
    local result = utils.system(cmd)
    if result.code ~= 0 then
        log.exception('docker inspect failed for %s: %s', name_or_id, result.stderr)
    end
    local data = vim.json.decode(result.stdout)
    assert(type(data) == 'table' and #data == 1 and type(data[1]) == 'table')
    return data[1]
end

M.events = require('devcontainers.docker.events')

return M
