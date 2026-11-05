# zlob

Zlob is a very fast glob implementation that is faster than ignore crate and event glibc. It is written in zig with hot paths for everythin and also allows globbing on the file path list in memory and provides a way more flexible API and support for a way larger set of patterns.

## Requirements

To compile this crate, install Zig 0.17.0 and add it to your `PATH`. iOS targets are currently broken by a standard library build error in Zig 0.17.0. [Download Zig](https://ziglang.org/download/)

## Misc

zlob rust's crate is maintained by the authors of zlob zig sources so this crate is officially supported and updated on every release.

Find the rust docs on [docs.rs](https://docs.rs/zlob) and the zig sources on [github](https://github.com/dmtrKovalenko/zlob)
