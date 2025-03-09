local meta_model = require('devcontainers.meta_model')
local M = meta_model.Context:new(meta_model.load())

describe('meta_model_perf', function()
    it('iterate over all LSP types', function()
        local start = vim.uv.hrtime()

        local param_kinds = {}
        local base_types = {}
        local uris = {}

        ---@param prefix string
        ---@param typ LspMetaModel.Type
        local function scan_types(typ, prefix)
            for item, visitor in M:iter_types(typ) do
                if item.kind == 'base' then
                    base_types[item.name] = true
                end
                if item.kind then
                    param_kinds[item.kind] = (param_kinds[item.kind] or 0) + 1
                end
                if item.kind == 'base' and item.name == 'URI' or item.name == 'DocumentUri' then
                    table.insert(uris, table.concat({ prefix, tostring(visitor), item.name }, '\t'))
                end
            end
        end

        for _, request in ipairs(M.model.requests) do
            if request.result then
                scan_types(request.result, string.format('Request(%s,%s).result', request.method, request.messageDirection))
            end
            if request.partialResult then
                scan_types(request.partialResult, string.format('Request(%s,%s).registrationOptions', request.method, request.messageDirection))
            end
            if request.params then
                local params = request.params
                if not params[1] and next(params) then
                    params = { request.params }
                end
                ---@cast params LspMetaModel.Type[]
                for i, param in ipairs(params) do
                    scan_types(param, string.format('Request(%s,%s).params[%d]', request.method, request.messageDirection, i))
                end
            end
            if request.registrationOptions then
                scan_types(request.registrationOptions, string.format('Request(%s,%s).registrationOptions', request.method, request.messageDirection))
            end
        end

        for _, notif in ipairs(M.model.notifications) do
            if notif.params then
                local params = notif.params
                if not params[1] and next(params) then
                    params = { notif.params }
                end
                ---@cast params LspMetaModel.Type[]
                for i, param in ipairs(params) do
                    scan_types(param, string.format('Notification(%s,%s).params[%d]', notif.method, notif.messageDirection, i))
                end
            end
            if notif.registrationOptions then
                scan_types(notif.registrationOptions, string.format('Notification(%s,%s).registrationOptions', notif.method, notif.messageDirection))
            end
        end

        local elapsed = vim.uv.hrtime() - start
        print(string.format('Elapsed: %.3f ms', elapsed / 1e6))
    end)
end)

