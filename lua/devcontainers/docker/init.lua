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

---@param container_name string
---@param abspath string
---@return string
function M.uri_from_container_name(container_name, abspath)
    assert(vim.startswith(abspath, '/'), 'Invalid abspath when constructing docker URI')
    if not vim.startswith(container_name, '/') then
        log.warn('Container name does not start with "/" (adding): %s', container_name)
        container_name = '/' .. container_name
    end
    return string.format('docker:/%s%s', container_name, abspath)
end

local DOCKER_URI_PATTERN = '^docker:/(/[^/]*)(/.*)'

---@param uri string
---@return string? container
---@return string? path
function M.parse_uri(uri)
    local container, path = uri:match(DOCKER_URI_PATTERN)
    return container, path
end

return M
