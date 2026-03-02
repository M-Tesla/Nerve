//! libmdbx C bindings via @cImport.
//! This is the only bridge to the C world — all other modules
//! import from here and never use @cImport directly.

pub const mdbx = @cImport({
    @cInclude("mdbx.h");
});
