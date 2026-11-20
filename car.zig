//! Offline reader for AT Protocol `repo.car` exports.
//!
//! Covers CAR v1 framing (varint-prefixed sections), binary CIDv0/v1
//! parsing, a DAG-CBOR subset decoder, and the Merkle Search Tree walk
//! that yields sorted `<collection>/<rkey>` → record entries. Pure parser:
//! no modes, no output writes, no network. `--mode=atproto*` consumes this.
//!
//! The CBOR subset is exactly what repo.car needs: unsigned/negative ints,
//! byte and text strings, arrays, text-keyed maps, tag-42 CID links, and
//! the simple values null/true/false/undefined. Floats, indefinite-length
//! items, and non-42 tags are `error.UnsupportedCbor`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidCar,
    InvalidCid,
    UnsupportedCid,
    TruncatedCbor,
    UnsupportedCbor,
    MissingBlock,
    MalformedMst,
    OutOfMemory,
};

pub const MapEntry = struct {
    key: []const u8,
    value: Value,
};

/// Decoded CBOR value. `link` holds the raw CID bytes of a tag-42
/// reference with the leading multibase NUL already stripped — identical
/// to the CID bytes used as block keys in a CAR file.
pub const Value = union(enum) {
    uint: u64,
    nint: u64, // value is -(nint + 1); kept positive to avoid overflow
    bytes: []const u8,
    text: []const u8,
    array: []const Value,
    map: []const MapEntry,
    link: []const u8,
    boolean: bool,
    nil,
    undefined_simple,
};

