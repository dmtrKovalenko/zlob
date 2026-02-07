const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const ZlobFlags = zlob.ZlobFlags;

// End-to-end test for gitignore filtering with real filesystem operations.
// This test creates a temporary directory structure with a .gitignore file
// and verifies that glob correctly filters out ignored files and directories.
test "gitignore e2e - target directory is filtered" {
    const allocator = testing.allocator;

    // Create unique temp directory
    var tmp_dir_buf: [256]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/zlob_gitignore_e2e_{d}", .{std.time.milliTimestamp()});

    // Create temp directory
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create directory structure:
    // tmp/
    //   .gitignore (contains "target/")
    //   src/
    //     main.rs
    //     lib.rs
    //   target/
    //     debug/
    //       main.rs
    //       deps.rs
    //     release/
    //       main.rs
    //   Cargo.toml

    // Create directories
    const dirs = [_][]const u8{
        "src",
        "target",
        "target/debug",
        "target/release",
    };
    for (dirs) |dir| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, dir });
        try std.fs.makeDirAbsolute(full_path);
    }

    // Create files
    const files = [_][]const u8{
        "src/main.rs",
        "src/lib.rs",
        "target/debug/main.rs",
        "target/debug/deps.rs",
        "target/release/main.rs",
        "Cargo.toml",
    };
    for (files) |file| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, file });
        const f = try std.fs.createFileAbsolute(full_path, .{});
        f.close();
    }

    // Create .gitignore file
    {
        var gitignore_path_buf: [512]u8 = undefined;
        const gitignore_path = try std.fmt.bufPrint(&gitignore_path_buf, "{s}/.gitignore", .{tmp_dir});
        const gitignore_file = try std.fs.createFileAbsolute(gitignore_path, .{});
        defer gitignore_file.close();
        try gitignore_file.writeAll("target/\n");
    }

    // Test 1: Without gitignore flag - should find ALL .rs files including target/
    {
        var pattern_buf: [512]u8 = undefined;
        const pattern = try std.fmt.bufPrint(&pattern_buf, "{s}/**/*.rs", .{tmp_dir});

        var flags = ZlobFlags.recommended();
        flags.gitignore = false; // Explicitly disable gitignore

        var result = try zlob.match(allocator, pattern, flags);
        try testing.expect(result != null);
        defer result.?.deinit();

        // Should find all 5 .rs files
        try testing.expectEqual(@as(usize, 5), result.?.len());

        // Verify we have files from target/
        var has_target_file = false;
        if (result) |*r| {
            var it = r.iterator();
            while (it.next()) |path| {
                if (std.mem.indexOf(u8, path, "target/") != null) {
                    has_target_file = true;
                    break;
                }
            }
        }
        try testing.expect(has_target_file);
    }

    // Test 2: With gitignore flag - should NOT find files in target/
    {
        // Change to temp dir to test gitignore loading from CWD
        const original_cwd = std.fs.cwd();
        var tmp_dir_handle = try std.fs.openDirAbsolute(tmp_dir, .{});
        defer tmp_dir_handle.close();
        try tmp_dir_handle.setAsCwd();
        defer original_cwd.setAsCwd() catch {};

        var flags = ZlobFlags.recommended();
        flags.gitignore = true; // Enable gitignore

        var result = try zlob.match(allocator, "./**/*.rs", flags);
        try testing.expect(result != null);
        defer result.?.deinit();

        // Should find only 2 .rs files (src/main.rs and src/lib.rs)
        try testing.expectEqual(@as(usize, 2), result.?.len());

        // Verify NO files from target/
        if (result) |*r| {
            var it = r.iterator();
            while (it.next()) |path| {
                try testing.expect(std.mem.indexOf(u8, path, "target/") == null);
            }
        }

        // Verify we have the expected files
        var has_main = false;
        var has_lib = false;
        if (result) |*r| {
            var it = r.iterator();
            while (it.next()) |path| {
                if (std.mem.endsWith(u8, path, "src/main.rs")) has_main = true;
                if (std.mem.endsWith(u8, path, "src/lib.rs")) has_lib = true;
            }
        }
        try testing.expect(has_main);
        try testing.expect(has_lib);
    }
}

