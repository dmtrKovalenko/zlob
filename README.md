# zlob.h

<p align="center">
  <img src="./assets/zlob-logo.png" alt="zlob logo" />
</p>

100% POSIX and glibc compatible globbing library for C, Zig, and Rust that is **faster** and supports **all the modern globbing formats** and gitignore

---

zlob is a C library, zig library and a rust crate that makes globbing fast. Why? Because `glob()` implemented by glibc sucks. It is very outdated and slow. Remember when you last time read all the flags available exposed by glibc `glob(3)`? I am pretty sure you never read those because by default POSIX glob requires sorting of results list which is _VERY_ slow in glibc implementation, it doesn't implement very basic patterns like `./**/*.c` and requires to pass a flags to enable bracing support like `./{a,b}/*.c`.

In short libc's glob is unusable, so I wanted to make a library that is 100% POSIX and glibc compatible, that supports all the features modern glob implementation needed and is faster than glibc. So here is zlob, a little bit about it:

- 100% POSIX and glibc compatible with all the flags and features supported
- Faster than glibc up to 10x in specific cases and generally 1.2-1.7x faster. See [benchmarks](#Benchmarks)
- Faster than rust's, node's, bun's, python's implementation by far
- In addition to standard unix wildcard syntax supports `**` recursive patterns, braces `*.{c,h}`, `gitignore` and bash `extglob` patterns
- Supports `.gitignore` out of the box
- Exports api for matching over paths (one or many) without involving file system
- Exposes path length in the output struct for seamless FFI
- Truly optimized for all platforms: 
    - usage of [getdents64](https://linux.die.net/man/2/getdents64) syscall for faster directory listing
    - usage of [getattrslistbulk](https://man.freebsd.org/cgi/man.cgi?query=getattrlistbulk&sektion=2&manpath=macOS+13.6.5) on macos when requesting metadata from the walker
    - uses ntdll directly on windows
    - windows paths & patterns are normalized at compile time (both "/" and "\" accepted and treated the same in patterns)

Used and built for [fff](https://github.com/dmtrKovalenko/fff) loved by more projects!

## Why it is faster?

zlob is using SIMD first implementation. It is a primary reason it is written in zig to have a native portable SIMD support at a languages level, it significantly reduces certain bottlenecks. But the primary reason of speed is that zlob is firstly analyzes the pattern and then matches paths to this patterns making patterns like `./drivers/**/*.c` parsed to `[drivers]` and `*.c` which makes it not spend the time on opening useless directories and making lef matches like suffix for small extensions and other hot and common patterns to be faster because optimized for a hot branch invariant.

One of my favourite optimizations for this project is patterns like `./**/*.{c,rs,zig}` this is usually the main reason glob is used and this pattern is the most optimized in the zlob implementation:

- recursive worker is using `getdents64` syscall directly which dramatically improves directory listing
- gitignore implementation allows use to optionally skip large subdirectories out of the box
- and the actual `*.{c,rs,zig}` pattern is precompiled down the the SIMD bitmask matching that allows to match 3 extension at once

Checkout [benchmarks](##Benchmarks) yourself.

## Compatibility

As much as I could I converted all the tests that I found from the glibc test suite, rust's `glob` crate and nodejs's `fs.glob` function. It passes 100% of test suite for both file system and string paths matching. As long as this we have a compatibility layer with direct libc and bash for compatibility, check or extend it here [./test/test_libc_comparison.sh](./test/test_libc_comparison.sh)

## Supported patterns

Any pattern you may think of should be already supported including gnu symbol classes, negation of character group, and event bash's extglob syntax.

Here are some examples:

| Pattern                   | Requred flags  | Description                                       |
| ------------------------- | -------------- | ------------------------------------------------- |
| `*.c`                     |                | Match all `.c` in one dir                         |
| `./**/*.c`                |                | Match all `.c` in current and subdirs             |
| `**/*.c`                  |                | Match all `.c` in current and subdirs             |
| `./{a,b}/*.c`             | `ZLOB_BRACE`   | Match all `.c` in `a` and `b` dirs                |
| `./{test,src}/**/*.{c,h}` | `ZLOB_BRACE`   | Match all `.c` and `.h` in `test` and `src` dirs  |
| `~/*.c`                   | `ZLOB_TILDE`   | Match all `.c` in home directory                  |
| `[a-z]*.c`                |                | Match all `.c` starting with lowercase            |
| `*.[ch]`                  |                | Match all `.c` and `.h` and `.ch`                 |
| `*.[!ch]`                 |                | Match all files that do not end with `.c` or `.h` |
| `@(a \| b).c`             | `ZLOB_EXTGLOB` | Match all `.c` that are named `a.c` or `b.c`      |
| `@(!a).c`                 | `ZLOB_EXTGLOB` | Match all `.c` that are not named `a.c`           |


## API

zlob primarily support 3 public apis: C library, Zig library, and Rust crate

### C 
The easiest way is to look at `include/zlob.h` it exposes the same API as POSIX glob requires. Just change prefix glob -> zlob.

```c
#include "zlob.h"

glob_t globbuf;
// recommended flag is default set of settings we recommended, see below
int ret = zlob("*.c", ZLOB_RECOMMENDED, NULL, &globbuf);

if (ret == 0) {
    for (size_t i = 0; i < globbuf.gl_pathc; i
++) {
        printf("%s\n", globbuf.gl_pathv[i]);
    }
    zlobfree(&globbuf);
} else {
    fprintf(stderr, "glob error: %d\n", ret);
}
```


### Zig

zlob exposes a native zig module. Add it to your `build.zig.zon` and import as `@import("zlob")`.

```zig
const std = @import("std");
const zlob = @import("zlob");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    if (try zlob.match(allocator, init.io, "**/*.{zig,zon}", .{
        .brace = true,
        .gitignore = true,
    })) |*result| {
        defer result.deinit();
        var it = result.iterator();
        while (it.next()) |path| {
            std.debug.print("{s}\n", .{path});
        }
    }

    // or match against an in-memory path list: no allocations, no io
    const paths = [_][]const u8{
        "src/lib.zig",
        "src/main.zig",
        "README.md",
    };
    var result = try zlob.matchPaths(allocator, "*.zig", &paths, .{});
    defer result.deinit();

    var it = result.iterator();
    while (it.next()) |p| {
        std.debug.print("{s}\n", .{p});
    }
}
```

## Rust

zlob is also shared as an officially supported rust crate, find it on [crates.io](https://crates.io/crates/zlob) and read the [rust docs](https://docs.rs/zlob/1.4.2/zlob/)

```rust
use zlob::{zlob, zlob_match_paths, ZlobFlags};

fn main() -> Result<(), zlob::ZlobError> {
    if let Some(result) = zlob("**/*.{rs,toml}", ZlobFlags::RECOMMENDED)? {
        for path in &result {
            println!("{}", path);
        }
    }

    let paths = ["src/lib.rs", "src/main.rs", "README.md"];
    if let Some(matches) = zlob_match_paths("*.rs", &paths, ZlobFlags::GITIGNORE)? {
        for path in &matches {
            println!("{}", path);
        }
    }

    Ok(())
}
```

## Flags

Behavior is controlled using zlob flags. `ZLOB_RECOMMENDED` makes zlob behaves like a modern glob implementation without sorting the output results, and enabling all the modern features that you might need. Additional flags that might be used are:

### Included in ZLOB_RECOMMENDED

- `ZLOB_NOSORT` - do not sort the output results, this is default behavior and it is recommended to use it for better performance
- `ZLOB_BRACE` - enable support for `{a,b}` patterns
- `ZLOB_TILDE` - expand `~` to the home directory
- `ZLOB_TILDE_CHECK` - checks the user exists when expanding `~user` and returns error if it doesn't

### Not included in ZLOB_RECOMMENDED

- `ZLOB_GITIGNORE` - reads the `.gitignore` fil in the scanning directory first and uses as a prefilter
- `ZLOB_PERIOD` - Allows to match hidden files using `*` and `?` patterns, by default these patterns do not match hidden files
- `ZLOB_EXTGLOB` - enable support for bash extglob patterns like `@(pattern-list)`, `!(pattern-list)`, `?(pattern-list)`, `*(pattern-list)` and `+(pattern-list)`

- `ZLOB_FOLLOW_SYMLINKS` - follow symlinked directories when recursing with `**` (see [Symlinks and `**`](#symlinks-and-) below)
- `ZLOB_NOCHECK` - if no matches found return the pattern itself as the only result
- `ZLOB_NOMAGIC` - if the pattern contains no special characters return the pattern itself as the only result
- `ZLOB_NOESCAPE` - disable backslash escaping
- `ZLOB_MARK` - append a slash to each directory match
- `ZLOB_ONLYDIR` - only match directories
- `ZLOB_ERR` - return error on unreadable directories
- `ZLOB_APPEND` - append results to the output buffer instead of overwriting it
- `ZLOB_DOOFFS` - reserve `zlo_offs` slots in the output buffer for custom use, these slots will be filled with `NULL` and the actual results will start from `zlo_pathv[zlo_offs]`

In addition to this zlob exposes `zlob_at` function that will open specific directory instead of requiring to manipulate CWD

## Symlinks and `**`

By default `**` does **not** descend into symlinked directories. This matches
bash `globstar`, zsh `**`, and `walkdir` — the dominant `**` implementations.
Symlinks are still matched by name like any other entry; only the recursion
stops at them. POSIX `glob(3)` has no `**` at all, so there is no "glibc
default" to diverge from here.

Set `ZLOB_FOLLOW_SYMLINKS` to descend into symlinked directories. zlob keeps a
`(dev, ino)` visited-set so it **never loops** and **never emits the same
physical file twice**: each real directory is traversed at most once for the
whole walk.

This is a deliberate difference from `glob` crate / `nu-glob`, which follow
symlinks with no cycle tracking. On trees where one directory is reachable
through several symlinks (e.g. a Bazel `bazel-bin` / `bazel-out` /
`bazel-<workspace>` layout, all pointing into the same cache), those tools emit
every aliased path — inflating their count several-fold and looping until
`PATH_MAX` on a true cycle. zlob returns the de-duplicated set instead.

## MatchPaths mode

Match paths allowing you to submit a pointer of C strings or rust/zig-like slices and get the matches pointer back.

```c
const char *paths[] = {
    "src/main.c", "src/utils.c", "src/tests/test.h", "readme.md", "src/lib.c",
};
const size_t path_count = sizeof(paths) / sizeof(paths[0]);

zlob_t pzlob;
int result = zlob_match_paths("**/*.c", paths, path_count, ZLOB_RECOMMENDED, &pzlob);

// Make sure that this does NOT free the input paths, the pointer to the pats are owned by the caller
// and have to be freed by the caller only after the zlob_t struct is freed to prevent dangling pointer
zlobfree(&pzlob);
```

This allows a very fast SIMD processing of the paths and supports **NOT ALL** the features of the standard FS globbing except `ALTDIRFUNC` which is not applicable because this mode is done to avoid using ALTDIRFUNC all along. Make sure that if you will use `ZLOB_TILDE` flag the paths input have to be absolute. Other flags like nomagic might not work as expected because they generally make very little sense.


## Compilation

Obviously to compile zlob as a C library you have to have installed `zig` toolchain (**only 0.16.0**) and then you can use standard make commands:

```bash
make
make test
make install <PREFIX>
```

I know it might be annoying to install zig but zig's linker is currently a decent way to cross compiler any native code so I would definitely recommend trying it out.

## Benchmarks

Numbers below come from the criterion harness in `rust/benches/glob_comparison.rs`, comparing the `zlob` crate against the `glob` crate and the `globset` crate (paired with `walkdir` where it needs to walk the FS). The fixture is a Linux kernel checkout: **93,638 files / 6,157 directories / 36,685 `.c` files / 99 symlinks**.

Here is a benchmark. Median wall time, lower is better.

| Pattern (matches)         | zlob        | glob crate              | globset + walkdir        |
| ------------------------- | ----------: | ----------------------: | -----------------------: |
| `fs/*.c` (73)             | **9.84 µs** | 31.9 µs &nbsp; (3.2×)   | 40.3 ms &nbsp; (~4 100×) |
| `*/Makefile` (21)         | **11.4 µs** | 39.1 µs &nbsp; (3.4×)   | 40.4 ms &nbsp; (~3 550×) |
| `[fk]*/*.c` (179)         | **25.0 µs** | 81.8 µs &nbsp; (3.3×)   | 41.6 ms &nbsp; (~1 660×) |
| `drivers/*/*.c` (4 314)   | **700 µs**  | 1.70 ms &nbsp; (2.4×)   | 40.9 ms &nbsp; (58×)     |
| `drivers/**/*.c` (22 107) | **8.23 ms** | 16.4 ms &nbsp; (2.0×)   | 41.4 ms &nbsp; (5.0×)    |
| `net/**/*.c` (1 475)      | **230 µs**  | 597 µs &nbsp; (2.6×)    | 40.2 ms &nbsp; (175×)    |
| `net/**/*.{c,h}` (1 747)  | **266 µs**  | n/a (no brace support)  | 40.3 ms &nbsp; (151×)    |
| `**/*.c` (36 685)         | **24.2 ms** | 49.2 ms &nbsp; (2.0×)   | 43.8 ms &nbsp; (1.8×)    |

> Hardware / config: Linux x86_64 Intel(R) Core(TM) i7-14700K, 14 cores (28vcpu), ReleaseFast static build via `zig 0.16.0` & `cargo bench` via criterion

Reproduce with:

```bash
# clones a shallow Linux kernel into /tmp/linux if no path is given
scripts/run-benchmarks.sh [/path/to/linux]
```

The script just sets `REPO=` and runs `cargo bench --bench glob_comparison`. The harness prints a match-count parity table at startup so you can see whether each library is doing the same amount of work.

## Naming

This is my favourite part. `zlob` is not just zig zlob but also it means redneck in a varios Eastern-European languages but in polish it means "a manger", which I find very funny.

## License

zlob is licensed under MIT license, see [LICENSE](./LICENSE.md) file for more details.

P.S. No AI was used in the making of this README.md file thank you for reading it till the end.