pub fn mapGet(map: []const MapEntry, key: []const u8) ?Value {
    for (map) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

const Decoder = struct {
    data: []const u8,
    pos: usize = 0,
    a: Allocator,
    depth: usize = 0,

    const max_depth = 256;

    fn take(self: *Decoder, n: usize) Error![]const u8 {
        if (n > self.data.len - self.pos) return error.TruncatedCbor;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn head(self: *Decoder) Error!struct { major: u8, addl: u8, arg: u64 } {
        const b = (try self.take(1))[0];
        const major = b >> 5;
        const addl = b & 0x1F;
        const arg: u64 = switch (addl) {
            0...23 => addl,
            24 => (try self.take(1))[0],
            25 => std.mem.readInt(u16, (try self.take(2))[0..2], .big),
            26 => std.mem.readInt(u32, (try self.take(4))[0..4], .big),
            27 => std.mem.readInt(u64, (try self.take(8))[0..8], .big),
            else => return error.UnsupportedCbor, // 28-31 indefinite/reserved
        };
        return .{ .major = major, .addl = addl, .arg = arg };
    }

    fn item(self: *Decoder) Error!Value {
        const h = try self.head();
        switch (h.major) {
            0 => return .{ .uint = h.arg },
            1 => return .{ .nint = h.arg },
            2 => {
                if (h.arg > self.data.len - self.pos) return error.TruncatedCbor;
                return .{ .bytes = try self.take(@intCast(h.arg)) };
            },
            3 => {
                if (h.arg > self.data.len - self.pos) return error.TruncatedCbor;
                return .{ .text = try self.take(@intCast(h.arg)) };
            },
            4 => {
                if (self.depth >= max_depth) return error.UnsupportedCbor;
                self.depth += 1;
                defer self.depth -= 1;
                if (h.arg > self.data.len - self.pos) return error.TruncatedCbor;
                const items = try self.a.alloc(Value, @intCast(h.arg));
                for (items) |*it| it.* = try self.item();
                return .{ .array = items };
            },
            5 => {
                if (self.depth >= max_depth) return error.UnsupportedCbor;
                self.depth += 1;
                defer self.depth -= 1;
                if (h.arg > self.data.len - self.pos) return error.TruncatedCbor;
                const entries = try self.a.alloc(MapEntry, @intCast(h.arg));
                for (entries) |*e| {
                    const k = try self.item();
                    switch (k) {
                        .text => |t| e.key = t,
                        else => return error.UnsupportedCbor,
                    }
                    e.value = try self.item();
                }
                return .{ .map = entries };
            },
            6 => {
                if (h.arg != 42) return error.UnsupportedCbor;
                const inner = try self.item();
                switch (inner) {
                    .bytes => |b| {
                        if (b.len == 0 or b[0] != 0) return error.InvalidCid;
                        return .{ .link = b[1..] };
                    },
                    else => return error.InvalidCid,
                }
            },
            // addl (not arg) distinguishes simple values from float payloads:
            // 20-23 are false/true/null/undefined; 24+ is simple(n)/float.
            7 => switch (h.addl) {
                20 => return .{ .boolean = false },
                21 => return .{ .boolean = true },
                22 => return .nil,
                23 => return .undefined_simple,
                else => return error.UnsupportedCbor,
            },
            else => return error.UnsupportedCbor,
        }
    }
};

/// Decode one complete DAG-CBOR item; trailing bytes are an error.
pub fn decodeValue(a: Allocator, data: []const u8) Error!Value {
    var d = Decoder{ .data = data, .a = a };
    const v = try d.item();
    if (d.pos != data.len) return error.TruncatedCbor;
    return v;
}

fn readVarint(data: []const u8, pos: *usize) Error!u64 {
    var shift: u6 = 0;
    var out: u64 = 0;
    var count: usize = 0;
    while (true) {
        if (pos.* >= data.len) return error.InvalidCar;
        const b = data[pos.*];
        pos.* += 1;
        count += 1;
        if (count == 10) {
            // 10th byte of a u64 varint carries only bit 63.
            if (b != 1) return error.InvalidCar;
            return out | (@as(u64, 1) << 63);
        }
        out |= @as(u64, b & 0x7F) << shift;
        if (b & 0x80 == 0) return out;
        shift += 7;
    }
}

/// Length in bytes of a binary CID at `data[0..]` (CIDv0 or CIDv1).
/// CIDv0: 0x12 0x20 + 32-byte digest (dag-pb multihash, no codec).
/// CIDv1: 0x01 + varint codec + varint hash-type + varint len + digest.
fn cidPrefixLen(data: []const u8) Error!usize {
    if (data.len < 2) return error.InvalidCid;
    if (data[0] == 0x12 and data[1] == 0x20) {
        if (data.len < 34) return error.InvalidCid;
        return 34;
    }
    if (data[0] != 0x01) return error.UnsupportedCid;
    var pos: usize = 1;
    _ = try readVarint(data, &pos); // codec
    _ = try readVarint(data, &pos); // multihash type
    const mh_len = try readVarint(data, &pos);
    if (mh_len > 1024 or mh_len > data.len - pos) return error.InvalidCid;
    const end = pos + @as(usize, @intCast(mh_len));
    return end;
}

/// One MST entry resolved to its record bytes.
pub const Record = struct {
    /// Full `collection/rkey` key.
    key: []const u8,
    collection: []const u8,
    rkey: []const u8,
    /// Raw DAG-CBOR bytes of the record block (decode with decodeValue).
    record: []const u8,
};

/// Parsed repo.car: every block keyed by its raw CID bytes, the commit
/// metadata, and the MST root CID. All slices alias the input buffer or
/// the caller's arena — no copies beyond what the arena holds.
pub const Car = struct {
    blocks: std.StringHashMap([]const u8),
    /// Commit metadata (provenance only).
    did: []const u8 = "",
    rev: []const u8 = "",
    /// Raw CID of the MST root node (commit `data` link).
    mst_root: []const u8,

    /// In-order walk of the MST: sorted `<collection>/<rkey>` keys each
    /// resolved to its record block bytes. `error.MissingBlock` when the
    /// CAR omits a referenced block.
    pub fn records(self: *const Car, a: Allocator) ![]const Record {
        var out: std.ArrayList(Record) = .empty;
        var prev_key: std.ArrayList(u8) = .empty;
        try walkMst(a, self, self.mst_root, &prev_key, &out, 0);
        return try out.toOwnedSlice(a);
    }
};

fn walkMst(
    a: Allocator,
    car: *const Car,
    cid: []const u8,
    prev_key: *std.ArrayList(u8),
    out: *std.ArrayList(Record),
    depth: usize,
) Error!void {
    if (depth > 64) return error.MalformedMst;
    const node_bytes = car.blocks.get(cid) orelse return error.MissingBlock;
    const node = try decodeValue(a, node_bytes);
    const map = switch (node) {
        .map => |m| m,
        else => return error.MalformedMst,
    };
    if (mapGet(map, "l")) |lv| {
        switch (lv) {
            .link => |l| try walkMst(a, car, l, prev_key, out, depth + 1),
            .nil, .undefined_simple => {},
            else => return error.MalformedMst,
        }
    }
    const e_v = mapGet(map, "e") orelse return error.MalformedMst;
    const entries = switch (e_v) {
        .array => |arr| arr,
        else => return error.MalformedMst,
    };
    for (entries) |ent| {
        const em = switch (ent) {
            .map => |m| m,
            else => return error.MalformedMst,
        };
        const p: usize = blk: {
            const pv = mapGet(em, "p") orelse return error.MalformedMst;
            switch (pv) {
                .uint => |u| break :blk @intCast(u),
                else => return error.MalformedMst,
            }
        };
        const k = blk: {
            const k_v = mapGet(em, "k") orelse return error.MalformedMst;
            switch (k_v) {
                .bytes => |b| break :blk b,
                else => return error.MalformedMst,
            }
        };
        const v = blk: {
            const vv = mapGet(em, "v") orelse return error.MalformedMst;
            switch (vv) {
                .link => |l| break :blk l,
                else => return error.MalformedMst,
            }
        };
        if (p > prev_key.items.len) return error.MalformedMst;
        prev_key.shrinkRetainingCapacity(p);
        try prev_key.appendSlice(a, k);
        const key = try a.dupe(u8, prev_key.items);
        const record = car.blocks.get(v) orelse return error.MissingBlock;
        const sep = std.mem.indexOfScalar(u8, key, '/') orelse return error.MalformedMst;
        try out.append(a, .{
            .key = key,
            .collection = key[0..sep],
            .rkey = key[sep + 1 ..],
            .record = record,
        });
        if (mapGet(em, "t")) |tv| {
            switch (tv) {
                .link => |l| try walkMst(a, car, l, prev_key, out, depth + 1),
                .nil, .undefined_simple => {},
                else => return error.MalformedMst,
            }
        }
    }
}

/// Parse CAR v1 bytes: header `{version, roots:[commit]}`, then
/// varint-prefixed `cid | block` sections.
pub fn parse(a: Allocator, data: []const u8) Error!Car {
    var pos: usize = 0;
    const header_len = try readVarint(data, &pos);
    if (header_len > data.len - pos) return error.InvalidCar;
    const header = try decodeValue(a, try try_take(data, &pos, header_len));
    const hmap = switch (header) {
        .map => |m| m,
        else => return error.InvalidCar,
    };
    const version = mapGet(hmap, "version") orelse return error.InvalidCar;
    switch (version) {
        .uint => |v| {
            if (v != 1) return error.InvalidCar;
        },
        else => return error.InvalidCar,
    }
    const roots = blk: {
        const rv = mapGet(hmap, "roots") orelse return error.InvalidCar;
        switch (rv) {
            .array => |arr| break :blk arr,
            else => return error.InvalidCar,
        }
    };
    if (roots.len == 0) return error.InvalidCar;
    const commit_cid = switch (roots[0]) {
        .link => |l| l,
        else => return error.InvalidCar,
    };

    var car = Car{
        .blocks = std.StringHashMap([]const u8).init(a),
        .mst_root = "",
    };
    while (pos < data.len) {
        const slen = try readVarint(data, &pos);
        if (slen > data.len - pos) return error.InvalidCar;
        const section = data[pos .. pos + @as(usize, @intCast(slen))];
        pos += @intCast(slen);
        const cid_len = try cidPrefixLen(section);
        if (cid_len >= section.len) return error.InvalidCar;
        try car.blocks.put(section[0..cid_len], section[cid_len..]);
    }
    if (car.blocks.count() == 0) return error.InvalidCar;

    // roots[0] is the commit: {data: <mst root link>, did, rev, sig, prev}.
    const commit_bytes = car.blocks.get(commit_cid) orelse return error.MissingBlock;
    const commit = try decodeValue(a, commit_bytes);
    const cmap = switch (commit) {
        .map => |m| m,
        else => return error.InvalidCar,
    };
    const data_v = mapGet(cmap, "data") orelse return error.InvalidCar;
    car.mst_root = switch (data_v) {
        .link => |l| l,
        else => return error.InvalidCar,
    };
    if (mapGet(cmap, "did")) |dv| {
        switch (dv) {
            .text => |t| car.did = t,
            else => {},
        }
    }
    if (mapGet(cmap, "rev")) |rv| {
        switch (rv) {
            .text => |t| car.rev = t,
            else => {},
        }
    }
    return car;
}

fn try_take(data: []const u8, pos: *usize, n: u64) Error![]const u8 {
    if (n > data.len - pos.*) return error.InvalidCar;
    const nn: usize = @intCast(n);
    const s = data[pos.* .. pos.* + nn];
    pos.* += nn;
    return s;
}

/// Read and parse a `repo.car` file.
pub fn readCar(io: Io, a: Allocator, path: []const u8) !Car {
    const bytes = try readFileAlloc(io, Io.Dir.cwd(), path, a);
    return try parse(a, bytes);
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, a: Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(a, .unlimited);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Runtime CBOR builder helpers (canonical order not needed — the decoder
// accepts any key order).
fn t_uint(a: Allocator, n: u64) ![]u8 {
    if (n < 24) return try std.fmt.allocPrint(a, "{c}", .{@as(u8, @intCast(n))});
    if (n < 256) return try std.fmt.allocPrint(a, "\x18{c}", .{@as(u8, @intCast(n))});
    return error.UnsupportedCbor;
}

fn t_bytes(a: Allocator, b: []const u8) ![]u8 {
    if (b.len < 24) return try std.fmt.allocPrint(a, "{c}{s}", .{ @as(u8, 0x40 | @as(u8, @intCast(b.len))), b });
    if (b.len < 256) return try std.fmt.allocPrint(a, "\x58{c}{s}", .{ @as(u8, @intCast(b.len)), b });
    return error.UnsupportedCbor;
}

fn t_text(a: Allocator, s: []const u8) ![]u8 {
    if (s.len < 24) return try std.fmt.allocPrint(a, "{c}{s}", .{ @as(u8, 0x60 | @as(u8, @intCast(s.len))), s });
    if (s.len < 256) return try std.fmt.allocPrint(a, "\x78{c}{s}", .{ @as(u8, @intCast(s.len)), s });
    return error.UnsupportedCbor;
}

fn t_map(a: Allocator, pairs: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, 0xA0 | @as(u8, @intCast(pairs.len)));
    for (pairs) |p| try out.appendSlice(a, p);
    return try out.toOwnedSlice(a);
}

fn t_arr(a: Allocator, items: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, 0x80 | @as(u8, @intCast(items.len)));
    for (items) |i| try out.appendSlice(a, i);
    return try out.toOwnedSlice(a);
}

fn t_link(a: Allocator, cid: []const u8) ![]u8 {
    const tagged = try std.fmt.allocPrint(a, "\x00{s}", .{cid});
    const inner = try t_bytes(a, tagged);
    return try std.fmt.allocPrint(a, "\xD8\x2A{s}", .{inner});
}

fn kv(a: Allocator, key: []const u8, val: []const u8) ![]u8 {
    return try std.fmt.allocPrint(a, "{s}{s}", .{ try t_text(a, key), val });
}

fn t_varint(a: Allocator, n: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var v = n;
    while (true) {
        const b: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            try out.append(a, b);
            break;
        }
        try out.append(a, b | 0x80);
    }
    return try out.toOwnedSlice(a);
}

fn acid(a: Allocator, tag: u8) ![]u8 {
    return try a.dupe(u8, &fakeCid(tag));
}

fn fakeCid(tag: u8) [36]u8 {
    var c: [36]u8 = .{ 0x01, 0x71, 0x12, 0x20 } ++ @as([32]u8, @splat(0));
    for (4..36) |i| c[i] = tag;
    return c;
}

test "cidPrefixLen: v0 and v1" {
    const v0 = "\x12\x20" ++ @as([32]u8, @splat(0));
    try testing.expectEqual(@as(usize, 34), try cidPrefixLen(v0));
    const v1 = fakeCid(0xAA);
    try testing.expectEqual(@as(usize, 36), try cidPrefixLen(&v1));
    try testing.expectError(error.InvalidCid, cidPrefixLen("\x01"));
    try testing.expectError(error.UnsupportedCid, cidPrefixLen("\x02\x71"));
}

test "decodeValue: scalars and containers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try decodeValue(a, "\x18\x2A");
    try testing.expectEqual(@as(u64, 42), v.uint);
    const neg = try decodeValue(a, "\x38\x09");
    try testing.expectEqual(@as(u64, 9), neg.nint);
    const m = try decodeValue(a, try t_map(a, &.{ try kv(a, "k", try t_uint(a, 1)), try kv(a, "z", try t_text(a, "v")) }));
    try testing.expectEqualStrings("v", mapGet(m.map, "z").?.text);
    try testing.expectEqual(@as(u64, 1), mapGet(m.map, "k").?.uint);
    const link = try decodeValue(a, try t_link(a, &fakeCid(0xBB)));
    try testing.expectEqualSlices(u8, &fakeCid(0xBB), link.link);
    try testing.expectError(error.TruncatedCbor, decodeValue(a, "\x41"));
    try testing.expectError(error.UnsupportedCbor, decodeValue(a, "\xFB\x3F\xF0\x00\x00\x00\x00\x00\x00")); // 1.0 float
}

