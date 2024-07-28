# json5.lua
Pure Lua [JSON5](https://json5.org) parser and serializer

## Installation & Usage

Put [`json5.lua`](./json5.lua) into your project and then
```lua
local json5 = require("json5")
```

### `json5.encode(value, options)`

Parameters:
  - `value: any`: A value to be encoded into JSON5 format.
  - `options: table`:
    - `explicit_string_key: boolean`: Explictly wrap key in quote regardless if it's a valid JSON5 identifier.
    - `explicit_positive_sign: boolean`: Explicitly add positive sign prefix to numbers.
    - `use_single_quote: boolean`: Use single quotes for string instead of double quotes
    - `json_compatible: boolean`: Enable compatibility with JSON, this will disables JSON5 goodies.

Returns: `string`

### `json5.decode(str)`

Parameters:
  - `str: string`: A JSON5 format string.

Returns: `any`
