local M = {}

local class = require('devcontainers.class')
local docker_events = require('devcontainers.docker_events')
local log = require('devcontainers.log').devcontainer
local utils = require('devcontainers.utils')

---@class devcontainer.ensure_up.opts
---@field confirm? boolean ask before starting devcontainer
---@field test_cmd? string[] use custom command for testing if container is running

---@class devcontainer.up_status.success
---@field outcome 'success'
---@field containerId string
---@field remoteUser string
---@field remoteWorkspaceFolder string

---@class devcontainer.up_status.error
---@field outcome 'error'
---@field message string
---@field description string

---@alias devcontainer.up_status devcontainer.up_status.success|devcontainer.up_status.error

---@generic T
---@param fn T
---@param get_info fun(...): string
---@return T
local function timed(fn, get_info)
    return function(...)
        local start = vim.uv.hrtime()
        local ret = { pcall(fn, ...) }
        local elapsed = vim.uv.hrtime() - start
        log.debug('Time %.3f ms: %s', elapsed / 1e6, get_info(...))
        local ok = ret[1]
        if not ok then
            error(ret[2])
        end
        return unpack(ret, 2)
    end
end

local system = timed(utils.system, function(cmd, _)
    return table.concat(cmd, ' ')
end)

--- Run a long running task with overseer, parser JSONs from output
---@param cmd string[]
---@param opts? { name?: string, cwd?: string }
---@async
---@return { code: integer, result?: table }
local function overseer_task(cmd, opts)
    opts = opts or {}

    -- Because stderr/stdout are interleaved we must parse JSONs from output
    local overseer = require('overseer')
    local task = overseer.new_task {
        cmd = cmd,
        name = opts.name,
        cwd = opts.cwd,
        components = {
            'default',
            -- { 'on_output_parse', parser = { 'loop', { 'sequence', { 'extract_json' } } } },
            -- { 'on_output_parse', parser = { jsons = { { 'loop', { 'extract_json' } } } } },
            -- { 'on_output_parse', parser = { jsons = { 'extract_json' } } },
            {
                'on_output_parse',
                parser = {
                    'extract',
                    {
                        postprocess = function(data)
                            data.json = vim.F.npcall(vim.json.decode, data.json)
                        end,
                    },
                    '(%b{})',
                    'json',
                },
            },
        },
    }
    local resume = utils.coroutine_resume()
    task:subscribe('on_complete', resume)
    task:start()
    local result = coroutine.yield()
    task:unsubscribe('on_complete', resume)

    -- Use last non-empty JSONs as result
    local json
    for _, res in ipairs(task.result) do
        if res.json and res.json ~= vim.empty_dict() then
            json = res.json
        end
    end

    return {
        code = result.exit_code,
        result = json,
    }
end

---@param out vim.SystemCompleted
---@return boolean is_success
---@return devcontainer.up_status?
local function up_status(out)
    if out.code ~= 0 then
        return false
    end
    local info = vim.F.npcall(vim.json.decode, out.stdout)
    if not info then
        log.error('Could not decode JSON from %s', utils.lazy_inspect(out))
        return false
    end
    return info.outcome == 'success', info
end

--- TODO: order of insertion should be reflected when getting command
---@type table<string, fun(workspace_dir: string): (string[]|nil)>
M._up_cmd_overrides = {}

--- Can be used to override command used for 'devcontainer up'.
---@param id string unique ID for the callback
---@param get_cmd fun(workspace_dir: string): (string[]|nil)  return nil if not handling this workspace_dir
function M.devcontainer_up_override(id, get_cmd)
    M._up_cmd_overrides[id] = get_cmd
end

local function devcontainer_up_cmd(workspace_dir)
    for _, getter in pairs(M._up_cmd_overrides) do
        local cmd = getter(workspace_dir)
        if cmd then
            return cmd
        end
    end
    return { 'devcontainer', 'up', '--workspace-folder', workspace_dir }
end