test "gitignore e2e - node_modules directory is filtered" {
    const allocator = testing.allocator;

    // Create unique temp directory
    var tmp_dir_buf: [256]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/zlob_gitignore_node_{d}", .{std.time.milliTimestamp()});

    // Create temp directory
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create directory structure for a Node.js project
    const dirs = [_][]const u8{
        "src",
        "node_modules",
        "node_modules/lodash",
        "node_modules/@types",
        "node_modules/@types/node",
    };
    for (dirs) |dir| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, dir });
        try std.fs.makeDirAbsolute(full_path);
    }

    // Create files
    const files_to_create = [_][]const u8{
        "src/index.js",
        "src/utils.js",
        "node_modules/lodash/index.js",
        "node_modules/@types/node/index.js",
        "package.json",
    };
    for (files_to_create) |file| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, file });
        const f = try std.fs.createFileAbsolute(full_path, .{});
        f.close();
    }

    // Create .gitignore file
    {
        var gitignore_path_buf: [512]u8 = undefined;
        const gitignore_path = try std.fmt.bufPrint(&gitignore_path_buf, "{s}/.gitignore", .{tmp_dir});
        const gitignore_file = try std.fs.createFileAbsolute(gitignore_path, .{});
        defer gitignore_file.close();
        try gitignore_file.writeAll("node_modules/\n");
    }

    // Change to temp dir
    const original_cwd = std.fs.cwd();
    var tmp_dir_handle = try std.fs.openDirAbsolute(tmp_dir, .{});
    defer tmp_dir_handle.close();
    try tmp_dir_handle.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    // Test with gitignore enabled
    var flags = ZlobFlags.recommended();
    flags.gitignore = true;

    var result = try zlob.match(allocator, "./**/*.js", flags);
    try testing.expect(result != null);
    defer result.?.deinit();

    // Should find only 2 .js files (src/index.js and src/utils.js)
    try testing.expectEqual(@as(usize, 2), result.?.len());

    // Verify NO files from node_modules/
    if (result) |*r| {
        var it = r.iterator();
        while (it.next()) |path| {
            try testing.expect(std.mem.indexOf(u8, path, "node_modules/") == null);
        }
    }
}

test "gitignore e2e - wildcard patterns" {
    const allocator = testing.allocator;

    // Create unique temp directory
    var tmp_dir_buf: [256]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/zlob_gitignore_wild_{d}", .{std.time.milliTimestamp()});

    // Create temp directory
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create directory structure
    const dirs = [_][]const u8{
        "src",
        "build",
    };
    for (dirs) |dir| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, dir });
        try std.fs.makeDirAbsolute(full_path);
    }

    // Create files - mix of .o files and source files
    const files_to_create = [_][]const u8{
        "src/main.c",
        "src/main.o",
        "src/utils.c",
        "src/utils.o",
        "build/app.o",
    };
    for (files_to_create) |file| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, file });
        const f = try std.fs.createFileAbsolute(full_path, .{});
        f.close();
    }

    // Create .gitignore file with wildcard pattern
    {
        var gitignore_path_buf: [512]u8 = undefined;
        const gitignore_path = try std.fmt.bufPrint(&gitignore_path_buf, "{s}/.gitignore", .{tmp_dir});
        const gitignore_file = try std.fs.createFileAbsolute(gitignore_path, .{});
        defer gitignore_file.close();
        try gitignore_file.writeAll("*.o\n");
    }

    // Change to temp dir
    const original_cwd = std.fs.cwd();
    var tmp_dir_handle = try std.fs.openDirAbsolute(tmp_dir, .{});
    defer tmp_dir_handle.close();
    try tmp_dir_handle.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    // Test with gitignore enabled - search for all files
    var flags = ZlobFlags.recommended();
    flags.gitignore = true;

    var result = try zlob.match(allocator, "./**/*.*", flags);
    try testing.expect(result != null);
    defer result.?.deinit();

    // Should find only .c files (2 files), not .o files
    try testing.expectEqual(@as(usize, 2), result.?.len());

    // Verify NO .o files
    if (result) |*r| {
        var it = r.iterator();
        while (it.next()) |path| {
            try testing.expect(!std.mem.endsWith(u8, path, ".o"));
        }
    }

    // Verify we have .c files
    var has_main_c = false;
    var has_utils_c = false;
    if (result) |*r| {
        var it = r.iterator();
        while (it.next()) |path| {
            if (std.mem.endsWith(u8, path, "main.c")) has_main_c = true;
            if (std.mem.endsWith(u8, path, "utils.c")) has_utils_c = true;
        }
    }
    try testing.expect(has_main_c);
    try testing.expect(has_utils_c);
}

