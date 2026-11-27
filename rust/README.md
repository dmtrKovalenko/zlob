# zlob

Zlob is a very fast glob implementation that is faster than ignore crate and event glibc. It is written in zig with hot paths for everythin and also allows globbing on the file path list in memory and provides a way more flexible API and support for a way larger set of patterns.

## Requirements

You do not need to install Zig. The library is written in Zig, and every release ships it compiled for the common targets in the `zlob-prebuilt-*` crates. Cargo downloads the one for your target OS from crates.io, and the build script links it. Nothing else is downloaded at build time.

When there is no prebuilt library for your target, the build script compiles the Zig sources. That needs Zig 0.17.1 or newer on your `PATH` (or in `ZIG`). [Download Zig](https://ziglang.org/download/)

| Setting | Effect |
| --- | --- |
| `default-features = false` | Turn off the `prebuilt` feature: always compile with Zig, and keep the prebuilt crates out of your dependency tree. |
| `ZLOB_BUILD=source` | Always compile with Zig. |
| `ZLOB_BUILD=prebuilt` | Fail the build instead of falling back to Zig. |
| `ZLOB_ZIG_CPU=<cpu>` | Compile with Zig for this CPU (for example `x86_64_v3`). Prebuilt libraries use the baseline CPU. |

## Misc

zlob rust's crate is maintained by the authors of zlob zig sources so this crate is officially supported and updated on every release.

Find the rust docs on [docs.rs](https://docs.rs/zlob) and the zig sources on [github](https://github.com/dmtrKovalenko/zlob)
