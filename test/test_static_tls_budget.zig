// Regression test for #298 in fff.nvim
//
// This test inspects the built libzlob.a archive for threadlocal symbols
// larger than a conservative per-symbol budget. glibc's default static-TLS
// reserve is small (≈2 KB + alignment), and anything north of ~16 KB risks
// exhausting it when the consuming `.so` is `dlopen`'d late.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const c = @cImport({
    @cInclude("stdlib.h");
});

/// Max tolerated size of a single TLS symbol in libzlob.a. 16 KB leaves
/// plenty of room for small per-thread state (thread ids, panic depth,
/// Io.Threaded.Thread.current pointer) while rejecting anything that
/// would blow out glibc's static-TLS budget in downstream consumers.
const MAX_TLS_SYMBOL_BYTES: u64 = 16 * 1024;

test "libzlob.a has no TLS symbols above the static-TLS budget" {
    // Only meaningful on platforms where glibc's static-TLS reserve is a
    // real constraint. Skip elsewhere so the test doesn't need cross-tool
    // availability on macOS/Windows CI.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (builtin.abi == .musl) return error.SkipZigTest;

    const archive_path_c = c.getenv("ZLOB_STATIC_ARCHIVE") orelse {
        std.debug.print(
            "ZLOB_STATIC_ARCHIVE not set; the build step should pass the archive path\n",
            .{},
        );
        return error.MissingArchivePath;
    };
    const archive_path = std.mem.sliceTo(archive_path_c, 0);

    const io = std.Io.Threaded.global_single_threaded.io();
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        archive_path,
        testing.allocator,
        .limited(64 * 1024 * 1024), // libzlob.a is a few MB at most
    );
    defer testing.allocator.free(contents);

    // Walk ELF objects inside the ar(5) archive and inspect their symbol
    // tables for any TLS symbol whose size exceeds the budget.
    var over_budget: u64 = 0;
    var worst_name: []const u8 = "";
    var worst_size: u64 = 0;

    var it = try ArchiveIterator.init(contents);
    while (try it.next()) |member| {
        if (!std.mem.startsWith(u8, member.data, "\x7fELF")) continue;
        try scanElfTls(member.data, &over_budget, &worst_name, &worst_size);
    }

    if (over_budget > 0) {
        std.debug.print(
            "libzlob.a contains TLS symbol '{s}' at {d} bytes (budget {d}). " ++
                "Did you remove the std_options.signal_stack_size = null override in c_lib.zig?\n",
            .{ worst_name, worst_size, MAX_TLS_SYMBOL_BYTES },
        );
        return error.TlsBudgetExceeded;
    }
}

/// Very small subset of ar(5) just enough to find ELF members.
const ArchiveIterator = struct {
    data: []const u8,
    pos: usize,

    const ar_magic = "!<arch>\n";
    const header_size = 60;

    fn init(data: []const u8) !ArchiveIterator {
        if (!std.mem.startsWith(u8, data, ar_magic)) return error.NotAnArArchive;
        return .{ .data = data, .pos = ar_magic.len };
    }

    fn next(self: *ArchiveIterator) !?struct { data: []const u8 } {
        // Align to even offset — ar pads members to 2 bytes.
        if (self.pos % 2 == 1) self.pos += 1;
        if (self.pos + header_size > self.data.len) return null;

        const size_field = std.mem.trimEnd(
            u8,
            self.data[self.pos + 48 .. self.pos + 58],
            " ",
        );
        const size = try std.fmt.parseInt(u64, size_field, 10);
        const start = self.pos + header_size;
        const end = start + size;
        if (end > self.data.len) return error.TruncatedArchive;

        self.pos = end;
        return .{ .data = self.data[start..end] };
    }
};

fn scanElfTls(
    elf: []const u8,
    over_budget: *u64,
    worst_name: *[]const u8,
    worst_size: *u64,
) !void {
    const Elf64_Ehdr = extern struct {
        e_ident: [16]u8,
        e_type: u16,
        e_machine: u16,
        e_version: u32,
        e_entry: u64,
        e_phoff: u64,
        e_shoff: u64,
        e_flags: u32,
        e_shentsize: u16,
        e_phentsize: u16,
        e_phnum: u16,
        e_shentsize2: u16,
        e_shnum: u16,
        e_shstrndx: u16,
    };
    const Elf64_Shdr = extern struct {
        sh_name: u32,
        sh_type: u32,
        sh_flags: u64,
        sh_addr: u64,
        sh_offset: u64,
        sh_size: u64,
        sh_link: u32,
        sh_info: u32,
        sh_addralign: u64,
        sh_entsize: u64,
    };
    const Elf64_Sym = extern struct {
        st_name: u32,
        st_info: u8,
        st_other: u8,
        st_shndx: u16,
        st_value: u64,
        st_size: u64,
    };

    if (elf.len < @sizeOf(Elf64_Ehdr)) return;
    const ehdr: *const Elf64_Ehdr = @ptrCast(@alignCast(elf.ptr));
    if (ehdr.e_ident[4] != 2) return; // 64-bit only

    const shoff = ehdr.e_shoff;
    const shnum = ehdr.e_shnum;
    if (shoff + @as(u64, shnum) * @sizeOf(Elf64_Shdr) > elf.len) return;

    const shdrs_ptr: [*]const Elf64_Shdr = @ptrCast(@alignCast(elf.ptr + shoff));
    const shdrs = shdrs_ptr[0..shnum];

    var symtab: ?[]const Elf64_Sym = null;
    var strtab: []const u8 = "";

    for (shdrs) |sh| {
        if (sh.sh_type == 2) { // SHT_SYMTAB
            const sym_ptr: [*]const Elf64_Sym = @ptrCast(@alignCast(elf.ptr + sh.sh_offset));
            const count = sh.sh_size / @sizeOf(Elf64_Sym);
            symtab = sym_ptr[0..count];
            const link = shdrs[sh.sh_link];
            strtab = elf[link.sh_offset .. link.sh_offset + link.sh_size];
        }
    }

    const syms = symtab orelse return;
    for (syms) |sym| {
        const st_type = sym.st_info & 0x0f;
        if (st_type != 6) continue; // STT_TLS
        if (sym.st_size <= MAX_TLS_SYMBOL_BYTES) continue;

        if (sym.st_size > worst_size.*) {
            const name_end = std.mem.indexOfScalar(u8, strtab[sym.st_name..], 0) orelse 0;
            worst_name.* = strtab[sym.st_name .. sym.st_name + name_end];
            worst_size.* = sym.st_size;
        }
        over_budget.* += sym.st_size;
    }
}
