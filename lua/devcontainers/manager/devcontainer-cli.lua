local M = {}

local utils = require('devcontainers.utils')
local log = require('devcontainers.log')['devcontainer-cli']

local system = utils.timed(utils.system, function(time_ms, cmd, _opts)
    log.trace('Command took %.3f ms: %s', time_ms, table.concat(cmd, ' '))
end)

-- TODO: use this at least in health check
M.is_supported = utils.lazy(function()
    local result = system({ 'devcontainer', '--version' })
    if result.code == 0 and #result.stdout > 0 then
        log.debug('Found devcontainer-cli version %s', result.stdout)
        return true
    else
        log.notify.warn('devcontainer-cli not available')
        return false
    end
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

--- TODO: order of insertion should be reflected when getting command
---@type table<string, fun(workspace_dir: string): (string[]|nil)>
M._up_cmd_overrides = {}

local function devcontainer_up_cmd(workspace_dir)
    for _, getter in pairs(M._up_cmd_overrides) do
        local cmd = getter(workspace_dir)
        if cmd then
            return cmd
        end
    end
    return { 'devcontainer', 'up', '--workspace-folder', workspace_dir }
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

---@param workspace_dir string
---@return { ok: boolean, error?: string, code: integer, status?: devcontainer.up_status }
local function devcontainer_up(workspace_dir)
    local cmd = devcontainer_up_cmd(workspace_dir)
    local ret
    -- TODO: refactor task management into single interface with multiple backends
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
        require('devcontainers.manager.cache').container[workspace_dir] = ret.status --[[@as devcontainer.up_status.success]]
    end
    return ret
end

devcontainer_up = utils.timed(devcontainer_up, function(time_us, workspace_dir)
    log.trace('devcontainer-up took %.3f ms: workspaceDir=%s', time_us, workspace_dir)
end)

M.devcontainer_up = devcontainer_up

---@param workspace_dir string
---@param opts? devcontainer.ensure_up.opts
---@return devcontainer.up_status.success?
function M.ensure_up(workspace_dir, opts)
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

---@param workspace_dir string
---@return { workspaceFolder: string }
function M.get_configuration(workspace_dir)
    log.trace('Getting configuration for: %s', workspace_dir)

    local result = system { 'devcontainer', 'read-configuration', '--workspace-folder', workspace_dir }
    if result.code ~= 0 then
        error(result.stderr)
    end

    local config = assert(vim.json.decode(result.stdout))

    return {
        workspaceFolder = assert(config.workspace.workspaceFolder, 'Missing .workspace.workspaceFolder'),
    }
end

return M
