local record json5
    record decode_options
        explicit_string_key: boolean
        explicit_positive_sign: boolean
        use_single_quote: boolean
        json_compatible: boolean
    end

    record opaque
    end

    null: opaque
    empty_array: opaque

    as_object: function({string:any}): {string:any}
    as_array: function({any}): {any}

    encode: function(any, decode_options): string
    decode: function(string): any
end

return json5
