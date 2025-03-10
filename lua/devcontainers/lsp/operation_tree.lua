--- Computes tree of access operations required to reach given value in a type
--- and replace it.
local M = {}

local class = require('devcontainers.class')

local function has_field(v, key)
    return type(v) == 'table' and v[key] ~= nil
end

---@alias devcontainers.OperationTree.Value.Fn fun(value: boolean|number|string): any

---@class devcontainers.OperationTree
local OperationTree = class('OperationTree')
M.OperationTree = OperationTree

---@param value any
---@return boolean
function OperationTree:matches(value)
    error(string.format('Not implemented: %s', value))
end

---@param _fn devcontainers.OperationTree.Value.Fn
---@param value any
---@return any
function OperationTree:apply(_fn, value)
    error(string.format('Not implemented: %s', value))
end

--- Process first matching child operation
---@class devcontainers.OperationTree.Or: devcontainers.OperationTree
---@field nodes devcontainers.OperationTree[]
local Or = class('Or', OperationTree)
M.Or = Or

---@param nodes devcontainers.OperationTree[]
function Or:new(nodes)
    return setmetatable({ nodes = nodes }, self)
end

function Or:matches(value)
    for _, node in ipairs(self.nodes) do
        if node:matches(value) then
            return true
        end
    end
    return false
end

function Or:apply(fn, value)
    for _, node in ipairs(self.nodes) do
        if node:matches(value) then
            return node:apply(fn, value)
        end
    end
    return value
end

--- Process all of child operations
---@class devcontainers.OperationTree.All: devcontainers.OperationTree
---@field nodes devcontainers.OperationTree[]
local All = class('All', OperationTree)
M.All = All

---@param nodes devcontainers.OperationTree[]
function All:new(nodes)
    return setmetatable({ nodes = nodes }, self)
end

function All:matches(value)
    for _, node in ipairs(self.nodes) do
        if node:matches(value) then
            return true
        end
    end
    return false
end

function All:apply(fn, value)
    for _, node in ipairs(self.nodes) do
        if node:matches(value) then
            value = node:apply(fn, value)
        end
    end
    return value
end

--- Process all array elements
---@class devcontainers.OperationTree.Array: devcontainers.OperationTree
---@field node devcontainers.OperationTree
local Array = class('Array', OperationTree)
M.Array = Array

---@param node devcontainers.OperationTree
function Array:new(node)
    return setmetatable({ node = node }, self)
end

function Array:matches(value)
    return has_field(value, 1) -- and self.node:matches(value[1])
end

function Array:apply(fn, value)
    for i, item in ipairs(value) do
        if self.node:matches(item) then
            value[i] = self.node:apply(fn, item)
        end
    end
    return value
end

--- Process all keys of a map
---@class devcontainers.OperationTree.MapKey: devcontainers.OperationTree
---@field node devcontainers.OperationTree
local MapKey = class('MapKey', OperationTree)
M.MapKey = MapKey

---@param node devcontainers.OperationTree
function MapKey:new(node)
    return setmetatable({ node = node }, self)
end

function MapKey:matches(value)
    return type(value) == 'table'
end

function MapKey:apply(fn, value)
    local new = {}
    for key, val in pairs(value) do
        if self.node:matches(key) then
            new[self.node:apply(fn, key)] = val
        end
    end
    return new
end

--- Process all values of a map
---@class devcontainers.OperationTree.MapValue: devcontainers.OperationTree
---@field node devcontainers.OperationTree
local MapValue = class('MapValue', OperationTree)
M.MapValue = MapValue

---@param node devcontainers.OperationTree
function MapValue:new(node)
    return setmetatable({ node = node }, self)
end

function MapValue:matches(value)
    return type(value) == 'table'
end

function MapValue:apply(fn, value)
    local new = {}
    for key, val in pairs(value) do
        if self.node:matches(val) then
            new[key] = self.node:apply(fn, val)
        end
    end
    return new
end

--- Index into current value
---@class devcontainers.OperationTree.Index: devcontainers.OperationTree
---@field node devcontainers.OperationTree
---@field index integer|string
local Index = class('Index', OperationTree)
M.Index = Index

---@param index integer|string
---@param node devcontainers.OperationTree
function Index:new(index, node)
    return setmetatable({ index = index, node = node }, self)
end

function Index:matches(value)
    return has_field(value, self.index)
end

function Index:apply(fn, value)
    if self.node:matches(value[self.index]) then
        value[self.index] = self.node:apply(fn, value[self.index])
    end
    return value
end

--- Final node to be processed
---@class devcontainers.OperationTree.Value: devcontainers.OperationTree
local Value = class('Value', OperationTree)
M.Value = Value

function Value:new()
    return setmetatable({}, self)
end

function Value:matches(value)
    return type(value) ~= 'table'
end

function Value:apply(fn, value)
    return fn(value)
end


