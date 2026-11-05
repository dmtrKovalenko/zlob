// Zig 0.17's formatter upgrades these builtins to spellings that Zig 0.16
// cannot compile. Keep the shared spellings here for iOS builds on 0.16.
// zig fmt: off
pub inline fn intFromEnum(value: anytype) @typeInfo(@TypeOf(value)).@"enum".tag_type {
    return @intFromEnum(value);
}

pub inline fn enumFromInt(comptime Enum: type, value: anytype) Enum {
    return @enumFromInt(value);
}
// zig fmt: on
