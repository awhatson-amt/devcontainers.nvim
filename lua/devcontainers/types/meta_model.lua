---@meta

-- Written based on metaModel.ts
-- TODO: this could be generated from metaModel.schema.json
-- see: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#metaModel

---@alias LspMetaModel.Type.kind 'base'|'reference'|'array'|'map'|'and'|'or'|'tuple'|'literal'|'stringLiteral'|'integerLiteral'|'booleanLiteral'

---@alias LspMetaModel.Type.base.name 'URI'|'DocumentUri'|'integer'|'uinteger'|'decimal'|'RegExp'|'string'|'boolean'|'null'

---@class LspMetaModel.Type.base
---@field kind 'base'
---@field name LspMetaModel.Type.base.name

---@class LspMetaModel.Type.reference
---@field kind 'reference'
---@field name string

---@class LspMetaModel.Type.array
---@field kind 'array'
---@field element LspMetaModel.Type

---@alias LspMetaModel.Type.map.key { kind: 'base', name: 'URI'|'DocumentUri'|'string'|'integer' }|LspMetaModel.Type.reference

---@class LspMetaModel.Type.map
---@field kind 'map'
---@field key LspMetaModel.Type.map.key
---@field value LspMetaModel.Type

---@class LspMetaModel.Type.and
---@field kind 'and'
---@field items LspMetaModel.Type[]

---@class LspMetaModel.Type.or
---@field kind 'or'
---@field items LspMetaModel.Type[]

---@class LspMetaModel.Type.tuple
---@field kind 'tuple'
---@field items LspMetaModel.Type[]

---@class LspMetaModel.Type.structureLiteral
---@field kind 'literal'
---@field value LspMetaModel.StructureLiteral

---@class LspMetaModel.Type.stringLiteral
---@field kind 'stringLiteral'
---@field value string

---@class LspMetaModel.Type.integerLiteral
---@field kind 'integerLiteral'
---@field value integer

---@class LspMetaModel.Type.booleanLiteral
---@field kind 'booleanLiteral'
---@field value boolean

---@alias LspMetaModel.Type
---| LspMetaModel.Type.base
---| LspMetaModel.Type.reference
---| LspMetaModel.Type.array
---| LspMetaModel.Type.map
---| LspMetaModel.Type.and
---| LspMetaModel.Type.or
---| LspMetaModel.Type.tuple
---| LspMetaModel.Type.structureLiteral
---| LspMetaModel.Type.stringLiteral
---| LspMetaModel.Type.integerLiteral
---| LspMetaModel.Type.booleanLiteral

---@class LspMetaModel.CommonFields
---@field documentation? string
---@field since? string
---@field proposed? boolean
---@field deprecated? string

---@alias LspMetaModel.MessageDirection 'clientToServer'|'serverToClient'|'both'

---@class LspMetaModel.Request: LspMetaModel.CommonFields
---@field method string
---@field params? LspMetaModel.Type|LspMetaModel.Type[]
---@field result LspMetaModel.Type
---@field partialResult? LspMetaModel.Type
---@field errorData? LspMetaModel.Type
---@field registrationMethod? string
---@field registrationOptions? LspMetaModel.Type
---@field messageDirection? LspMetaModel.MessageDirection

---@class LspMetaModel.Notification: LspMetaModel.CommonFields
---@field method string
---@field params? LspMetaModel.Type|LspMetaModel.Type[]
---@field registrationMethod? string
---@field registrationOptions? LspMetaModel.Type
---@field messageDirection LspMetaModel.MessageDirection

---@class LspMetaModel.Property: LspMetaModel.CommonFields
---@field name string
---@field type LspMetaModel.Type
---@field optional? boolean

---@class LspMetaModel.Structure: LspMetaModel.CommonFields
---@field name string
---@field extends? LspMetaModel.Type[]
---@field mixins? LspMetaModel.Type[]
---@field properties LspMetaModel.Property[]

---@class LspMetaModel.StructureLiteral: LspMetaModel.CommonFields
---@field properties LspMetaModel.Property[]

---@class LspMetaModel.TypeAlias: LspMetaModel.CommonFields
---@field name string
---@field type LspMetaModel.Type

---@class LspMetaModel.EnumerationEntry: LspMetaModel.CommonFields
---@field name string
---@field value string|number

---@class LspMetaModel.EnumerationType
---@field kind 'base'
---@field name 'string'|'integer'|'uinteger'

---@class LspMetaModel.Enumeration: LspMetaModel.CommonFields
---@field name string
---@field type LspMetaModel.EnumerationType
---@field values LspMetaModel.EnumerationEntry[]
---@field supportsCustomValues? boolean

---@class LspMetaModel.MetaData
---@field version string

---@class LspMetaModel.Model
---@field metaData LspMetaModel.MetaData
---@field requests LspMetaModel.Request[]
---@field notifications LspMetaModel.Notification[]
---@field structures LspMetaModel.Structure[]
---@field enumerations LspMetaModel.Enumeration[]
---@field typeAliases LspMetaModel.TypeAlias[]
