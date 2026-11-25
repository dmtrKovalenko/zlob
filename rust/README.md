# zlob

Zlob is a very fast glob implementation that is faster than ignore crate and event glibc. It is written in zig with hot paths for everythin and also allows globbing on the file path list in memory and provides a way more flexible API and support for a way larger set of patterns.

## Requirements

You do not need to install anything. The library is written in Zig, and the build script finds a compiler in this order:

1. The compiler named by the `ZIG` environment variable.
2. `zig` on your `PATH`, when it is 0.17.1 or newer.
3. Zig 0.17.1 downloaded from ziglang.org for your machine, checked against a pinned sha256 and kept in the build directory. This step needs `curl` and `tar` (with `xz` on Linux).

| Variable | Effect |
| --- | --- |
| `ZLOB_NO_ZIG_DOWNLOAD=1` | Never download; fail with install instructions instead. `CARGO_NET_OFFLINE=true` does the same. |
| `ZLOB_ZIG_MIRROR=<url>` | Try this [Zig mirror](https://ziglang.org/download/community-mirrors.txt) before ziglang.org. |
| `ZLOB_ZIG_CACHE_DIR=<dir>` | Keep the downloaded compiler here, so every build and project shares one copy (about 300 MB). |

## Misc

zlob rust's crate is maintained by the authors of zlob zig sources so this crate is officially supported and updated on every release.

Find the rust docs on [docs.rs](https://docs.rs/zlob) and the zig sources on [github](https://github.com/dmtrKovalenko/zlob)
