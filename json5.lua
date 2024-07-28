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

-- forward decl
local check_chars, getchar

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
    x = function(str, quote)
        local err = check_chars(str, 2, quote, "incomplete hex escape")
        if err then
            return nil, err
        end

        local hexdigits
        hexdigits, str = getchar(str, 2)

        local num = tonumber("0x" .. hexdigits)
        if not num then
            return nil, "not a hex '" .. hexdigits .. "'"
        end

        return string.char(num), str
    end,
    u = function(str, quote)
        local err = check_chars(str, 4, quote, "incomplete utf8 escape")
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
            return char, str
        else
            return nil, char
        end
    end
}

local line_sep = "\226\128\168"
local parag_sep = "\226\128\169"

---@param str string
---@param n number?
---@return string
---@return string
function getchar(str, n)
    n = n or 1
    return str:sub(1, n), str:sub(1 + n)
end

---@param str string
---@param len integer
---@param quote string
---@param err string
function check_chars(str, len, quote, err)
    for i = 1, len do
        local c = str:sub(i, i)
        if c == quote or c == "" then
            return err
        end
    end
end

---@alias lex_func fun(tokens: any[], str: string): string?, string?

---@type lex_func
local function lex_string(tokens, str)
    local quote = str:match("^['\"]")
    if not quote then
        return str
    end
    _, str = getchar(str)

    local buff = {}
    local has_end_quote
    while #str ~= 0 do
        local c
        c, str = getchar(str)
        if c == quote then
            has_end_quote = true
            break
        end

        if c == "\\" then
            c, str = getchar(str)
            local escaped_c = escape_str[c]
            if not escaped_c and c == "\n" or c == "\r" then
                c, str = getchar(str)
                if c == "\r" then
                    c, str = getchar(str)
                end
                if c == quote then
                    has_end_quote = true
                    break
                end
            elseif not escaped_c and c == "\226" then
                _, str = getchar(str, 2)
                c, str = getchar(str)
                if c == quote then
                    has_end_quote = true
                    break
                end
            elseif type(escaped_c) == "string" then
                c = escape_str[c]
            elseif type(escaped_c) == "function" then
                c, str = escaped_c(str, quote)
                if not c and str then
                    return nil, str
                end
            else
                return nil, "unknown escape sequence '\\" .. c .. "'"
            end
        end

        buff[#buff + 1] = c
    end

    ---@diagnostic disable-next-line: cast-local-type
    buff = table.concat(buff)
    if not has_end_quote then
        return nil, "expected end-of-string quote"
    end

    tokens[#tokens + 1] = buff
    return str
end

---@type lex_func
local function lex_number(tokens, str)
    if not matchs(str,
            "^[-+]?Infinity",
            "^[-+]?NaN",
            "^[-+]?%.?%d")
    then
        return str
    end

    local num

    local negate = ""
    local c, strclone = getchar(str)
    if c:match("[-+]") then
        negate = c == "-" and "-" or ""
        str = strclone
    end

    local special_num
    special_num, strclone = getchar(str, 8)
    if special_num:match("^Infinity") then
        num = math.huge
        if negate == "-" then
            num = -num
        end
        str = strclone
    elseif special_num:match("^NaN") then
        num = 0 / 0
        str = str:sub(4)
    end

    if not num then
        num = {}
        while #str ~= 0 do
            c, str = getchar(str)
            if c:match("[^0-9.eE]") then
                str = c .. str
                break
            end
            num[#num + 1] = c
        end
        num = tonumber(negate .. table.concat(num), 10)
    end

    tokens[#tokens + 1] = num

    return str
end

---@type lex_func
local function lex_hex(tokens, str)
    if not str:match("^[-+]?0[Xx]%x") then
        return str
    end

    local negate = ""
    local c, strclone = getchar(str)
    if c:match("[-+]") then
        negate = c == "-" and "-" or ""
        str = strclone
    end

    local num = {}
    while #str ~= 0 do
        c, str = getchar(str)
        if c:match("[^xX%x]") then
            str = c .. str
            break
        end
        num[#num + 1] = c
    end
    ---@diagnostic disable-next-line: cast-local-type
    num = tonumber(negate .. table.concat(num), 16)

    tokens[#tokens + 1] = num

    return str
end

---@type lex_func
local function lex_boolean(tokens, str)
    local bool, strclone = getchar(str, 5)
    if bool:match("^false") then
        tokens[#tokens + 1] = false
        str = strclone
    elseif bool:match("^true") then
        tokens[#tokens + 1] = true
        str = str:sub(5)
    end

    return str
end

---@type lex_func
local function lex_null(tokens, str)
    local null, strclone = getchar(str, 4)
    if null == "null" then
        tokens[#tokens + 1] = json5.null
        str = strclone
    end

    return str
end

---@type lex_func
local function lex_comment(_, str)
    if not str:match("^//") then
        return str
    end

    _, str = getchar(str, 2)
    while #str ~= 0 do
        local c, strclone
        c, strclone = getchar(str)
        if c == "\n" or c == "\r" or c == line_sep or c == parag_sep or c == "" then
            str = strclone
            break
        end
    end

    return str
end

---@type lex_func
local function lex_comment_long(_, str)
    if not str:match("^/%*") then
        return str
    end

    _, str = getchar(str, 2)
    while #str ~= 0 do
        local end_comment, strclone
        end_comment, strclone = getchar(str, 2)
        if end_comment == "*/" then
            str = strclone
            break
        end
        _, str = getchar(str)
    end

    return str
end

---@type lex_func
local function lex_identifier(tokens, str)
    -- TODO: allow unicode in identifier

    if tokens[#tokens] == ":" then
        return str
    end

    if not str:match("^[%a%$_][%w_]?") then
        return str
    end

    local buff = {}
    while #str ~= 0 do
        local c
        c, str = getchar(str)
        if c:match("[^%w%$_]") then
            str = c .. str
            break
        end
        buff[#buff + 1] = c
    end
    ---@diagnostic disable-next-line: cast-local-type
    buff = table.concat(buff)

    tokens[#tokens + 1] = setmetatable({ buff }, { __json5_lex = "identifier" })

    return str
end

local function lex(str)
    local tokens = {}

    while #str ~= 0 do
        local err
        local c, strclone = getchar(str)

        if c:match("[,:%[%]{}]") then
            tokens[#tokens + 1] = c
            str = strclone
        elseif c:match("%s") or c == "\226" then
            str = strclone
            if c == "\226" then
                c, strclone = getchar(str, 2)
                if c:match("\128[\168\169]") then
                    str = strclone
                end
            end
        else
            ---@diagnostic disable:param-type-mismatch
            str, err = lex_comment(tokens, str)
            if err then return nil, err end

            str, err = lex_comment_long(tokens, str)
            if err then return nil, err end

            str, err = lex_string(tokens, str)
            if err then return nil, err end

            str, err = lex_hex(tokens, str)
            if err then return nil, err end

            str, err = lex_number(tokens, str)
            if err then return nil, err end

            str, err = lex_boolean(tokens, str)
            if err then return nil, err end

            str, err = lex_null(tokens, str)
            if err then return nil, err end

            str, err = lex_identifier(tokens, str)
            if err then return nil, err end
            ---@diagnostic enable:param-type-mismatch
        end
    end

    return tokens
end

---@alias parse_func fun(tokens: any[]): any?, string|any[]

---@param tbl any
---@param typ string
---@return boolean
local function check_lex_type(tbl, typ)
    return type(tbl) == "table" and (getmetatable(tbl) or {}).__json5_lex == typ
end

local parse

---@type parse_func
local function parse_array(tokens)
    local t = {}

    if tokens[1] == "]" then
        table.remove(tokens, 1)
        return t, tokens
    end

    while #tokens ~= 0 do
        local tok = tokens[1]
        if tok == "]" then
            table.remove(tokens, 1)
            return t, tokens
        elseif tok == "," then
            return nil, "only single trailing comma is allowed in array"
        end

        local v
        v, tokens = parse(tokens)

        if check_lex_type(v, "identifier") then
            return nil, "invalid syntax: " .. v[1]
        end

        t[#t + 1] = v

        tok = tokens[1]
        if tok == "]" then
            table.remove(tokens, 1)
            return t, tokens
        elseif tok ~= "," then
            return nil, "expected comma after value in array"
        end

        table.remove(tokens, 1)
    end

    return nil, "expected end-of-array bracket"
end

---@type parse_func
local function parse_object(tokens)
    local t = {}

    if tokens[1] == "}" then
        table.remove(tokens, 1)
        return t, tokens
    end

    while #tokens ~= 0 do
        local tok = tokens[1]
        if tok == "}" then
            table.remove(tokens, 1)
            return t, tokens
        elseif tok == "," then
            return nil, "only single trailing comma is allowed in object"
        end

        local k = tokens[1]

        if type(k) == "string" then
            table.remove(tokens, 1)
        elseif check_lex_type(k, "identifier") then
            k = k[1]
            table.remove(tokens, 1)
        else
            return nil, "expected key to be string, got " .. type(k)
        end

        if table.remove(tokens, 1) ~= ":" then
            return nil, "expected colon after key in object"
        end

        local v
        v, tokens = parse(tokens)

        t[k] = v


        tok = tokens[1]
        if tok == "}" then
            table.remove(tokens, 1)
            return t, tokens
        elseif tok ~= "," then
            return nil, "expected comma after pair in object"
        end

        table.remove(tokens, 1)
    end

    return nil, "expected end-of-object bracket"
end

---@param tokens any[]
---@return any?
---@return any[]|string
function parse(tokens)
    local tok = table.remove(tokens, 1)

    if tok == "[" then
        return parse_array(tokens)
    elseif tok == "{" then
        return parse_object(tokens)
    elseif check_lex_type(tok, "identifier") then
        return nil, "unexpected identifer: " .. tok[1]
    else
        return tok, tokens
    end
end

function json5.decode(str)
    local v, err = lex(str)
    if err then
        return nil, err
    end
    ---@diagnostic disable-next-line: cast-local-type, param-type-mismatch
    v, err = parse(v)
    if not v and err then
        return nil, err
    end
    return v
end

return json5
