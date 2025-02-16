local M = {}

M.version = '3.17'

---@param path string
---@return string data
local function read_file_sync(path)
    local fd = assert(vim.uv.fs_open(path, 'r', 438))
    local stat = assert(vim.uv.fs_fstat(fd))
    local data = assert(vim.uv.fs_read(fd, stat.size, 0))
    assert(vim.uv.fs_close(fd))
    return data
end

---@param path string
---@param data string
local function write_file_sync(path, data)
    local fd = assert(vim.uv.fs_open(path, 'w', 438))
    assert(vim.uv.fs_write(fd, data))
    assert(vim.uv.fs_close(fd))
end

---@param json_data string
---@return LspMetaModel.Model
function M.load_from_string(json_data)
    return vim.json.decode(json_data)
end

---@param path string
---@return LspMetaModel.Model
function M.load_from_file(path)
    return M.load_from_string(read_file_sync(path))
end

---@param version? string
function M.get_url(version)
    version = version or M.version
    return string.format('https://microsoft.github.io/language-server-protocol/specifications/lsp/%s/metaModel/metaModel.json', version)
end

---@param url string
---@return string
local function download(url)
    local result = vim.system({ 'curl', url }, { text = true }):wait()
    if not result.code == 0 then
        error(string.format('Downloading with curl failed:\n%s', result.stderr))
    end
    return result.stdout
end

---@param url? string
---@return LspMetaModel.Model
function M.load_from_url(url)
    return M.load_from_string(download(url or M.get_url()))
end

---@param version? string
---@param no_cache? boolean
---@return LspMetaModel.Model
function M.load(version, no_cache)
    version = version or M.version

    local cache_dir = vim.fn.stdpath('cache')
    ---@cast cache_dir string
    local path = vim.fs.joinpath(cache_dir, 'devcontainers', string.format('metaModel_%s.json', version))

    if not no_cache and vim.uv.fs_stat(path) then
        return M.load_from_file(path)
    else
        vim.notify(string.format('Downloading LSP metaModel version %s ...', version), vim.log.levels.DEBUG)
        local data = download(M.get_url(version))
        local model = M.load_from_string(data)
        vim.fn.mkdir(vim.fs.dirname(path), 'p')
        write_file_sync(path, data)
        return model
    end
end

---@param key string
---@param list table[]
local function make_lookup_by_key(key, list)
    local tbl = {}
    for _, item in ipairs(list) do
        local key_value = item[key]
        assert(not tbl[key_value], key_value)
        tbl[key_value] = item
    end
    return tbl
end

---@class devcontainers.LspModelContext
---@field model LspMetaModel.Model
---@field requests table<string, LspMetaModel.Request>
---@field notifications table<string, LspMetaModel.Notification>
---@field type_aliases table<string, LspMetaModel.TypeAlias>
---@field enumerations table<string, LspMetaModel.Enumeration>
---@field structures table<string, LspMetaModel.Structure>
M.Context = {}
M.Context.__index = M.Context

---@param model LspMetaModel.Model
function M.Context:new(model)
    return setmetatable({
        model = model,
        requests = make_lookup_by_key('method', model.requests),
        notifications = make_lookup_by_key('method', model.notifications),
        type_aliases = make_lookup_by_key('name', model.typeAliases),
        enumerations = make_lookup_by_key('name', model.enumerations),
        structures = make_lookup_by_key('name', model.structures),
    }, self)
end

---@alias LspMetaModel.ReferenceTarget
---| LspMetaModel.TypeAlias
---| LspMetaModel.Structure
---| LspMetaModel.Enumeration

---@param ref LspMetaModel.Type.reference
---@return LspMetaModel.ReferenceTarget
function M.Context:get_reference(ref)
    if self.type_aliases[ref.name] then
        return self.type_aliases[ref.name]
    elseif self.structures[ref.name] then
        return self.structures[ref.name]
    elseif self.enumerations[ref.name] then
        return self.enumerations[ref.name]
    else
        error(string.format('Missing reference definition: %s', ref.name))
    end