// Two-level MST: root entry "b/1" carries t → a subtree whose keys sort
// between it and the next entry. Child holds "b/2","b/3"; in-order yield
// must be b/1, b/2, b/3.
fn buildTwoLevelCar(a: Allocator) !Car {
    const cid_root = try acid(a, 0x01);
    const cid_child = try acid(a, 0x02);
    const cid_r1 = try acid(a, 0x11);
    const cid_r2 = try acid(a, 0x12);
    const cid_r3 = try acid(a, 0x13);
    const cid_commit = try acid(a, 0xFF);

    const e2 = try t_map(a, &.{ try kv(a, "k", try t_bytes(a, "b/2")), try kv(a, "p", try t_uint(a, 0)), try kv(a, "t", "\xF6"), try kv(a, "v", try t_link(a, cid_r2)) });
    const e3 = try t_map(a, &.{ try kv(a, "k", try t_bytes(a, "b/3")), try kv(a, "p", try t_uint(a, 0)), try kv(a, "t", "\xF6"), try kv(a, "v", try t_link(a, cid_r3)) });
    const child = try t_map(a, &.{ try kv(a, "e", try t_arr(a, &.{ e2, e3 })), try kv(a, "l", "\xF6") });
    const e1 = try t_map(a, &.{ try kv(a, "k", try t_bytes(a, "b/1")), try kv(a, "p", try t_uint(a, 0)), try kv(a, "t", try t_link(a, cid_child)), try kv(a, "v", try t_link(a, cid_r1)) });
    const root = try t_map(a, &.{ try kv(a, "e", try t_arr(a, &.{e1})), try kv(a, "l", "\xF6") });
    const commit = try t_map(a, &.{ try kv(a, "data", try t_link(a, cid_root)), try kv(a, "did", try t_text(a, "did:plc:test")), try kv(a, "rev", try t_text(a, "rev1")) });

    var blocks = std.StringHashMap([]const u8).init(a);
    try blocks.put(cid_root, root);
    try blocks.put(cid_child, child);
    try blocks.put(cid_commit, commit);
    try blocks.put(cid_r1, try t_map(a, &.{try kv(a, "r", try t_uint(a, 1))}));
    try blocks.put(cid_r2, try t_map(a, &.{try kv(a, "r", try t_uint(a, 2))}));
    try blocks.put(cid_r3, try t_map(a, &.{try kv(a, "r", try t_uint(a, 3))}));
    return .{ .blocks = blocks, .did = "did:plc:test", .rev = "rev1", .mst_root = cid_root };
}