---@param workspace_dir string
---@return { ok: boolean, error?: string, code: integer, status?: devcontainer.up_status }
local function devcontainer_up(workspace_dir)
    local cmd = devcontainer_up_cmd(workspace_dir)
    local ret
    if vim.F.npcall(require, 'overseer') then
        local out = overseer_task(cmd, { name = 'devcontainer up' })
        local ok = out.code == 0 and vim.tbl_get(out, 'result', 'outcome') == 'success'
        ret = {
            ok = ok,
            code = out.code,
            error = not ok and vim.inspect(out) or nil,
            status = out.result,
        }
    else
        local short_dir = vim.fn.pathshorten(workspace_dir)
        local notif = vim.notify(string.format('Starting devcontainer in %s', short_dir))
        local result = system(cmd)
        local ok, status = up_status(result)
        ret = {
            ok = ok,
            error = not ok and table.concat({result.stdout, result.stderr}, '\n') or nil,
            code = result.code,
            status = status
        }
        if ok then
            local msg = string.format('Starting devcontainer in %s: OK', short_dir)
            vim.notify(msg, nil, { replace = notif and notif.id })
        else
            local msg = string.format('Starting devcontainer in %s: FAILED: code=%d status=%s', short_dir, result.code, vim.inspect(status))
            vim.notify(msg, nil, { replace = notif and notif.id })
        end
    end
    if ret.ok then
        M.ContainerCache.cache[workspace_dir] = ret.status --[[@as devcontainer.up_status.success]]
    end
    return ret
end

devcontainer_up = timed(devcontainer_up, function(workspace_dir)
    return 'devcontainer-up: ' .. workspace_dir
end)

--- Mapping from workspace_dir to info
---@class devcontainer.ContainerCache
M.ContainerCache = class('ContainerCache')

---@type table<string, devcontainer.up_status.success>
M.ContainerCache.cache = setmetatable({}, {
    __index = function(_, workspace_dir)
        log.notify.info('Running devcontainer up to get container id ...')

        local result = devcontainer_up(workspace_dir)

        if not result.ok then
            log.exception('devcontainer up failed: %s', result.error)
        end

        return result.status
    end,
})

local DIR_CACHE = false
if DIR_CACHE then
    ---@type table<string, uv_timer_t>
    local dir_cache_clear = {}
    local dir_cache_clear_period = 3 * 1000

    ---@type table<string, string>
    M.ContainerCache.dir_cache = setmetatable({}, {
        __index = function(cache, workspace_dir)
            -- log.trace('Getting workspace_dir for: %s, cache=%s', workspace_dir, vim.inspect(cache))
            log.trace('Getting workspace_dir for: %s', workspace_dir)

            local result = system { 'devcontainer', 'read-configuration', '--workspace-folder', workspace_dir }
            if result.code ~= 0 then
                error(result.stderr)
            end

            local folder = assert(vim.json.decode(result.stdout).workspace.workspaceFolder)
            cache[workspace_dir] = folder

            -- Clear cache after short time
            if dir_cache_clear[workspace_dir] then
                dir_cache_clear[workspace_dir]:stop()
            else
                dir_cache_clear[workspace_dir] = vim.uv.new_timer()
            end
            log.trace('Starting clear cache timer for: %s', workspace_dir)
            dir_cache_clear[workspace_dir]:start(dir_cache_clear_period, 0, function()
                log.trace('Clearing workspace_dir cache for: %s', workspace_dir)
                cache[workspace_dir] = nil
                if dir_cache_clear[workspace_dir] then
                    dir_cache_clear[workspace_dir]:stop()
                    dir_cache_clear[workspace_dir] = nil
                end
            end)

            return rawget(cache, folder)
        end
    })
end

-- Invalidate entries when containers die
docker_events.subscribe('devcontainer.ContainerCache', function(event)
    if event.Type == 'container' and event.Action == 'die' then
        log.info('container_cache: %s died - removing', event.id)
        for workspace_dir, info in pairs(M.ContainerCache.cache) do
            if info.containerId == event.id then
                M.ContainerCache.cache[workspace_dir] = nil
            end
        end
    end
    return false
end)

---@param workspace_dir string
---@return devcontainer.up_status.success?
---@async
function M.ContainerCache:get(workspace_dir)
    return M.ContainerCache.cache[workspace_dir]