end

---@alias LspMetaModel.ConcreteType
---| LspMetaModel.Type.base
---| LspMetaModel.Type.array
---| LspMetaModel.Type.map
---| LspMetaModel.Type.and
---| LspMetaModel.Type.or
---| LspMetaModel.Type.tuple
---| LspMetaModel.Type.structureLiteral
---| LspMetaModel.Type.stringLiteral
---| LspMetaModel.Type.integerLiteral
---| LspMetaModel.Type.booleanLiteral
---| LspMetaModel.Structure
---| LspMetaModel.Enumeration

---@param typ LspMetaModel.Type
---@return LspMetaModel.ConcreteType
function M.Context:resolve_type(typ)
    if typ.kind == 'reference' then
        local ref = self:get_reference(typ)
        if ref.type then ---@cast ref LspMetaModel.TypeAlias
            return self:resolve_type(ref.type)
        elseif ref.properties then ---@cast ref LspMetaModel.Structure
            return ref
        elseif ref.values then ---@cast ref LspMetaModel.Enumeration
            return ref
        else
            error(string.format('Invalid reference: %s', ref))
        end
    else
        return typ
    end
end

---@alias devcontainers.LspTypeIter.Item
---| LspMetaModel.Type
---| LspMetaModel.TypeAlias
---| LspMetaModel.Structure
---| LspMetaModel.Enumeration

---@class devcontainers.LspTypeVisitor
---@field ctx devcontainers.LspModelContext
---@field stack devcontainers.LspTypeIter.Item[]
---@field visited_refs table<string, true>
---@field level integer
---@overload fun(): devcontainers.LspTypeIter.Item?
local Visitor = {}
Visitor.__index = Visitor

---@param ctx devcontainers.LspModelContext
---@return devcontainers.LspTypeVisitor
function Visitor:new(ctx)
    return setmetatable({ ctx = ctx, stack = {}, visited_refs ={},  level = 0 }, self)
end

---@private
---@param item devcontainers.LspTypeIter.Item
function Visitor:push(item)
    -- Guard agains cycles
    if item.kind == 'reference' then
        if self.visited_refs[item.name] then
            return false
        else
            self.visited_refs[item.name] = true
        end
    end
    self.level = self.level + 1
    self.stack[self.level] = item
    return true
end

---@private
function Visitor:pop()
    local item = self.stack[self.level]
    if item.kind == 'reference' then
        assert(self.visited_refs[item.name], item.name)
        self.visited_refs[item.name] = nil
    end
    self.stack[self.level] = nil
    self.level = self.level - 1
    return item
end

---@param typ LspMetaModel.Type
---@param on_item fun(item: devcontainers.LspTypeIter.Item)
function Visitor:visit(typ, on_item)
    if not self:push(typ) then
        return
    end

    on_item(typ)

    if typ.kind == 'base' then
    elseif typ.kind == 'reference' then
        self:visit_reference(self.ctx:get_reference(typ), on_item)
    elseif typ.kind == 'array' then
        self:visit(typ.element, on_item)
    elseif typ.kind == 'map' then
        self:visit(typ.key, on_item)
        self:visit(typ.value, on_item)
    elseif typ.kind == 'and' then
        for _, item in ipairs(typ.items) do
            self:visit(item, on_item)
        end
    elseif typ.kind == 'or' then
        for _, item in ipairs(typ.items) do
            self:visit(item, on_item)
        end
    elseif typ.kind == 'tuple' then
        for _, item in ipairs(typ.items) do
            self:visit(item, on_item)
        end
    elseif typ.kind == 'literal' then
        self:visit_structure(typ.value, on_item)
    elseif typ.kind == 'stringLiteral' then
    elseif typ.kind == 'integerLiteral' then
    elseif typ.kind == 'booleanLiteral' then
    else
        error(string.format('Invalid kind=%s', typ['kind']))
    end

    self:pop()
end