test "walkMst: two-level tree yields in-order keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var car = try buildTwoLevelCar(a);
    const recs = try car.records(a);
    try testing.expectEqual(@as(usize, 3), recs.len);
    try testing.expectEqualStrings("b/1", recs[0].key);
    try testing.expectEqualStrings("b/2", recs[1].key);
    try testing.expectEqualStrings("b/3", recs[2].key);
    try testing.expectEqualStrings("b", recs[1].collection);
    try testing.expectEqualStrings("2", recs[1].rkey);
}

test "walkMst: left subtree sorts before first entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cid_root = try acid(a, 0x01);
    const cid_left = try acid(a, 0x02);
    const cid_ra = try acid(a, 0x10);
    const cid_rb = try acid(a, 0x11);
    const cid_commit = try acid(a, 0xFF);
    const eb = try t_map(a, &.{ try kv(a, "k", try t_bytes(a, "b/2")), try kv(a, "p", try t_uint(a, 0)), try kv(a, "t", "\xF6"), try kv(a, "v", try t_link(a, cid_rb)) });
    const root = try t_map(a, &.{ try kv(a, "e", try t_arr(a, &.{eb})), try kv(a, "l", try t_link(a, cid_left)) });
    const ea = try t_map(a, &.{ try kv(a, "k", try t_bytes(a, "b/1")), try kv(a, "p", try t_uint(a, 0)), try kv(a, "t", "\xF6"), try kv(a, "v", try t_link(a, cid_ra)) });
    const left = try t_map(a, &.{ try kv(a, "e", try t_arr(a, &.{ea})), try kv(a, "l", "\xF6") });
    const commit = try t_map(a, &.{try kv(a, "data", try t_link(a, cid_root))});
    var blocks = std.StringHashMap([]const u8).init(a);
    try blocks.put(cid_root, root);
    try blocks.put(cid_left, left);
    try blocks.put(cid_commit, commit);
    try blocks.put(cid_ra, try t_map(a, &.{try kv(a, "r", try t_uint(a, 0))}));
    try blocks.put(cid_rb, try t_map(a, &.{try kv(a, "r", try t_uint(a, 1))}));
    var car = Car{ .blocks = blocks, .mst_root = cid_root };
    const recs = try car.records(a);
    try testing.expectEqual(@as(usize, 2), recs.len);
    try testing.expectEqualStrings("b/1", recs[0].key);
    try testing.expectEqualStrings("b/2", recs[1].key);
}

