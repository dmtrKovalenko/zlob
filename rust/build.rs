use std::env;
use std::path::PathBuf;
use std::process::Command;

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

    let bindings = bindgen::Builder::default()
        .header(header_path.to_str().unwrap())
        .use_core()
        .generate_comments(false)
        .default_macro_constant_type(bindgen::MacroTypeVariation::Signed)
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .unwrap_or_else(|e| {
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

    let target = env::var("TARGET").unwrap();
    let host = env::var("HOST").unwrap();

    // For Windows targets, always map through rust_target_to_zig().
    // Using "native" on Windows would cause Zig to resolve to GNU/MinGW ABI
    // (because Zig ships its own MinGW libc), but Rust's MSVC linker expects
    // MSVC symbols (e.g., __chkstk vs ___chkstk_ms). This causes linker errors.
    let zig_target = if target == host && !target.contains("windows") {
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

    println!("cargo:rustc-link-search=native={}/lib", out_dir.display());
    println!("cargo:rustc-link-lib=static=zlob");
}

fn rust_target_to_zig(target: &str) -> &'static str {
    match target {
        "x86_64-unknown-linux-gnu" => "x86_64-linux-gnu",
        "x86_64-unknown-linux-musl" => "x86_64-linux-musl",
        "aarch64-unknown-linux-gnu" => "aarch64-linux-gnu",
        "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
        "i686-unknown-linux-gnu" => "x86-linux-gnu",
        "armv7-unknown-linux-gnueabihf" => "arm-linux-gnueabihf",
        "x86_64-apple-darwin" => "x86_64-macos",
        "aarch64-apple-darwin" => "aarch64-macos",
        "x86_64-pc-windows-gnu" => "x86_64-windows-gnu",
        "x86_64-pc-windows-msvc" => "x86_64-windows-msvc",
        "i686-pc-windows-gnu" => "x86-windows-gnu",
        "i686-pc-windows-msvc" => "x86-windows-msvc",
        "aarch64-pc-windows-msvc" => "aarch64-windows-msvc",
        "x86_64-unknown-freebsd" => "x86_64-freebsd",
        "aarch64-unknown-freebsd" => "aarch64-freebsd",
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