end

--- Get path to workspace directory inside container
---@param host_workspace_dir string workspace directory for which the devcontainer runs
function M.get_workspace_dir(host_workspace_dir)
    local cached_info = rawget(M.ContainerCache.cache, host_workspace_dir)
    if cached_info then
        assert(cached_info.remoteWorkspaceFolder)
        log.trace('Returing workspace_dir from cache: %s => %s', host_workspace_dir, cached_info.remoteWorkspaceFolder)
        return cached_info.remoteWorkspaceFolder
    end

    if DIR_CACHE then
        -- FIXME: this cache would need invalidation based on devcontainer.json
        local cached = rawget(M.ContainerCache.dir_cache, host_workspace_dir)
        if cached then
            log.trace('Returing workspace_dir from dir_cache: %s => %s', host_workspace_dir, cached)
        end
        return M.ContainerCache.dir_cache[host_workspace_dir]
    end

    -- log.debug('Getting workspace_dir for: %s: cache=%s', host_workspace_dir, vim.inspect(M.ContainerCache.cache))
    log.debug('Getting workspace_dir for: %s', host_workspace_dir)
    local result = system { 'devcontainer', 'read-configuration', '--workspace-folder', host_workspace_dir }
    if result.code ~= 0 then
        error(result.stderr)
    end
    return vim.json.decode(result.stdout).workspace.workspaceFolder
end

---@param workspace_dir string
---@param opts? devcontainer.ensure_up.opts
---@return devcontainer.up_status.success?
local function ensure_up(workspace_dir, opts)
    opts = opts or {}
    assert(coroutine.running())

    local short_dir = utils.bind(utils.lazy(vim.fn.pathshorten), workspace_dir)

    -- Check if container exists
    local echo = system(opts.test_cmd or { 'devcontainer', 'exec', '--workspace-folder', workspace_dir, 'echo' })
    if echo.code == 0 then
        return
    end

    -- Offer to start it
    if opts.confirm then
        local input = utils.ui_input {
            prompt = string.format('Devcontainer for %s not running, start? [y/N]: ', short_dir()),
        }
        if not (input and vim.tbl_contains({'y', 'yes'}, input:lower())) then
            return
        end
    end

    -- Start the devcontainer
    -- local notif = vim.notify(string.format('Starting devcontainer in %s', workspace_dir))
    local result = devcontainer_up(workspace_dir)

    return result.ok and result.status --[[@as devcontainer.up_status.success]] or nil

    -- if not result.ok then
    --     local msg = string.format('Starting devcontainer in %s: FAILED: code=%d status=%s', short_dir(), result.code, vim.inspect(result.status))
    --     vim.notify(msg, nil, { replace = notif and notif.id })
    --     return
    -- end
    --
    -- local msg = string.format('Starting devcontainer in %s: OK', workspace_dir)
    -- vim.notify(msg, nil, { replace = notif and notif.id })
    -- return result.status --[[@as devcontainer.up_status.success]]
end

---@type table<string, thread[]> threads to notify after ensure_up completed
local pending_ups = {}

--- Check if a container is already running, if not then spawn it
---@param workspace_dir string
---@param opts? devcontainer.ensure_up.opts
---@return devcontainer.up_status.success?
function M.ensure_up(workspace_dir, opts)
    opts = opts or {}
    assert(coroutine.running())

    local start
    if not pending_ups[workspace_dir] then
        pending_ups[workspace_dir] = {}

        -- Run the operation in separate thread
        start = coroutine.wrap(function()
            local result = ensure_up(workspace_dir, opts)
            utils.schedule()

            -- Resume all pending coroutines
            local pending = pending_ups[workspace_dir] or {}
            pending_ups[workspace_dir] = nil
            for _, co in ipairs(pending) do
                local ok, err = coroutine.resume(co, result)
                if not ok then
                    log.notify.error('Pending ensure_up failed:\n%s', debug.traceback(co, err))
                end
            end
        end)
    end

    -- Add caller thread to observers and wait
    table.insert(pending_ups[workspace_dir], coroutine.running())
    if start then
        start()
    end
    return coroutine.yield()
end

return M
