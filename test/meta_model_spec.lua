local say = require('say')
local meta_model = require('devcontainers.lsp.meta_model')

local ctx = meta_model.Context:new(meta_model.load())

local MAX_ITERATIONS = 500

---@param from_type LspMetaModel.Type
---@param matcher fun(item: LspMetaModel.LspTypeIter.Item): boolean
---@return string[]
local function get_paths_to(from_type, matcher)
    local iter = 1
    local paths = {}
    for item, visitor in ctx:iter_types(from_type) do
        if iter > MAX_ITERATIONS then
            error('Max iterations limit reached')
        end
        iter = iter + 1
        if matcher(item) then
            table.insert(paths, tostring(visitor))
        end
    end
    table.sort(paths) -- for deterministic results
    return paths
end

---@param name? string
local function is_base_type(name)
    return function(item)
        return item.kind == 'base' and (name == nil or item.name == name)
    end
end

---@param name string
local function ref(name)
    return { kind = 'reference', name = name }
end

describe('meta_model', function()
    describe('paths', function()
        it('Definition -> DocumentUri', function()
            local paths = get_paths_to(ctx.type_aliases.Definition.type, is_base_type('DocumentUri'))
            assert.same(paths, {
                '.[].[uri] = DocumentUri',
                '.[uri] = DocumentUri',
            })
        end)

        it('GlobPattern -> string', function()
            local paths = get_paths_to(ctx.type_aliases.GlobPattern.type, is_base_type('string'))
            assert.same(paths, {
                ' = string', -- Pattern
                '.[baseUri].[name] = string', -- RelativePatern.baseUri.or[1].WorkspaceFolder
                '.[pattern] = string', -- RelativePatern.pattern(Pattern)
            })
        end)

        it('HoverOptions -> base', function()
            local paths = get_paths_to(ref('HoverOptions'), is_base_type())
            assert.same(paths, { '.[workDoneProgress] = boolean' })
        end)

        it('CreateFile -> base', function()
            local paths = get_paths_to(ref('CreateFile'), is_base_type())
            assert.same(paths, {
                '.[annotationId] = string',
                -- '.[kind] = string', -- NOTE: overwritten from extends ResourceOperation with stringLiteral
                '.[options].[ignoreIfExists] = boolean',
                '.[options].[overwrite] = boolean',
                '.[uri] = DocumentUri',
            })
        end)
    end)
end)
