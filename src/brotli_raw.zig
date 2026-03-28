pub const c = @cImport({
    @cInclude("brotli/encode.h");
    @cInclude("brotli/decode.h");
});
