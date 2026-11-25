use std::env;
use std::path::{Path, PathBuf};
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

/// sha256 of every prebuilt library of this release, one `<sha256>  <file>`
/// per line after a `# zlob <version>` header. scripts/build-prebuilt.sh
/// writes it at release time, before the libraries are uploaded.
const PREBUILT_SUMS: &str = include_str!("prebuilt.sha256");
const PREBUILT_URL: &str = "https://github.com/dmtrKovalenko/zlob/releases/download";

#[derive(Debug)]
struct BindgenCallbacks {
    out_dir: PathBuf,
}

impl bindgen::callbacks::ParseCallbacks for BindgenCallbacks {
    fn header_file(&self, filename: &str) {
        self.include_file(filename);
    }

    fn include_file(&self, filename: &str) {
        // becuase we have to write libclang header for docs generation, but because we write it on
        // every build we invalidate the cargo builds on our own, so we want to avoid listing those
        // files in rerun-if-changed intrinsic
        if !std::path::Path::new(filename).starts_with(&self.out_dir) {
            println!("cargo:rerun-if-changed={filename}");
        }
    }

    fn read_env_var(&self, key: &str) {
        println!("cargo:rerun-if-env-changed={key}");
    }
}

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
    let host = env::var("HOST").unwrap();

    // zlob.h only needs size_t and the fixed-width integer types.
    // Instead of relying on the target's libc/toolchain headers which will be missing
    // in case of real cross compilation and docs generation
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
        .parse_callbacks(Box::new(BindgenCallbacks {
            out_dir: out_dir.clone(),
        }));

    // Give clang the target triple so integer/pointer widths match the target.
    // The triple must be one libclang can parse — Rust micro-arch suffixes
    // like the `gc` in `riscv64gc-...` are not valid clang arch names.
    if target != host {
        builder = builder.clang_arg(format!("--target={}", rust_target_to_clang(&target)));
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

    // A prebuilt library needs no Zig. Without one, compile from source.
    let in_checkout = zig_src_dir == "src";
    let no_prebuilt = match prebuilt_library(&target, &out_dir, in_checkout) {
        Ok(lib_dir) => {
            println!("cargo:rustc-link-search=native={}", lib_dir.display());
            println!("cargo:rustc-link-lib=static=zlob");
            return;
        }
        Err(why) => why,
    };

    println!("cargo:rerun-if-env-changed=ZIG");
    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".to_string());
    let zig_works = Command::new(&zig)
        .arg("version")
        .output()
        .is_ok_and(|o| o.status.success());
    if !zig_works {
        panic!(
            "zlob has no prebuilt library to use ({no_prebuilt}) and cannot run `{zig}` to \
             compile it.\nInstall Zig 0.17.1 or newer from https://ziglang.org/download/ or \
             set ZIG to the compiler path."
        );
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
        .env("ZIG_GLOBAL_CACHE_DIR", &zig_global_cache_dir)
        .arg("build")
        .arg(format!("-Doptimize={}", optimize))
        .arg(format!("-Dsrc-dir={}", zig_src_dir))
        .arg("--cache-dir")
        .arg(&zig_cache_dir)
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

/// Fetch the prebuilt static library for `target` and return the directory to
/// link from, or the reason to compile from source instead.
///
/// `ZLOB_BUILD=source` always compiles, `ZLOB_BUILD=prebuilt` fails the build
/// when no prebuilt library can be used. The default uses a prebuilt library
/// when one exists, except in a git checkout (where the Zig sources may have
/// local changes) and when `ZLOB_ZIG_CPU` asks for a non-baseline CPU.
fn prebuilt_library(target: &str, out_dir: &Path, in_checkout: bool) -> Result<PathBuf, String> {
    for var in ["ZLOB_BUILD", "ZLOB_PREBUILT_DIR", "ZLOB_PREBUILT_URL"] {
        println!("cargo:rerun-if-env-changed={var}");
    }
    println!("cargo:rerun-if-changed=prebuilt.sha256");

    let mode = env::var("ZLOB_BUILD").unwrap_or_default();
    let required = match mode.as_str() {
        "source" => return Err("ZLOB_BUILD=source".into()),
        "prebuilt" => true,
        "" | "auto" => false,
        other => panic!("ZLOB_BUILD must be `auto`, `prebuilt` or `source`, not `{other}`"),
    };

    let result = fetch_prebuilt(target, out_dir, required, in_checkout);
    match &result {
        Err(why) if required => panic!("ZLOB_BUILD=prebuilt, but {why}"),
        // The fallback is a normal outcome in a checkout; say why elsewhere.
        Err(why) if !in_checkout => println!("cargo:warning=zlob: compiling with Zig: {why}"),
        _ => {}
    }
    result
}

fn fetch_prebuilt(
    target: &str,
    out_dir: &Path,
    required: bool,
    in_checkout: bool,
) -> Result<PathBuf, String> {
    let local_dir = env::var_os("ZLOB_PREBUILT_DIR")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from);

    if !required {
        if in_checkout {
            return Err("this is a git checkout".into());
        }
        if env::var("ZLOB_ZIG_CPU").is_ok_and(|c| !c.is_empty()) {
            return Err("ZLOB_ZIG_CPU is set and prebuilt libraries use the baseline CPU".into());
        }
    }

    let asset = format!("libzlob-{target}.a");
    // A directory you built yourself carries its own checksum list.
    let sums = match &local_dir {
        Some(dir) if dir.join("prebuilt.sha256").exists() => {
            std::fs::read_to_string(dir.join("prebuilt.sha256")).map_err(|e| e.to_string())?
        }
        _ => PREBUILT_SUMS.to_string(),
    };
    let version = env::var("CARGO_PKG_VERSION").unwrap();
    if sums.lines().next() != Some(&format!("# zlob {version}")) {
        return Err(format!("the checksum list is not for zlob {version}"));
    }
    let expected = sums
        .lines()
        .filter_map(|line| line.split_once("  "))
        .find(|(_, name)| *name == asset)
        .map(|(sum, _)| sum)
        .ok_or(format!("there is no prebuilt library for {target}"))?;

    // rustc looks for zlob.lib on MSVC and libzlob.a everywhere else.
    let lib_dir = out_dir.join("prebuilt");
    let lib = lib_dir.join(if target.contains("msvc") {
        "zlob.lib"
    } else {
        "libzlob.a"
    });
    if verify_sha256(&lib, expected).is_ok() {
        return Ok(lib_dir);
    }
    std::fs::create_dir_all(&lib_dir).map_err(|e| e.to_string())?;

    let partial = lib_dir.join(format!("{asset}.partial"));
    let source = match &local_dir {
        Some(dir) => {
            let from = dir.join(&asset);
            std::fs::copy(&from, &partial).map_err(|e| format!("{}: {e}", from.display()))?;
            from.display().to_string()
        }
        None => {
            let base = env::var("ZLOB_PREBUILT_URL")
                .ok()
                .filter(|u| !u.is_empty())
                .unwrap_or_else(|| format!("{PREBUILT_URL}/v{version}"));
            let url = format!("{}/{asset}", base.trim_end_matches('/'));
            let status = Command::new("curl")
                .args(["--fail", "--location", "--silent", "--show-error"])
                .args(["--retry", "3", "--connect-timeout", "30", "--output"])
                .arg(&partial)
                .arg(&url)
                .status()
                .map_err(|e| format!("cannot run curl to download {url}: {e}"))?;
            if !status.success() {
                let _ = std::fs::remove_file(&partial);
                return Err(format!("curl could not download {url} ({status})"));
            }
            url
        }
    };

    if let Err(e) = verify_sha256(&partial, expected) {
        let _ = std::fs::remove_file(&partial);
        return Err(format!("{source}: {e}"));
    }
    std::fs::rename(&partial, &lib).map_err(|e| e.to_string())?;
    Ok(lib_dir)
}

fn verify_sha256(path: &Path, expected: &str) -> Result<(), String> {
    use sha2::{Digest, Sha256};

    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let actual: String = Sha256::digest(&bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    if actual == expected {
        Ok(())
    } else {
        Err(format!(
            "sha256 mismatch: expected {expected}, got {actual}"
        ))
    }
}

/// Map a Rust target triple to one libclang accepts.
///
/// Rust bakes micro-architecture extensions into the arch component (the `gc`
/// in `riscv64gc`, `imac` in `riscv32imac`, …) that clang's target parser does
/// not recognise, so passing the Rust triple straight to `--target=` makes
/// libclang fail with "unknown target triple". bindgen only needs the base ISA
/// to fix integer/pointer widths and the builtin `__riscv`/`__riscv_xlen`
/// macros, so collapse the arch component to its clang-known base and leave the
/// vendor/os/env components untouched.
fn rust_target_to_clang(target: &str) -> String {
    match target.split_once('-') {
        Some((arch, rest)) => {
            let clang_arch = if arch.starts_with("riscv32") {
                "riscv32"
            } else if arch.starts_with("riscv64") {
                "riscv64"
            } else {
                arch
            };
            // Rust spells the Apple simulator env `sim`, clang spells it `simulator`.
            let rest = match rest.strip_suffix("-sim") {
                Some(base) => format!("{base}-simulator"),
                None => rest.to_string(),
            };
            format!("{}-{}", clang_arch, rest)
        }
        None => target.to_string(),
    }
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
