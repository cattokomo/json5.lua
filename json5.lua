local json5 = {}

local function create_enum(name)
    return setmetatable({}, {
        __name = name,
        __tostring = function()
            return name
        end
    })
end

---@class json5.null
---
--- A special enum to encode value as JSON `null`.
---
json5.null = create_enum("json5.null")

---@param tbl {string:any}|any[]
---@return {string:any}|any[]
---
--- Return a table with data to encode table as object.
---
function json5.as_object(tbl)
    return setmetatable(tbl, {
        __json5_type = "object",
    })
end

---@param tbl {string:any}|any[]
---@return {string:any}|any[]
---
--- Return a table with data to encode table as array.
---
function json5.as_array(tbl)
    return setmetatable(tbl, {
        __json5_type = "array",
    })
end

local serializer
local serializer_mt = {
    __index = function(self, k)
        local v = rawget(self, k)
        if not v then
            return function() return "unsupported type '" .. k .. "'" end
        end
        return v
    end
}

serializer = setmetatable({
    ["nil"] = function(rope)
        rope[#rope + 1] = "null"
    end,
    string = function(rope, value)
        rope[#rope + 1] =
            '"' ..
            value
            :gsub('"', '\\"')
            :gsub("\n", "\\n")
            :gsub("\r", "\\r")
            .. '"'
    end,
    number = function(rope, value)
        if tostring(value) == "nan" then
            rope[#rope + 1] = "NaN"
        elseif value == math.huge then
            rope[#rope + 1] = "Infinity"
        elseif value == -math.huge then
            rope[#rope + 1] = "-Infinity"
        else
            rope[#rope + 1] = tostring(value)
        end
    end,
    boolean = function(rope, value)
        rope[#rope + 1] = tostring(value)
    end,
    table = function(rope, value)
        if value == json5.null then
            rope[#rope + 1] = "null"
            return
        end

        local json5_type = (getmetatable(value) or {}).__json5_type


        if rawget(value, 1) ~= nil or next(value) == nil then
            json5_type = json5_type or "array"
        elseif rawget(value, 1) == nil or next(value) ~= nil then
            json5_type = json5_type or "object"
        end

        rope[#rope + 1] = json5_type == "array" and "[" or "{"
        if json5_type == "array" then
            for _, v in ipairs(value) do
                if v == value then
                    return "circular reference"
                end
                local err = serializer[type(v)](rope, v)
                if err and v ~= json5.null then
                    return err
                end
                rope[#rope + 1] = ","
            end
            rope[#rope] = nil
        elseif json5_type == "object" then
            for k, v in pairs(value) do
                if v == value then
                    return "circular reference"
                end
                if type(k) == "string" then
                    serializer.string(rope, k)
                    rope[#rope + 1] = ":"
                    local err = serializer[type(v)](rope, v)
                    if err then
                        return err
                    end
                    rope[#rope + 1] = ","
                end
            end
            rope[#rope] = nil
        end
        rope[#rope + 1] = json5_type == "array" and "]" or "}"
    end,
}, serializer_mt)

---@param value {string:any}|any[]
---@param options? table
---@return string?
---@return string?
---
--- Encode a table as JSON5 format.
--- If encoding failed, returns nil + error message.
---
function json5.encode(value, options)
    options = options or {}

    local rope = {}
    local err = serializer[type(value)](rope, value)

    if err then
        return nil, err
    end
    return table.concat(rope)
end

return json5
