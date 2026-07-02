use std::env;
use std::path::PathBuf;
use std::process::Command;

// Minimal self-contained headers for bindgen. They rely only on clang's
// builtin target macros (__SIZE_TYPE__, __INTxx_TYPE__), so the widths always
// match the compilation target without needing any libc/sysroot.
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

fn main() {
    // docs.rs sets this env var; skip native build since Zig isn't available there
    if env::var("DOCS_RS").is_ok() {
        return;
    }

    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());

    // Find the zlob project root and determine source directory:
    // 1. For local dev: parent directory, sources in "src"
    // 2. For published crate: manifest_dir itself, sources in "zig-src"
    let (zlob_root, zig_src_dir) = if let Some(parent) = manifest_dir.parent() {
        if parent.join("build.zig").exists() && parent.join("include/zlob.h").exists() {
            // Local development - use parent directory with default "src"
            (parent.to_path_buf(), "src")
        } else if manifest_dir.join("build.zig").exists() {
            // Published crate - files are in manifest_dir, zig sources in "zig-src"
            (manifest_dir.clone(), "zig-src")
        } else {
            panic!(
                "Cannot find zlob source files.\n\
                 Checked parent: {}\n\
                 Checked manifest: {}\n\
                 Make sure build.zig and include/zlob.h exist.",
                parent.display(),
                manifest_dir.display()
            );
        }
    } else if manifest_dir.join("build.zig").exists() {
        (manifest_dir.clone(), "zig-src")
    } else {
        panic!(
            "Cannot find zlob source files in {}",
            manifest_dir.display()
        );
    };

    let header_path = zlob_root.join("include/zlob.h");

    if !header_path.exists() {
        panic!("Cannot find zlob header at {}", header_path.display());
    }

    println!("cargo:rerun-if-changed={}", header_path.display());
    println!(
        "cargo:rerun-if-changed={}",
        zlob_root.join(zig_src_dir).display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        zlob_root.join("build.zig").display()
    );

    let target = env::var("TARGET").unwrap();
    let host = env::var("HOST").unwrap();

    // zlob.h only needs size_t and the fixed-width integer types. Instead of
    // relying on the target's libc/toolchain headers (which are missing or
    // inconsistent across cross-compile setups: host glibc lacks the target's
    // bits/libc-header-start.h, and Zig's freestanding stdint.h references
    // undefined macros), we point clang at a self-contained stub that defines
    // exactly those types. `-nostdinc` guarantees only our stub is used.
    let stub_dir = out_dir.join("bindgen-stubs");
    std::fs::create_dir_all(&stub_dir).expect("create bindgen stub dir");
    std::fs::write(stub_dir.join("stddef.h"), STDDEF_STUB).expect("write stddef stub");
    std::fs::write(stub_dir.join("stdint.h"), STDINT_STUB).expect("write stdint stub");

    let mut builder = bindgen::Builder::default()
        .header(header_path.to_str().unwrap())
        .clang_arg("-nostdinc")
        .clang_arg(format!("-I{}", stub_dir.display()))
        .use_core()
        .generate_comments(false)
        .default_macro_constant_type(bindgen::MacroTypeVariation::Signed)
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()));

    // Give clang the target triple so integer/pointer widths match the target.
    if target != host {
        builder = builder.clang_arg(format!("--target={}", target));
    }

    let bindings = builder.generate().unwrap_or_else(|e| {
        panic!(
            "Unable to generate bindings from {}: {:?}",
            header_path.display(),
            e
        )
    });

    bindings
        .write_to_file(out_dir.join("zlob_bindings.rs"))
        .expect("Couldn't write bindings!");

    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".to_string());
    let zig_version = Command::new(&zig)
        .arg("version")
        .output()
        .expect("Failed to find zig. Please install zig or set the ZIG environment variable.");

    if !zig_version.status.success() {
        panic!("Failed to run zig. Please ensure zig is installed and accessible.");
    }

    // In CI, always map through rust_target_to_zig() so the produced artifact
    // uses the generic baseline CPU for that ISA. Otherwise Zig's "native"
    // would bake in whatever SIMD the CI runner happens to have (e.g.
    // AVX-512 on some Intel SKUs), and downstream users on older CPUs hit
    // SIGILL / "Illegal instruction" at runtime.
    //
    // For Windows targets, always map through rust_target_to_zig() regardless
    // of CI: using "native" on Windows would cause Zig to resolve to GNU/MinGW
    // ABI (because Zig ships its own MinGW libc), but Rust's MSVC linker
    // expects MSVC symbols (e.g., __chkstk vs ___chkstk_ms).
    let in_ci = env::var("CI").is_ok();
    let zig_target = if target == host && !target.contains("windows") && !in_ci {
        "native"
    } else {
        rust_target_to_zig(&target)
    };

    let profile = env::var("PROFILE").unwrap();
    let optimize = match profile.as_str() {
        "release" | "bench" => "ReleaseFast",
        _ => "Debug",
    };

    let zig_cache_dir = out_dir.join(".zig-cache");
    let zig_global_cache_dir = out_dir.join("zig-global-cache");

    let mut cmd = Command::new(&zig);
    cmd.current_dir(&zlob_root)
        .arg("build")
        .arg(format!("-Doptimize={}", optimize))
        .arg(format!("-Dsrc-dir={}", zig_src_dir))
        .arg("--cache-dir")
        .arg(&zig_cache_dir)
        .arg("--global-cache-dir")
        .arg(&zig_global_cache_dir)
        .arg("-Dskip-bench=true")
        .arg("-Dstatic-only=true")
        .arg("-p")
        .arg(out_dir.as_os_str());

    if zig_target != "native" {
        cmd.arg(format!("-Dtarget={}", zig_target));
    }

    println!(
        "cargo:warning=Building zlob from: {} (src-dir={})",
        zlob_root.display(),
        zig_src_dir
    );

    // Capture command string before running (cmd is consumed by output())
    let cmd_debug = format!("{:?}", cmd);
    println!("cargo:warning=Running: {}", cmd_debug);

    let output = cmd.output().expect("Failed to run zig build");
    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        eprintln!("\n========== ZIG BUILD FAILED ==========");
        eprintln!("Command: {}", cmd_debug);
        eprintln!("Status: {}", output.status);
        eprintln!("Working dir: {}", zlob_root.display());
        eprintln!("Target: {}", zig_target);
        eprintln!("Optimize: {}", optimize);

        if !stdout.is_empty() {
            eprintln!("\n----- STDOUT -----");
            eprintln!("{}", stdout);
            for line in stdout.lines() {
                println!("cargo:warning=[zig stdout] {}", line);
            }
        }
        if !stderr.is_empty() {
            eprintln!("\n----- STDERR -----");
            eprintln!("{}", stderr);
            for line in stderr.lines() {
                println!("cargo:warning=[zig stderr] {}", line);
            }
        }
        eprintln!("=====================================\n");

        panic!(
            "zig build failed with status: {}\nstdout: {}\nstderr: {}",
            output.status, stdout, stderr
        );
    }

    // zig's archiver sometimes can use bsd style that is 4 bytes aligned, we need to force it to 8
    // bytes alignment to match the macos/ios requirement for linking
    if target.contains("apple") {
        let lib = out_dir.join("lib").join("libzlob.a");
        let aligned = out_dir.join("lib").join("libzlob_aligned.a");
        // `q` appends: remove any stale output from a previous build first.
        let _ = std::fs::remove_file(&aligned);
        let status = Command::new(&zig)
            .arg("ar")
            .arg("--format=darwin")
            .arg("qLcs")
            .arg(&aligned)
            .arg(&lib)
            .status()
            .expect("failed to run `zig ar` to realign libzlob.a");
        if !status.success() {
            panic!("`zig ar --format=darwin` repack of libzlob.a failed: {status}");
        }
        std::fs::rename(&aligned, &lib).expect("failed to replace libzlob.a with aligned archive");
    }

    println!("cargo:rustc-link-search=native={}/lib", out_dir.display());
    println!("cargo:rustc-link-lib=static=zlob");
}