---@private
---@param on_item fun(item: devcontainers.LspTypeIter.Item)
---@param ref LspMetaModel.ReferenceTarget
function Visitor:visit_reference(ref, on_item)
    if not self:push(ref) then
        return
    end

    on_item(ref)

    if ref.type then ---@cast ref LspMetaModel.TypeAlias
        self:visit(ref.type, on_item)
    elseif ref.properties then ---@cast ref LspMetaModel.Structure
        self:visit_structure(ref, on_item)
    elseif ref.values then ---@cast ref LspMetaModel.Enumeration
    end

    self:pop()
end

---@private
---@param typ LspMetaModel.Type
---@param fn fun(prop: LspMetaModel.Property)
function Visitor:visit_properties(typ, fn)
    local concrete = self.ctx:resolve_type(typ)
    if concrete.properties then
        for _, prop in ipairs(concrete.properties) do
            fn(prop)
        end
    else
        error(string.format('Invalid type without properties: %s, kind="%s"', typ, typ.kind))
    end
end

---@private
---@param on_item fun(item: devcontainers.LspTypeIter.Item)
---@param struct LspMetaModel.Structure|LspMetaModel.StructureLiteral
function Visitor:visit_structure(struct, on_item)
    local props = {}
    for _, prop in ipairs(struct.properties) do
        props[prop.name] = prop
    end
    if struct.extends then
        for _, typ in ipairs(struct.extends) do
            self:visit_properties(typ, function(prop)
                -- if props[prop.name] then
                --     error(string.format('Duplicate property "%s" of %s (extends)', prop.name, struct.name or 'structureLiteral'))
                -- end
                if not props[prop.name] then -- overridden
                    props[prop.name] = prop
                end
            end)
        end
    end
    if struct.mixins then
        for _, typ in ipairs(struct.mixins) do
            self:visit_properties(typ, function(prop)
                -- allow overriding
                props[prop.name] = prop
            end)
        end
    end
    for _, prop in pairs(props) do
        self:visit(prop.type, on_item)
    end
end

---@param item devcontainers.LspTypeIter.Item
---@return string
local function item_to_string(item)
    if item.kind == 'base' then
        return string.format('base(%s)', item.name)
    elseif item.kind == 'reference' then
        return string.format('reference(%s)', item.name)
    elseif item.kind == 'array' then
        return item.kind
    elseif item.kind == 'map' then
        return item.kind
    elseif item.kind == 'and' then
        return item.kind
    elseif item.kind == 'or' then
        return item.kind
    elseif item.kind == 'tuple' then
        return item.kind
    elseif item.kind == 'literal' then
        return item.kind
    elseif item.kind == 'stringLiteral' then
        return item.kind
    elseif item.kind == 'integerLiteral' then
        return item.kind
    elseif item.kind == 'booleanLiteral' then
        return item.kind
    elseif item.type then ---@cast item LspMetaModel.TypeAlias
        return string.format('TypeAlias(%s)', item.name)
    elseif item.properties then ---@cast item LspMetaModel.Structure
        return string.format('Structure(%s)', item.name)
    elseif item.values then ---@cast item LspMetaModel.Enumeration
        return string.format('Enumeration(%s)', item.name)
    else
        return '<?>'
    end
end

function Visitor:__tostring()
    local stack = {}
    for i, v in ipairs(self.stack) do
        stack[i] = item_to_string(v)
    end
    return table.concat(stack, '.')
end

--- Iterator adapter for the visitor
---@param typ LspMetaModel.Type
---@return fun(): devcontainers.LspTypeIter.Item?, devcontainers.LspTypeVisitor?
function Visitor:iter(typ)
    return coroutine.wrap(function()
        self:visit(typ, function(item)
            coroutine.yield(item, self)
        end)
    end)
end

---@return devcontainers.LspTypeVisitor
function M.Context:type_visitor()
    return Visitor:new(self)
end

---@param typ LspMetaModel.Type
---@return fun(): devcontainers.LspTypeIter.Item?, devcontainers.LspTypeVisitor?
function M.Context:iter_types(typ)
    return Visitor:new(self):iter(typ)
end

return M