test "parse: mini-atproto fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const bytes = try readFileAlloc(io, Io.Dir.cwd(), "fixtures/mini-atproto/repo.car", a);
    var car = try parse(a, bytes);
    try testing.expectEqualStrings("did:plc:testuser0000000000000", car.did);
    const recs = try car.records(a);
    try testing.expectEqual(@as(usize, 6), recs.len);
    // MST entries arrive in key-sorted order.
    const keys = [_][]const u8{
        "app.bsky.actor.profile/self",
        "app.bsky.feed.like/3klike1",
        "app.bsky.feed.post/3kpost1",
        "app.bsky.feed.post/3kpost2",
        "app.bsky.feed.post/3kpost3",
        "site.standard.document/3kdoc1",
    };
    for (keys, recs) |k, r| {
        try testing.expectEqualStrings(k, r.key);
        try testing.expect(r.record.len > 0);
    }
    const post = try decodeValue(a, recs[2].record);
    const ty = mapGet(post.map, "$type").?;
    try testing.expectEqualStrings("app.bsky.feed.post", ty.text);
}

test "parse: rejects truncated and rootless cars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidCar, parse(a, "\x05abc"));
    // header-only CAR: {version:1, roots:[]} — empty roots rejected.
    const hdr = try t_map(a, &.{ try kv(a, "roots", try t_arr(a, &.{})), try kv(a, "version", try t_uint(a, 1)) });
    const car_bytes = try std.fmt.allocPrint(a, "{s}{s}", .{ try t_varint(a, hdr.len), hdr });
    try testing.expectError(error.InvalidCar, parse(a, car_bytes));
    // version != 1 rejected even with valid framing.
    const hdr2 = try t_map(a, &.{ try kv(a, "roots", try t_arr(a, &.{})), try kv(a, "version", try t_uint(a, 2)) });
    const car_bytes2 = try std.fmt.allocPrint(a, "{s}{s}", .{ try t_varint(a, hdr2.len), hdr2 });
    try testing.expectError(error.InvalidCar, parse(a, car_bytes2));
}

