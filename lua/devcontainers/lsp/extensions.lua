--- Non-official extensions to LSP specification
local M = {}

local log = require('devcontainers.log')['lsp.extensions']

---@class devcontainers.lsp.Extensions
---@field requests? LspMetaModel.Request[]
---@field notifications? LspMetaModel.Notification[]
---@field structures? LspMetaModel.Structure[]
---@field enumerations? LspMetaModel.Enumeration[]
---@field typeAliases? LspMetaModel.TypeAlias[]
---@field updates? devcontainers.lsp.extensions.Updates

---@class devcontainers.lsp.extensions.Updates
---@field structures? table<string, devcontainers.lsp.extensions.StructureUpdate>

---@class devcontainers.lsp.extensions.StructureUpdate
---@field properties? LspMetaModel.Property[]

---@type table<string, devcontainers.lsp.Extensions>
M.extensions = {}

--- See https://clangd.llvm.org/extensions
M.extensions.clangd = {
    structures = {
        {
            name = 'FileStatus',
            properties = {
                { name = 'uri', type = { kind = 'base', name = 'DocumentUri' } },
                { name = 'state', type = { kind = 'base', name = 'string' } },
            },
            since = 'clangd-8',
        },
        {
            name = 'SymbolDetails',
            properties = {
                { name = 'name', type = { kind = 'base', name = 'string' } },
                { name = 'containerName', type = { kind = 'base', name = 'string' } },
                { name = 'usr', type = { kind = 'base', name = 'string' } },
                { name = 'id', type = { kind = 'base', name = 'string' }, optional = true },
            },
            since = 'clangd-8',
        },
    },
    requests = {
        {
            method = 'textDocument/switchSourceHeader',
            params = { kind = 'reference', name = 'TextDocumentIdentifier' },
            result = { kind = 'base', name = 'DocumentUri' },
            messageDirection = 'clientToServer',
            documentation = 'Lets editors switch between the main source file (*.cpp) and header (*.h).',
            since = 'clangd-6',
        },
        {
            method = 'textDocument/symbolInfo',
            params = { kind = 'reference', name = 'TextDocumentPositionParams' },
            result = { kind = 'reference', name = 'SymbolDetails' },
            messageDirection = 'clientToServer',
            documentation = 'Lets editors switch between the main source file (*.cpp) and header (*.h).',
            since = 'clangd-6',
        },
        -- TODO: AST request - looks like it is the only one missing that contains some DocumentUri
    },
    notifications = {
        {
            method = 'textDocument/clangd.fileStatus',
            params = { kind = 'reference', name = 'FileStatus' },
            messageDirection = 'serverToClient',
            documentation = 'Provides information about activity on clangd’s per-file worker thread. This can be relevant to users as building the AST blocks many other operations.',
            since = 'clangd-8',
        },
    },
    updates = {
        structures = {
            Diagnostic = {
                properties = {
                    {
                        name = 'codeActions',
                        optional = true,
                        type = {
                            kind = 'array',
                            element = { kind = 'reference', name = 'CodeAction' },
                        },
                        documentation = 'All the code actions that address this diagnostic.',
                        since = 'clangd-8',
                    },
                    {
                        name = 'category',
                        type = { kind = 'base', name = 'string' },
                        since = 'clangd-8',
                    },
                },
            },
        },
    },
}

local function find_by_name(name, list)
    for _, elem in ipairs(list) do
        if elem.name == name then
            return elem
        end
    end
end

---@param model LspMetaModel.Model
---@param extensions devcontainers.lsp.Extensions
function M.apply_extensions(model, extensions)
    local lists = { 'requests', 'notifications', 'structures', 'enumerations', 'typeAliases' }
    for _, list in ipairs(lists) do
        if extensions[list] then
            vim.list_extend(model[list], extensions[list])
        end
    end
    if extensions.updates then
        for name, update in pairs(extensions.updates.structures or {}) do
            ---@type LspMetaModel.Structure
            local structure = find_by_name(name, model.structures)
            if not structure then
                log.error('Could not update structure "%s": no such type', name)
            else
                vim.list_extend(structure.properties, update.properties or {})
            end
        end
    end
end

---@alias devcontainers.lsp.ExtensionsFilter fun(name: string, extensions: devcontainers.lsp.Extensions): boolean

---@param model LspMetaModel.Model
---@param filter? fun(name: string, extensions: devcontainers.lsp.Extensions): boolean
function M.apply(model, filter)
    for name, ext in pairs(M.extensions) do
        if filter == nil or filter(name, ext) then
            log.debug('Applying LSP protocol extensions "%s"', name)
            M.apply_extensions(model, ext)
        else
            log.debug('Ignoring LSP protocol extensions "%s"', name)
        end
    end
end

return M
