pub const ErrorCode = enum(u32) {
    Ok,
    UnknownScope,
    Timeout,
    InvalidLanguage,
    InvalidUtf8,
    InvalidRegex,
    InvalidQuery,
};

pub const TSHighlighter = anyopaque;

pub extern "C" fn ts_highlighter_new(
    highlight_names: [*]const [*:0]const u8,
    attribute_strings: [*]const [*:0]const u8,
    highlight_count: u32,
) *TSHighlighter;

// pub extern "C" fn ts_highlighter_add_language(
//     this: *TSHighlighter,
//     scope_name: [*]const u8,
//     injection_regex: [*]const u8,
//     language: Language,
//     highlight_query: [*]const u8,
//     injection_query: [*]const u8,
//     locals_query: [*]const u8,
//     highlight_query_len: u32,
//     injection_query_len: u32,
//     locals_query_len: u32,
// ) *TSHighlighter;
