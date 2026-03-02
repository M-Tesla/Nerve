//! Public types for the Monolith API.
//! Error set, flags, and structs used by the services.

const c = @import("c.zig").mdbx;

// ---------------------------------------------------------------------------
// Opaque DBI type (named database handle)
// ---------------------------------------------------------------------------
pub const Dbi = c.MDBX_dbi;

// ---------------------------------------------------------------------------
// Zig error set mapped from libmdbx return codes
// ---------------------------------------------------------------------------
pub const Error = error{
    /// Key not found (use null, not error, in cursor)
    NotFound,
    /// Page not found — DB corrupted
    PageNotFound,
    /// DB corrupted
    Corrupted,
    /// Panic — serious internal problem
    Panic,
    /// Incompatible version
    VersionMismatch,
    /// File is not a libmdbx DB
    Invalid,
    /// Map size exhausted — call env.setMapSize()
    MapFull,
    /// Max DBIs reached
    DbsFull,
    /// Max readers reached
    ReadersFull,
    /// Transaction too large
    TxnFull,
    /// Cursor stack overflow
    CursorFull,
    /// Internal page full
    PageFull,
    /// MMAP impossible — DB larger than address space
    UnableExtendMapSize,
    /// DBI incompatible with flags
    Incompatible,
    /// Invalid key (wrong size or type)
    BadValSize,
    /// Invalid transaction handle
    BadTxn,
    /// Invalid reference
    BadRslot,
    /// Invalid DBI handle
    BadDbi,
    /// I/O problem in mmap
    Problem,
    /// Environment already open
    Busy,
    /// MVCC conflict — retry required
    KeyExist,
    /// Generic system I/O error
    ErrnoIo,
    /// Other unmapped error
    Unknown,
};

/// Converts a C return code (int) to Error or void.
/// MDBX_SUCCESS (0) → void; MDBX_NOTFOUND is handled separately
/// in the cursor (returns null instead of error).
pub fn checkError(rc: c_int) Error!void {
    if (rc == c.MDBX_SUCCESS) return;
    return switch (rc) {
        c.MDBX_NOTFOUND         => Error.NotFound,
        c.MDBX_PAGE_NOTFOUND    => Error.PageNotFound,
        c.MDBX_CORRUPTED        => Error.Corrupted,
        c.MDBX_PANIC            => Error.Panic,
        c.MDBX_VERSION_MISMATCH => Error.VersionMismatch,
        c.MDBX_INVALID          => Error.Invalid,
        c.MDBX_MAP_FULL         => Error.MapFull,
        c.MDBX_DBS_FULL         => Error.DbsFull,
        c.MDBX_READERS_FULL     => Error.ReadersFull,
        c.MDBX_TXN_FULL         => Error.TxnFull,
        c.MDBX_CURSOR_FULL      => Error.CursorFull,
        c.MDBX_PAGE_FULL        => Error.PageFull,
        c.MDBX_UNABLE_EXTEND_MAPSIZE => Error.UnableExtendMapSize,
        c.MDBX_INCOMPATIBLE     => Error.Incompatible,
        c.MDBX_BAD_VALSIZE      => Error.BadValSize,
        c.MDBX_BAD_TXN         => Error.BadTxn,
        c.MDBX_BAD_RSLOT        => Error.BadRslot,
        c.MDBX_BAD_DBI          => Error.BadDbi,
        c.MDBX_PROBLEM          => Error.Problem,
        c.MDBX_BUSY             => Error.Busy,
        c.MDBX_KEYEXIST         => Error.KeyExist,
        else                    => Error.Unknown,
    };
}

