use std::path::Path;

const STDDEF_STUB: &str = "#pragma once\ntypedef __SIZE_TYPE__ size_t;\n";
const STDINT_STUB: &str = "#pragma once\n\
typedef __INT8_TYPE__ int8_t;\n\
typedef __INT16_TYPE__ int16_t;\n\
typedef __INT32_TYPE__ int32_t;\n\
typedef __INT64_TYPE__ int64_t;\n\
typedef __UINT8_TYPE__ uint8_t;\n\
typedef __UINT16_TYPE__ uint16_t;\n\
typedef __UINT32_TYPE__ uint32_t;\n\
typedef __UINT64_TYPE__ uint64_t;\n\
typedef __INTPTR_TYPE__ intptr_t;\n\
typedef __UINTPTR_TYPE__ uintptr_t;\n";

// Run ZLOB_UPDATE_BINDINGS=1 cargo test --test bindings to update src/ffi.rs.
#[test]
fn bindings_match_public_header() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let stubs = tempfile::tempdir().unwrap();
    std::fs::write(stubs.path().join("stddef.h"), STDDEF_STUB).unwrap();
    std::fs::write(stubs.path().join("stdint.h"), STDINT_STUB).unwrap();
    let generate = |target: &str| {
        bindgen::Builder::default()
            .header(root.join("include/zlob.h").to_str().unwrap())
            .clang_arg("-nostdinc")
            .clang_arg(format!("-I{}", stubs.path().display()))
            .clang_arg(format!("--target={target}"))
            .use_core()
            .generate_comments(false)
            .layout_tests(false)
            .default_macro_constant_type(bindgen::MacroTypeVariation::Signed)
            .generate()
            .expect("generate zlob bindings")
            .to_string()
    };

    let bindings = generate("x86_64-unknown-linux-gnu");
    for target in [
        "i686-unknown-linux-gnu",
        "armv7-unknown-linux-gnueabihf",
        "aarch64-unknown-linux-gnu",
        "powerpc64le-unknown-linux-gnu",
        "s390x-unknown-linux-gnu",
        "riscv64-unknown-linux-gnu",
        "x86_64-apple-darwin",
        "aarch64-apple-darwin",
        "x86_64-pc-windows-gnu",
        "x86_64-pc-windows-msvc",
        "i686-pc-windows-msvc",
        "aarch64-pc-windows-msvc",
    ] {
        assert_eq!(bindings, generate(target), "bindings differ for {target}");
    }
    let file = root.join("src/ffi.rs");
    if std::env::var_os("ZLOB_UPDATE_BINDINGS").is_some() {
        std::fs::write(&file, &bindings).unwrap();
    }
    assert_eq!(bindings, std::fs::read_to_string(file).unwrap());
}