---@param model devcontainers.LspModelContext
---@param path devcontainers.LspTypeIter.Item[]
---@param pos integer
---@return devcontainers.OperationTree
local function tree_from_path(model, path, pos)
    local i = assert(path[pos])
    if i.kind == 'base' or i.kind == 'stringLiteral' or i.kind == 'integerLiteral' or i.kind == 'booleanLiteral' or i.values then
        assert(path[pos + 1] == nil)
        return Value:new()
    elseif i.kind == 'reference' or i.type then
        return tree_from_path(model, path, pos + 1)
    elseif i.info == 'or.index' then
        return tree_from_path(model, path, pos + 1)
    elseif i.kind == 'array' then
        return Array:new(tree_from_path(model, path, pos + 1))
    elseif i.kind == 'or' then
        -- handle only the variant that is in currently processed path, merge trees later
        return Or:new { tree_from_path(model, path, pos + 1) }
    elseif i.kind == 'map' then
        -- handle only the variant that is in currently processed path, merge trees later
        return All:new { tree_from_path(model, path, pos + 1) }
    elseif i.info == 'map.key' then
        return MapKey:new(tree_from_path(model, path, pos + 1))
    elseif i.info == 'map.value' then
        return MapValue:new(tree_from_path(model, path, pos + 1))
    elseif i.kind == 'tuple' or i.kind == 'literal' or i.properties then
        -- handle only the variant that is in currently processed path, merge trees later
        return All:new { tree_from_path(model, path, pos + 1) }
    elseif i.info == 'tuple.index' then
        return Index:new(i.index, tree_from_path(model, path, pos + 1))
    elseif i.info == 'property' then
        return Index:new(i.property.name, tree_from_path(model, path, pos + 1))
    elseif i.kind == 'and' or i.info == 'and.index' then
        error(string.format('"%s" not supported', i.kind)) -- not sure how this would even work
    else
        error(string.format('Invalid item: %s', vim.inspect(i)))
    end
end

---@param model devcontainers.LspModelContext
---@param path devcontainers.LspTypeIter.Item[]
---@return devcontainers.OperationTree
function OperationTree.from_path(model, path)
    return tree_from_path(model, path, 1)
end

function OperationTree:_merge(other)
    error(string.format('Not implemented: %s', other))
end

function Or:_merge(other)
    vim.list_extend(self.nodes, other.nodes)
end

All._merge = Or._merge

function Array:_merge(other)
    self.node:merge(other.node)
end

MapKey._merge = Array._merge
MapValue._merge = Array._merge
Index._merge = Array._merge

function Value:_merge()
end

-- TODO:  remove duplicates after merging+simplifying in And/Or (e.g. workspaceSymbol/resolve)
---@param other devcontainers.OperationTree
function OperationTree:merge(other)
    if getmetatable(self) == getmetatable(other) then
        ---@diagnostic disable-next-line: undefined-field
        self:_merge(other)
    end
end

---@vararg devcontainers.OperationTree
---@return devcontainers.OperationTree
function OperationTree:merged(...)
    local new = vim.deepcopy(self, true)
    for i = 1, select('#', ...) do
        new:merge(select(i, ...))
    end
    return new
end

---@return devcontainers.OperationTree
function OperationTree:_simplified()
    error('Not implemented')
end

function Or:_simplified()
    local n = #self.nodes
    assert(n > 0, n)
    if n == 1 then
        return self.nodes[1]:simplified()
    else
        return getmetatable(self):new(vim.tbl_map(OperationTree.simplified, self.nodes))
    end
end

All._simplified = Or._simplified

function Array:_simplified()
    return getmetatable(self):new(self.node:simplified())
end

MapKey._simplified = Array._simplified
MapValue._simplified = Array._simplified

function Index:_simplified()
    return Index:new(self.index, self.node:simplified())
end

function Value:_simplified()
    return self
end

function OperationTree:simplified()
    return self:_simplified()
end

local STRING_SHORT = true
local STRING_NEWLINE = false

if not STRING_SHORT then
    function Or:__tostring()
        return string.format('Or(%s)', table.concat(vim.tbl_map(tostring, self.nodes), ', '))
    end
    function All:__tostring()
        return string.format('All(%s)', table.concat(vim.tbl_map(tostring, self.nodes), ', '))
    end
    function Array:__tostring()
        return string.format('Array(%s)', self.node)
    end
    function MapKey:__tostring()
        return string.format('MapKey(%s)', self.node)
    end
    function MapValue:__tostring()
        return string.format('MapValue(%s)', self.node)
    end
    function Index:__tostring()
        return string.format('Index(%s, %s)', self.index, self.node)
    end
    function Value:__tostring()
        return 'Value'
    end
else
    if STRING_NEWLINE then
        local level = 0
        local function indent()
            return string.rep('  ', level)
        end
        local function tostring_multiline(nodes, join)
            local postfix = ' ' .. join
            local lines = { indent() .. '(' }
            level = level + 1
            for i, node in ipairs(nodes) do
                table.insert(lines, indent() .. tostring(node) .. (i == #nodes and '' or postfix))
            end
            level = level - 1
            table.insert(lines, indent() .. ')')
            return table.concat(lines, '\n')
        end
        function Or:__tostring()
            return tostring_multiline(self.nodes, '| ')
        end
        function All:__tostring()
            return tostring_multiline(self.nodes, '& ')
        end
    else
        function Or:__tostring()
            return string.format('(%s)', table.concat(vim.tbl_map(tostring, self.nodes), ' | '))
        end
        function All:__tostring()
            return string.format('(%s)', table.concat(vim.tbl_map(tostring, self.nodes), ' & '))
        end
    end
    function Array:__tostring()
        return string.format('.[]%s', self.node)
    end
    function MapKey:__tostring()
        return string.format('<*,>%s', self.node)
    end
    function MapValue:__tostring()
        return string.format('<,*>%s', self.node)
    end
    function Index:__tostring()
        if type(self.index) == 'string' then
            return string.format('.%s%s', self.index, self.node)
        else
            return string.format('[%s]%s', self.index, self.node)
        end
    end
    function Value:__tostring()
        return ''
    end
end

return M