// ---------------------------------------------------------------------------
// Environment flags
// ---------------------------------------------------------------------------
pub const EnvFlags = struct {
    /// Do not create subdirectory — the path is the file itself
    nosubdir: bool = true,
    /// Open in read-only mode
    rdonly: bool = false,
    /// Write directly into mmap (avoids shadow page copy)
    writemap: bool = false,
    /// No fsync per commit; trusts the OS page cache (faster,
    /// requires periodic env.sync() for durability)
    safe_nosync: bool = false,
    /// Do not fsync the metapage after commit (data protected, meta may
    /// lag one txn behind; mdbx recovers automatically on the next open)
    nometasync: bool = false,
    /// LIFO policy for recycled pages (better locality for SSDs and HDDs)
    liforeclaim: bool = false,

    pub fn toC(self: EnvFlags) c.MDBX_env_flags_t {
        var f: c.MDBX_env_flags_t = c.MDBX_ENV_DEFAULTS;
        if (self.nosubdir)    f |= c.MDBX_NOSUBDIR;
        if (self.rdonly)      f |= c.MDBX_RDONLY;
        if (self.writemap)    f |= c.MDBX_WRITEMAP;
        if (self.safe_nosync) f |= c.MDBX_SAFE_NOSYNC;
        if (self.nometasync)  f |= c.MDBX_NOMETASYNC;
        if (self.liforeclaim) f |= c.MDBX_LIFORECLAIM;
        return f;
    }
};

// ---------------------------------------------------------------------------
// DBI flags (passed to mdbx_dbi_open)
// ---------------------------------------------------------------------------
pub const DbFlags = struct {
    /// Create DBI if it does not exist
    create: bool = false,
    /// Allow multiple values per key (sorted duplicate keys)
    dupsort: bool = false,
    /// Keys are native integers (u32/u64), sorted numerically
    integerkey: bool = false,
    /// Duplicate values have fixed size (requires dupsort)
    dupfixed: bool = false,
    /// Duplicate values are native integers (requires dupsort)
    integerdup: bool = false,
    /// Keys are compared in reverse order
    reversekey: bool = false,

    pub fn toC(self: DbFlags) c.MDBX_db_flags_t {
        var f: c.MDBX_db_flags_t = c.MDBX_DB_DEFAULTS;
        if (self.create)     f |= c.MDBX_CREATE;
        if (self.dupsort)    f |= c.MDBX_DUPSORT;
        if (self.integerkey) f |= c.MDBX_INTEGERKEY;
        if (self.dupfixed)   f |= c.MDBX_DUPFIXED;
        if (self.integerdup) f |= c.MDBX_INTEGERDUP;
        if (self.reversekey) f |= c.MDBX_REVERSEKEY;
        return f;
    }
};

// ---------------------------------------------------------------------------
// Transaction flags
// ---------------------------------------------------------------------------
pub const TxnFlags = struct {
    rdonly: bool = false,

    pub fn toC(self: TxnFlags) c.MDBX_txn_flags_t {
        if (self.rdonly) return c.MDBX_TXN_RDONLY;
        return c.MDBX_TXN_READWRITE;
    }
};

// ---------------------------------------------------------------------------
// Put/cursor put flags
// ---------------------------------------------------------------------------
pub const PutFlags = struct {
    /// Do not overwrite if key already exists
    nooverwrite: bool = false,
    /// For dupsort: do not insert if (key, value) pair already exists
    nodupdata: bool = false,
    /// Only update existing record (do not insert new)
    current: bool = false,
    /// Append: key MUST be greater than the last (for sorted imports)
    append: bool = false,

    pub fn toC(self: PutFlags) c.MDBX_put_flags_t {
        var f: c.MDBX_put_flags_t = c.MDBX_UPSERT;
        if (self.nooverwrite) f |= c.MDBX_NOOVERWRITE;
        if (self.nodupdata)   f |= c.MDBX_NODUPDATA;
        if (self.current)     f |= c.MDBX_CURRENT;
        if (self.append)      f |= c.MDBX_APPEND;
        return f;
    }
};

// ---------------------------------------------------------------------------
// KV struct — key/value pair as byte slices
// ---------------------------------------------------------------------------
pub const KV = struct {
    key: []const u8,
    val: []const u8,
};
