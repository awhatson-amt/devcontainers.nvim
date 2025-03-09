---@param cls table
---@param super table
---@return boolean
local function issubclass(cls, super)
    vim.validate('cls', cls, 'table')
    vim.validate('super', super, 'table')
    while cls and cls ~= super do
        cls = getmetatable(cls)
    end
    return cls == super
end

---@param obj any
---@param cls table = metatable of class instances
---@return boolean
local function isinstance(obj, cls)
    vim.validate('class', cls, 'table')
    local mt = type(obj) == 'table' and getmetatable(obj)
    return mt and issubclass(mt, cls)
end

---@param name string
---@param super? table
local function class(name, super)
    vim.validate('name', name, 'string')
    vim.validate('super', super, 'table', true)

    local cls = {}
    cls.__index = cls
    -- custom fields
    cls.__name = name

    -- inheritance
    if super then
        setmetatable(cls, super)
    end

    return cls
end

return class
