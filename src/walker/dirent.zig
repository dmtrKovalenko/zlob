const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("dirent64 records are a Linux getdents64 concept; " ++
            "this module must not be referenced on other targets");
    }
}

pub const INO_OFFSET = 0;
pub const RECLEN_OFFSET = 16;
pub const TYPE_OFFSET = 18;
pub const NAME_OFFSET = 19;

comptime {
    const d64 = std.os.linux.dirent64;
    std.debug.assert(@offsetOf(d64, "ino") == INO_OFFSET);
    std.debug.assert(@offsetOf(d64, "reclen") == RECLEN_OFFSET);
    std.debug.assert(@offsetOf(d64, "type") == TYPE_OFFSET);
    std.debug.assert(@offsetOf(d64, "name") == NAME_OFFSET);
}

/// Length of the NUL-terminated name in a dirent record, scanned a word at a
/// time. Returns area_len if no NUL is present.
/// (yes it's a better faster SWAR implmeented `strnlen`)
pub inline fn nameLen(area_ptr: [*]const u8, area_len: usize) usize {
    const lo: u64 = 0x0101010101010101;
    const hi: u64 = 0x8080808080808080;
    var k: usize = 0;
    while (k < area_len) : (k += 8) {
        const w = mem.readInt(u64, area_ptr[k..][0..8], .little);
        const zero_mask = (w -% lo) & ~w & hi;
        if (zero_mask != 0) {
            return @min(k + (@ctz(zero_mask) >> 3), area_len);
        }
    }
    return area_len;
}
