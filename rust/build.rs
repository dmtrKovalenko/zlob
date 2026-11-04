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

    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".to_string());
    let zig_version = Command::new(&zig)
        .arg("version")
        .output()
        .expect("Failed to find zig. Please install zig or set the ZIG environment variable.");

    if !zig_version.status.success() {
        panic!("Failed to run zig. Please ensure zig is installed and accessible.");
    }

    // Windows note: "native" would also resolve to GNU/MinGW ABI (Zig ships
    // its own MinGW libc), but Rust's MSVC linker expects MSVC symbols
    // (__chkstk vs ___chkstk_ms), so the explicit mapping is required there
    // regardless.
    let zig_target = rust_target_to_zig(&target);

    // allow to ovveride the cpu to a specific architecture e.g. x86_64v3 for AVX2
    println!("cargo:rerun-if-env-changed=ZLOB_ZIG_CPU");
    let zig_cpu = env::var("ZLOB_ZIG_CPU").ok().filter(|s| !s.is_empty());

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

    if let Some(cpu) = &zig_cpu {
        cmd.arg(format!("-Dcpu={}", cpu));
    } else if zig_target == "native" {
        // explicitly provide a baseline cpu otherwise we might be screwed
        cmd.arg("-Dcpu=baseline");
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
        "riscv64gc-unknown-linux-musl" => "riscv64-linux-musl",
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