// This test demonstrates the bug with anchored patterns like "rust/target/"
// Anchored patterns (containing /) are not checked in shouldSkipDirectory,
// so files inside ignored directories are still returned.
test "gitignore e2e - anchored directory patterns (rust/target/)" {
    const allocator = testing.allocator;

    // Create unique temp directory
    var tmp_dir_buf: [256]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/zlob_gitignore_anchored_{d}", .{std.time.milliTimestamp()});

    // Create temp directory
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create directory structure similar to a monorepo with rust subproject:
    // tmp/
    //   .gitignore (contains "rust/target/")
    //   rust/
    //     src/
    //       main.rs
    //       lib.rs
    //     target/
    //       debug/
    //         main.rs
    //         deps.rs

    // Create directories
    const dirs = [_][]const u8{
        "rust",
        "rust/src",
        "rust/target",
        "rust/target/debug",
    };
    for (dirs) |dir| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, dir });
        try std.fs.makeDirAbsolute(full_path);
    }

    // Create files
    const files_to_create = [_][]const u8{
        "rust/src/main.rs",
        "rust/src/lib.rs",
        "rust/target/debug/main.rs",
        "rust/target/debug/deps.rs",
    };
    for (files_to_create) |file| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, file });
        const f = try std.fs.createFileAbsolute(full_path, .{});
        f.close();
    }

    // Create .gitignore file with ANCHORED pattern (contains /)
    {
        var gitignore_path_buf: [512]u8 = undefined;
        const gitignore_path = try std.fmt.bufPrint(&gitignore_path_buf, "{s}/.gitignore", .{tmp_dir});
        const gitignore_file = try std.fs.createFileAbsolute(gitignore_path, .{});
        defer gitignore_file.close();
        // This pattern is anchored because it contains / before the trailing /
        try gitignore_file.writeAll("rust/target/\n");
    }

    // Change to temp dir
    const original_cwd = std.fs.cwd();
    var tmp_dir_handle = try std.fs.openDirAbsolute(tmp_dir, .{});
    defer tmp_dir_handle.close();
    try tmp_dir_handle.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    // Test with gitignore enabled
    var flags = ZlobFlags.recommended();
    flags.gitignore = true;

    var result = try zlob.match(allocator, "./**/*.rs", flags);
    try testing.expect(result != null);
    defer result.?.deinit();

    // Should find only 2 .rs files (rust/src/main.rs and rust/src/lib.rs)
    // NOT the files in rust/target/
    try testing.expectEqual(@as(usize, 2), result.?.len());

    // Verify NO files from rust/target/
    if (result) |*r| {
        var it = r.iterator();
        while (it.next()) |path| {
            try testing.expect(std.mem.indexOf(u8, path, "rust/target/") == null);
        }
    }
}

test "gitignore e2e - negation patterns" {
    const allocator = testing.allocator;

    // Create unique temp directory
    var tmp_dir_buf: [256]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/zlob_gitignore_neg_{d}", .{std.time.milliTimestamp()});

    // Create temp directory
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create directory structure
    const dirs = [_][]const u8{
        "logs",
    };
    for (dirs) |dir| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, dir });
        try std.fs.makeDirAbsolute(full_path);
    }

    // Create files
    const files_to_create = [_][]const u8{
        "logs/debug.log",
        "logs/error.log",
        "logs/important.log",
        "app.log",
    };
    for (files_to_create) |file| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, file });
        const f = try std.fs.createFileAbsolute(full_path, .{});
        f.close();
    }

    // Create .gitignore file with negation pattern
    {
        var gitignore_path_buf: [512]u8 = undefined;
        const gitignore_path = try std.fmt.bufPrint(&gitignore_path_buf, "{s}/.gitignore", .{tmp_dir});
        const gitignore_file = try std.fs.createFileAbsolute(gitignore_path, .{});
        defer gitignore_file.close();
        // Ignore all .log files except important.log
        try gitignore_file.writeAll("*.log\n!important.log\n");
    }

    // Change to temp dir
    const original_cwd = std.fs.cwd();
    var tmp_dir_handle = try std.fs.openDirAbsolute(tmp_dir, .{});
    defer tmp_dir_handle.close();
    try tmp_dir_handle.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    // Test with gitignore enabled
    var flags = ZlobFlags.recommended();
    flags.gitignore = true;

    var result = try zlob.match(allocator, "./**/*.log", flags);
    try testing.expect(result != null);
    defer result.?.deinit();

    // Should find only important.log (negation should re-include it)
    try testing.expectEqual(@as(usize, 1), result.?.len());

    // Verify we have important.log
    try testing.expect(std.mem.endsWith(u8, result.?.get(0), "important.log"));
}

