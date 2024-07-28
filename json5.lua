local json5 = {}

-- TODO: optimize decode function

---@class json5.encode_options
---@field explicit_string_key boolean Explictly wrap key in quote regardless if it's a valid JSON5 identifier
---@field explicit_positive_sign boolean Explicitly add positive sign prefix to numbers
---@field use_single_quote boolean Use single quotes for string instead of double quotes
---@field json_compatible boolean Enable compatibility with JSON, this will disables JSON5 goodies

---@diagnostic disable-next-line: deprecated
local unpack = unpack or table.unpack

---@param name string
---@return table
local function create_enum(name)
    return setmetatable({}, {
        __name = name,
        __tostring = function()
            return name
        end
    })
end

---@param str string
---@param ... string
---@return string
local function matchs(str, ...)
    local ret = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        ret = { str:match(v) }
        if #ret ~= 0 then
            break
        end
    end
    return unpack(ret)
end

---@param tbl table
---@return table
local function copy(tbl)
    local t = {}
    for i, v in pairs(tbl) do
        t[i] = type(v) == "table" and copy(v) or v
    end
    return t
end

-- Taken from https://github.com/rxi/json.lua/blob/master/json.lua#L189-L203

---@param n integer
---@return string
local function codepoint_to_utf8(n)
    -- http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=iws-appendixa
    local f = math.floor
    if n <= 0x7f then
        return string.char(n)
    elseif n <= 0x7ff then
        return string.char(f(n / 64) + 192, n % 64 + 128)
    elseif n <= 0xffff then
        return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
    elseif n <= 0x10ffff then
        return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
            f(n % 4096 / 64) + 128, n % 64 + 128)
    end
    error(string.format("invalid unicode codepoint '%x'", n))
end

---@class json5.null
---
--- A special enum to encode value as JSON `null`.
---
json5.null = create_enum("json5.null")

---@class json5.empty_array
---
--- A special enum to encode value as empty JSON array.
---
json5.empty_array = create_enum("json5.empty_array")

---@param tbl {string:any}|any[]
---@return {string:any}|any[]
---
--- Return a table with data to encode table as object.
---
function json5.as_object(tbl)
    return setmetatable(copy(tbl), {
        __json5_type = "object",
    })
end

---@param tbl {string:any}|any[]
---@return {string:any}|any[]
---
--- Return a table with data to encode table as array.
---
function json5.as_array(tbl)
    return setmetatable(copy(tbl), {
        __json5_type = "array",
    })
end

local escapes = {
    ["'"] = [[\']],
    ['"'] = [[\"]],
    ["\\"] = [[\\]],
    ["\b"] = [[\b]],
    ["\f"] = [[\f]],
    ["\n"] = [[\n]],
    ["\r"] = [[\r]],
    ["\t"] = [[\t]],
    ["\v"] = [[\v]],
    ["\0"] = [[\0]],
}
local escape_patt = "['\"\\\8-\13" .. (_VERSION >= "Lua 5.2" and "\0" or "%z") .. "]"

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
    ---@param rope string[]
    ["nil"] = function(rope)
        rope[#rope + 1] = "null"
    end,
    ---@param rope string[]
    ---@param value string
    ---@param options table
    string = function(rope, value, options)
        local quote = '"'
        if options.use_single_quote then
            quote = "'"
        end
        rope[#rope + 1] = quote .. value:gsub(escape_patt, escapes) .. quote
    end,
    ---@param rope string[]
    ---@param value number
    ---@param options table
    ---@return string?
    number = function(rope, value, options)
        if
            options.json_compatible and
            tostring(value) == "nan" or
            value == math.huge or
            value == -math.huge
        then
            return "unexpected number value '" .. tostring(value) .. "'"
        end

        if tostring(value) == "nan" then
            rope[#rope + 1] = "NaN"
        elseif value == math.huge then
            rope[#rope + 1] = "Infinity"
        elseif value == -math.huge then
            rope[#rope + 1] = "-Infinity"
        else
            local suffix =
                (value > 0 and options.explicit_plus_sign)
                and "+"
                or ""
            rope[#rope + 1] = suffix .. tostring(value)
        end
    end,
    ---@param rope string[]
    ---@param value boolean
    boolean = function(rope, value)
        rope[#rope + 1] = tostring(value)
    end,
    ---@param rope string[]
    ---@param value table
    ---@param options table
    ---@return string?
    table = function(rope, value, options)
        if value == json5.null then
            rope[#rope + 1] = "null"
            return
        elseif value == json5.empty_array then
            rope[#rope + 1] = "[]"
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

                local err = serializer[type(v)](rope, v, options)
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
                    if options.explicit_string_key or not k:match("^[%a%$_][%w_]*$") then
                        serializer.string(rope, k, options)
                    else
                        rope[#rope + 1] = k
                    end
                    rope[#rope + 1] = ":"
                    local err = serializer[type(v)](rope, v, options)
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
---@param options json5.encode_options?
---@return string?
---@return string?
---
--- Encode a table as JSON5 format.
--- If encoding failed, returns nil + error message.
---
function json5.encode(value, options)
    options = options or {}

    if options.json_compatible then
        options.explicit_positive_sign = false
        options.explicit_string_key = true
        options.use_single_quote = false
    end

    local rope = {}
    local err = serializer[type(value)](rope, value, options)
    if err then
        return nil, err
    end

    return table.concat(rope)
end

local escapes = {

}

local parse

---@alias parse_func function(result: any[], str: string[]): string?

---@type parse_func
local function parse_string(result, ptr)
    local str = ptr[1]
    local quote = str:sub(1, 1)

    local start = str:find(quote .. ".*")
    local _end = str:find(quote, 2)

    if not _end then
        return "unfinished string on byte " .. start
    end

    local err
    local content = str:sub(start + 1, _end - 1)
        :gsub("\\x(..)", function(c)
            local loc_start, loc_end = str:find("\\x" .. c)
            if not c:match("%x+") then
                err = "unexpected escape sequence " .. ("%d, %d"):format(loc_start, loc_end)
                return
            end
            ---@diagnostic disable-next-line: param-type-mismatch
            return string.char(tonumber("0x" .. c))
        end)
        :gsub("\\u(....)", function(c)
            local loc_start, loc_end = str:find("\\u" .. c)
            if not c:match("%x+") then
                err = "unexpected escape sequence " .. ("%d, %d"):format(loc_start, loc_end)
                return
            end
            ---@diagnostic disable-next-line: param-type-mismatch
            return codepoint_to_utf8(tonumber("0x" .. c))
        end)

    if err then
        return err
    end

    result[#result + 1] = content
    ptr[1] = ptr[1]:sub(_end + 1)
end

function parse(result, str)
    local result = {}
    local ptr = { str }

    while #str ~= 0 do
        local tok = str:sub(1, 1)
        if tok == '"' or tok == "'" then
            parse_string(result, ptr)
        end
    end

    return result[1]
end

json5.test = parse_string

return json5