fn rust_target_to_zig(target: &str) -> &'static str {
    match target {
        // Linux - GNU
        "x86_64-unknown-linux-gnu" => "x86_64-linux-gnu",
        "aarch64-unknown-linux-gnu" => "aarch64-linux-gnu",
        "i686-unknown-linux-gnu" => "x86-linux-gnu",
        "armv7-unknown-linux-gnueabihf" => "arm-linux-gnueabihf",
        "armv7-unknown-linux-gnueabi" => "arm-linux-gnueabi",
        "powerpc64le-unknown-linux-gnu" => "powerpc64le-linux-gnu",
        "riscv64gc-unknown-linux-gnu" => "riscv64-linux-gnu",
        "s390x-unknown-linux-gnu" => "s390x-linux-gnu",
        "loongarch64-unknown-linux-gnu" => "loongarch64-linux-gnu",
        // Linux - musl
        "x86_64-unknown-linux-musl" => "x86_64-linux-musl",
        "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
        "i686-unknown-linux-musl" => "x86-linux-musl",
        "armv7-unknown-linux-musleabihf" => "arm-linux-musleabihf",
        "armv7-unknown-linux-musleabi" => "arm-linux-musleabi",
        // macOS
        "x86_64-apple-darwin" => "x86_64-macos",
        "aarch64-apple-darwin" => "aarch64-macos",
        // iOS
        "aarch64-apple-ios" => "aarch64-ios",
        "aarch64-apple-ios-sim" => "aarch64-ios-simulator",
        "x86_64-apple-ios" => "x86_64-ios-simulator",
        // Windows
        "x86_64-pc-windows-gnu" => "x86_64-windows-gnu",
        "x86_64-pc-windows-msvc" => "x86_64-windows-msvc",
        "i686-pc-windows-gnu" => "x86-windows-gnu",
        "i686-pc-windows-msvc" => "x86-windows-msvc",
        "aarch64-pc-windows-msvc" => "aarch64-windows-msvc",
        // FreeBSD
        "x86_64-unknown-freebsd" => "x86_64-freebsd",
        "aarch64-unknown-freebsd" => "aarch64-freebsd",
        // NetBSD
        "x86_64-unknown-netbsd" => "x86_64-netbsd",
        // Android
        "aarch64-linux-android" => "aarch64-linux-android",
        "armv7-linux-androideabi" => "arm-linux-androideabi",
        "x86_64-linux-android" => "x86_64-linux-android",
        "i686-linux-android" => "x86-linux-android",
        _ if target.contains("windows") => panic!(
            "Unsupported Windows target: '{}'. \
             Please add a mapping for this target in rust_target_to_zig(). \
             Using 'native' as a fallback on Windows is not safe because Zig \
             resolves to GNU/MinGW ABI, but Rust's MSVC linker expects MSVC symbols \
             (e.g., ___chkstk_ms vs __chkstk).",
            target
        ),
        _ => "native",
    }
}
