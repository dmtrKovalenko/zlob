# zlob.h

100% POSIX and glibc compatible globbing library for C, Zig, and Rust that is **faster** and supports **all the modern globbing formats** (more than libc and rust `glob` crate)

---

zlob is a C library, zig library and a rust crate that makes globbing fast. Why? Because `glob()` implemented by glibc sucks. It is very outdated and slow. Remember when you last time read all the flags avaialble exposed by glibc `glob(3)`? I am pretty sure you never read those because by default POSIX glob requires sorting of results list which is _VERY_ slow in glibc implementaion, it doesn't implement very basic patterns like `./**/*.c` and requires to pass a flags to enable bracing support like `./{a,b}/*.c`.

In short libc's glob is unusable, so I wanted to make a library that is 100% POSIX and glibc compatible, that supports all the features modern glob implementation needed and is faster than glibc. So here is zlob, a little bit about it:

- 100% POSIX and glibc compatible with all the flags and features supported
- absolutely cross platform (does not yet support backslashes on windows but works under cygwin)
- Faster than glibc up to 10x in certain cases and for general cases 1.2-1.7x faster
- In addition to standard globbing supportes `**` recursive patterns, braces `*.{c,h}`, `gitignore` and bash `extglob` patterns
- SIMD first implementaion where needed
- Direct usage of [getdents64](https://linux.die.net/man/2/getdents64) syscall for faster directory listing
- Supports `.gitignore` out of the box
- Exposes a way better api for globbing over paths list in case you need to glob over a liT of filenames
- Exposes path length in the output struct meking it way better for FFI

## Why it is faster?

zlob is using SIMD first implemenation. It is a primary reason it is written in zig to have a native portable SIMD support, somewhere it signficantly improves certain bottlenecks. But the primary reason it is faster is that zlob is firstly analyzes the pattern and then matches paths to this patterns making patterns like `./drivers/**/*.c` parsed to `[drivers]` and `*.c` which makes it not spend the time on opening useless directores and making lef matches like suffix for small extensions and other hot and common patterns to be faster because optimized for a hot branch invariant.

One of my favourite optimizations for this project is patterns like `./**/*.{c,rs,zig}` this is usually the main reason glob is used and this pattern is the most optimized in the zlob implementation:

- recursive worker is using `getdents64` syscall directly which dramatically improves directory listing
- gitignore implemenation allows use to optionally skip large subdirectories out of the box
- and the actual `*.{c,rs,zig}` pattern is precompiled down the the SIMD bitmask matching that allows to match 3 extension at once

## Copmatibility

As much as I could I converted all the tests that I found from the glibc test suite, rust's `glob` crate and nodejs's `fs.glob` function. It passes 100% of test suite for both file system and string paths matching. As long as that it compares over 450 glob patterns with glibc for the same results count and the same outpu.

## Supported patterns

Any pattern you may think of should be already supported including gnu symbol classes, negation of charcter group, and event bash's extglob syntax.

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

The easierst way is to look at `include/zlob.h` but it exposes the same API as POSIX glob requires

```c
#include "zlob.h"

glob_t globbuf;
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

Behavior is controlled using zlob flags. `ZLOB_RECOMMENDED` makes zlob behaves like a modern glob implemenation without sorting the output results, and enabling all the modern features that you might need. Additional flags that might be used are:

### Included in ZLOB_RECOMMENDED

- `ZLOB_NOSORT` - do not sort the output results, this is default behavior and it is recommended to use it for better performance
- `ZLOB_BRACE` - enable support for `{a,b}` patterns
- `ZLOB_TILDE` - expand `~` to the home directory
- `ZLOB_TILDE_CHECK` - checks the user exists when expanding `~user` and returns error if it doesn't

### Not included in ZLOB_RECOMMENDED

- `ZLOB_GITIGNORE` - reads the `.gitignore` fil in the scanning directory first and uses as a prefilter
- `ZLOB_PERIOD` - Allows to match hidden files using `*` and `?` patterns, by default these patterns do not match hidden files
- `ZLOB_EXTGLOB` - enable support for bash extglob patterns like `@(pattern-list)`, `!(pattern-list)`, `?(pattern-list)`, `*(pattern-list)` and `+(pattern-list)`

- `ZLOB_NOCHECK` - if no matches found return the pattern itself as the only result
- `ZLOB_NOMAGIC` - if the pattern contains no special characters return the pattern itself as the only result
- `ZLOB_NOESCAPE` - disable backslash escaping
- `ZLOB_MARK` - append a slash to each directory match
- `ZLOB_ONLYDIR` - only match directories
- `ZLOB_ERR` - return error on unreadable directories
- `ZLOB_APPEND` - append results to the output buffer instead of overwriting it
- `ZLOB_DOOFFS` - reserve `zlo_offs` slots in the output buffer for custom use, these slots will be filled with `NULL` and the actual results will start from `zlo_pathv[zlo_offs]`

In addition to this zlob exposes `zlob_at` function that will open specific directory instead of requiring to manipulate CWD

## MatchPaths mode

Match paths allowing you to submit a pointer of C strings or rust/zig-like slices and get the matches pointer back

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

This allows a very fast SIMD processing of the paths and supports **NOT ALL** the features of the standard FS globbing except `ALTDIRFUNC` which is not applicable because this mode is done to avoid using ALTDIRFUNC all along. Make sure that if you will use `ZLOB_TILDE` flag the paths input have to be absolute. Other flags like nomagic might not work as expected because they generally makes very little sense.


## Rust

zlob is also shared as a rust crate you can find it on [crates.io](https://crates.io/crates/zlob) rust version is supported by this project authors and published automatically on every zlob release. It also requires zig toolchain to compile.

## Compilation

Obviously to compile zlob as a C library you have to have installed `zig` toolchain (**only 0.15.2**) and then you can use standard make commands:

```bash
make
make test
make install <PREFIX>
```

I know it might be annoying to install zig but zig's linker is currently a decent way to cross compiler any native code so I would definetely recommend trying it out.

## Naming

This is my favourite part. `zlob` is not just zig zlob but also it means redneck in a varios Eastern-European languaes but in polish it means "a manger", which I find very funny.

## License

zlob is licensed under MIT license, see [LICENSE](./LICENSE.md) file for more details.

P.S. No AI was used in the making of this README.md file thank you for reading it till the end.

