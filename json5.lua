local json5 = {}

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

local function matchs(str, ...)
    local ret = {}
    for i = 1, select("#", ...) do
        ret = { str:match(select(i, ...)) }
        if #ret ~= 0 then
            break
        end
    end
    return unpack(ret)
end

local function finds(str, ...)
    local ret = {}
    for i = 1, select("#", ...) do
        ret = { str:find(select(i, ...)) }
        if #ret ~= 0 then
            break
        end
    end
    return unpack(ret)
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
    string = function(rope, value)
        rope[#rope + 1] = '"' .. value:gsub(escape_patt, escapes) .. '"'
    end,
    ---@param rope string[]
    ---@param value number
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
    ---@param rope string[]
    ---@param value boolean
    boolean = function(rope, value)
        rope[#rope + 1] = tostring(value)
    end,
    ---@param rope string[]
    ---@param value table
    ---@return string?
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

local number_patts = {
    "^%-?Infinity",
    "^NaN",
    "^[eE]",
    "^%-?%d",
}

local escape_str = {
    b = "\b",
    f = "\f",
    n = "\n",
    r = "\r",
    t = "\t",
    v = "\v",
    ["0"] = "\0",
    ['"'] = '"',
    ["'"] = "'",
    ["\\"] = "\\",
}

local line_sep = "\226\128\168"
local parag_sep = "\226\128\169"

---@param str string
---@param n number?
---@return string
---@return string
local function getchar(str, n)
    n = n or 1
    return str:sub(1, n), str:sub(1 + n)
end

---@param str string
---@param len integer
---@param quote string
---@param err string
local function check_esc(str, len, quote, err)
    for i = 1, len do
        local c = str:sub(i, i)
        if c == quote or c == "" then
            return err
        end
    end
end

---@param tokens any[]
---@param str string
---@return string?
---@return string?
local function lex_string(tokens, str)
    local quote
    quote, str = getchar(str)
    if quote:match("[^'\"]") then
        return str
    end

    local buff = {}
    local has_end_quote
    local oldstr = str
    while #str ~= 0 do
        local c
        c, str = getchar(str)
        if c == quote then
            str = str:sub(2)
            has_end_quote = true
            break
        end

        if c == "\\" then
            c, str = getchar(str)
            if c:match("[bfnrtv0\"'\\]") then
                c = escape_str[c]
            elseif c == "x" then
                local err = check_esc(str, 2, quote, "incomplete hex escape")
                if err then
                    return nil, err
                end

                local hexdigits
                hexdigits, str = getchar(str, 2)
                print(hexdigits, str)
                local num = tonumber("0x" .. hexdigits)
                if not num then
                    return nil, "not a hex '" .. hexdigits .. "'"
                end

                c = string.char(num)
            elseif c == "\n" or c == "\r" or c == line_sep or c == parag_sep then
                c, str = getchar(str)
                if c == "\r" then
                    c, str = getchar(str)
                end
            elseif c == "u" then
                local err = check_esc(str, 4, quote, "incomplete utf8 escape")
                if err then
                    return nil, err
                end

                local codepoints
                codepoints, str = getchar(str, 4)
                local num = tonumber("0x" .. codepoints)
                if not num then
                    return nil, "not a hex '" .. codepoints .. "'"
                end

                local ok, char = pcall(codepoint_to_utf8, num)
                if ok and char then
                    c = char
                else
                    return nil, char
                end
            else
                return nil, "unknown escape sequence '" .. c .. "'"
            end
        end

        oldstr = str
        buff[#buff + 1] = c
    end

    ---@diagnostic disable-next-line: cast-local-type
    buff = table.concat(buff)
    if not has_end_quote then
        return nil, "expected end-of-string quote"
    end

    tokens[#tokens + 1] = buff
    return oldstr:sub(2)
end

--[[
local function lex(_, str)
    local tokens = {}

    while #str ~= 0 do
        local json_value
        if str:sub(1, 1):match("[\"']") then
            str:
        elseif matchs(str, unpack(number_patts)) then
            local _, new_length = finds(str, unpack(number_patts))
            new_length = new_length + 1
        end
    end
end
]]

json5.test = lex_string

return json5
