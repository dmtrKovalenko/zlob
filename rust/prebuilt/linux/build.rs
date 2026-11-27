// Tells the zlob crate where the static library for the target is. The
// libraries are not in git: scripts/build-prebuilt.sh puts them in lib/ before
// this crate is published. Without one, zlob compiles its Zig sources.
fn main() {
    println!("cargo:rerun-if-changed=lib");
    let target = std::env::var("TARGET").unwrap();
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("lib")
        .join(target);
    if dir.is_dir() {
        println!("cargo:lib_dir={}", dir.display());
    }
}