test "decoder: hostile inputs error instead of crashing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Byte-string length = max u64 → TruncatedCbor, not an overflow panic.
    try testing.expectError(error.TruncatedCbor, decodeValue(a, "\x5B" ++ @as([8]u8, @splat(0xFF))));
    // Array length = max u64 → TruncatedCbor, not an overflow panic.
    try testing.expectError(error.TruncatedCbor, decodeValue(a, "\x9B" ++ @as([8]u8, @splat(0xFF))));
    // f16 whose bits (0x0015 = 21) collide with 'true' → UnsupportedCbor.
    try testing.expectError(error.UnsupportedCbor, decodeValue(a, "\xF9\x00\x15"));
    // 300 nested arrays exceed the depth cap → UnsupportedCbor, no stack overflow.
    const deep = try a.alloc(u8, 301);
    @memset(deep[0..300], 0x81);
    deep[300] = '0';
    try testing.expectError(error.UnsupportedCbor, decodeValue(a, deep));
    // 10 continuation bytes → InvalidCar, not a shift overflow.
    try testing.expectError(error.InvalidCar, parse(a, @as([10]u8, @splat(0xFF)) ++ "\x01"));
    // Multihash length varint = u64 max → InvalidCid, not an overflow panic.
    try testing.expectError(error.InvalidCid, cidPrefixLen("\x01\x71\x12" ++ @as([9]u8, @splat(0xFF)) ++ "\x01pad"));
}