test "gitignore e2e - negated subdirectory of ignored directory" {
    const allocator = testing.allocator;

    // Create unique temp directory
    var tmp_dir_buf: [256]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/zlob_gitignore_negdir_{d}", .{std.time.milliTimestamp()});

    // Create temp directory
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create directory structure:
    // tmp/
    //   .gitignore (contains "rust/target/" and "!rust/target/rust-analyzer/")
    //   rust/
    //     src/
    //       main.rs
    //     target/
    //       debug/
    //         app.rs        <- should be ignored
    //       rust-analyzer/
    //         analysis.rs   <- should NOT be ignored (negated)

    // Create directories
    const dirs = [_][]const u8{
        "rust",
        "rust/src",
        "rust/target",
        "rust/target/debug",
        "rust/target/rust-analyzer",
    };
    for (dirs) |dir| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, dir });
        try std.fs.makeDirAbsolute(full_path);
    }

    // Create files
    const files_to_create = [_][]const u8{
        "rust/src/main.rs",
        "rust/target/debug/app.rs",
        "rust/target/rust-analyzer/analysis.rs",
    };
    for (files_to_create) |file| {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, file });
        const f = try std.fs.createFileAbsolute(full_path, .{});
        f.close();
    }

    // Create .gitignore file with negation for subdirectory
    {
        var gitignore_path_buf: [512]u8 = undefined;
        const gitignore_path = try std.fmt.bufPrint(&gitignore_path_buf, "{s}/.gitignore", .{tmp_dir});
        const gitignore_file = try std.fs.createFileAbsolute(gitignore_path, .{});
        defer gitignore_file.close();
        // Ignore rust/target/ but NOT rust/target/rust-analyzer/
        try gitignore_file.writeAll("rust/target/\n!rust/target/rust-analyzer/\n");
    }

    // Change to temp dir
    const original_cwd = std.fs.cwd();
    var tmp_dir_handle = try std.fs.openDirAbsolute(tmp_dir, .{});
    defer tmp_dir_handle.close();
    try tmp_dir_handle.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    // Test with gitignore enabled
    var flags = ZlobFlags.recommended();
    flags.gitignore = true;

    var result = try zlob.match(allocator, "./**/*.rs", flags);
    try testing.expect(result != null);
    defer result.?.deinit();

    // Should find 2 files:
    // - rust/src/main.rs (not ignored)
    // - rust/target/rust-analyzer/analysis.rs (negation re-includes it)
    // Should NOT find:
    // - rust/target/debug/app.rs (ignored by rust/target/)
    try testing.expectEqual(@as(usize, 2), result.?.len());

    // Verify we have the expected files
    var has_main = false;
    var has_analysis = false;
    var has_debug_app = false;
    if (result) |*r| {
        var it = r.iterator();
        while (it.next()) |path| {
            if (std.mem.endsWith(u8, path, "rust/src/main.rs")) has_main = true;
            if (std.mem.endsWith(u8, path, "rust/target/rust-analyzer/analysis.rs")) has_analysis = true;
            if (std.mem.endsWith(u8, path, "rust/target/debug/app.rs")) has_debug_app = true;
        }
    }
    try testing.expect(has_main);
    try testing.expect(has_analysis);
    try testing.expect(!has_debug_app);
}
