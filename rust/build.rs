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

/// Zig release that `build.rs` downloads when no usable `zig` is installed.
/// Keep in sync with `minimum_zig_version` in build.zig.zon.
const ZIG_VERSION: &str = "0.17.1";
const ZIG_MIN_VERSION: (u32, u32, u32) = (0, 17, 1);

/// `(zig host name, archive extension, sha256)` for every official
/// `ZIG_VERSION` build, copied from https://ziglang.org/download/index.json.
/// The checksum is what makes it safe to download from any mirror.
#[rustfmt::skip]
const ZIG_DOWNLOADS: &[(&str, &str, &str)] = &[
    ("x86_64-macos", "tar.xz", "9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7"),
    ("aarch64-macos", "tar.xz", "75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d"),
    ("x86_64-linux", "tar.xz", "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a"),
    ("aarch64-linux", "tar.xz", "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795"),
    ("arm-linux", "tar.xz", "45b5262ef4d4d1e70d21683b2ef4c1b765b067f34a13e2aa57d5f92bb02382a9"),
    ("riscv64-linux", "tar.xz", "b31a3fd8b42b614cb68f93f18aab11c1721336654a9c8dd389ff7bab3a6827dc"),
    ("powerpc64le-linux", "tar.xz", "f06911010b44fa4fdd8e8775669acf499310ff18e209bb392f2eb2428dccc05e"),
    ("x86-linux", "tar.xz", "0855367e096917bb0b628050d994d1871cc8c1f9192542163f9f93b6a30c9c6c"),
    ("loongarch64-linux", "tar.xz", "cc698ceda768c2bd94eb15dfa53496da94bc432f20ac713b60798b9f319cc228"),
    ("s390x-linux", "tar.xz", "e88c93115bdc18f7f37551945cb55ba041a002d2334fd1d6f7424187bec3dee8"),
    ("x86_64-windows", "zip", "b03f477a1943673e02aca0f570e8030dffd536ce1f45cbc4d3326ec31159562e"),
    ("aarch64-windows", "zip", "4789895bdb1e312a2ea73b2a7c0a0cc8d2ab62ba6976e834a7c54cf443377c15"),
    ("x86-windows", "zip", "a93f48164339ecc3c2d8f470d5b5d8ec54895db3aabdd1737c216ddf9284fd8d"),
    ("aarch64-freebsd", "tar.xz", "5ebd395db8996df2bfe1c252b5b6848ec8fad886192cbd88358fbcbf91c91703"),
    ("arm-freebsd", "tar.xz", "a0ec7b932278086cef43a460938f85f7959a44a660aabda30044bbbc0132cb6f"),
    ("powerpc64le-freebsd", "tar.xz", "ba175e24970d9711bf4fbab196914f3d6324a60effca2fde34a68afebbafdfc0"),
    ("riscv64-freebsd", "tar.xz", "b237ebfbe0b276641bf1036c7557dcd72dcfc00493ef3491ea71f455b4989175"),
    ("x86_64-freebsd", "tar.xz", "fd8b9728f05db2a9942fc1f18087c0e0d6dfccb7a51557b06cf026d3e4c78542"),
    ("aarch64-netbsd", "tar.xz", "ddf6ea43b006f4a4766e81e396d53f3f4eb4d5526f137ded797ccf6d597abdef"),
    ("arm-netbsd", "tar.xz", "71aff179be613b47ef690d34784df5885403d5fbe600710686c7eb14faf8b835"),
    ("riscv64-netbsd", "tar.xz", "af5b5ce63e21b9e85a0ed988651ec03c2d039cabbc0f9dd41be1e8594be8c3e6"),
    ("x86-netbsd", "tar.xz", "ecfcbff50565d2510c39295f1f7bccb3b9fb8e147cece317a575226e58b33eef"),
    ("x86_64-netbsd", "tar.xz", "ab96eafda31fab8525f37d5ec66ffab53b40ce542388ac0aaa8924a7df2acb47"),
    ("aarch64-openbsd", "tar.xz", "cb23acb22dc53674d399e0e935568aad94f15055d5e12f8d776f93fb5836d17c"),
    ("arm-openbsd", "tar.xz", "bd4f7b8d33c5a8af7d176e52e4d22157c89442440fbb423d1a9be314c8ce989a"),
    ("riscv64-openbsd", "tar.xz", "00a6b773ed54cc6ef4ebae8fa3f3e398350249e99bbd45c937ceff3a02178b23"),
    ("x86_64-openbsd", "tar.xz", "282bd7041d25c4280d66626461c7e946d5553b5b31719de68aa1b27ddb39ed9f"),
];

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

    let zig = resolve_zig(&host, &out_dir);

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

    let output = cmd
        .output()
        .unwrap_or_else(|e| panic!("Failed to run {}: {e}", zig.display()));
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

/// Find a Zig compiler to build the library with.
///
/// 1. `ZIG` names the compiler explicitly and is used as is.
/// 2. `zig` on `PATH` is used when it is at least `ZIG_MIN_VERSION`.
/// 3. Otherwise the pinned `ZIG_VERSION` is downloaded for the host, checked
///    against its sha256 and unpacked next to the build output.
fn resolve_zig(host: &str, out_dir: &Path) -> PathBuf {
    for var in [
        "ZIG",
        "ZLOB_NO_ZIG_DOWNLOAD",
        "ZLOB_ZIG_MIRROR",
        "ZLOB_ZIG_CACHE_DIR",
        "CARGO_NET_OFFLINE",
    ] {
        println!("cargo:rerun-if-env-changed={var}");
    }

    if let Some(zig) = env::var_os("ZIG").filter(|z| !z.is_empty()) {
        let zig = PathBuf::from(zig);
        if zig_version(&zig).is_none() {
            panic!(
                "ZIG is set to {} but `{} version` did not run.",
                zig.display(),
                zig.display()
            );
        }
        return zig;
    }

    let path_zig = PathBuf::from("zig");
    let found = zig_version(&path_zig);
    let why = match &found {
        Some(version) if parse_zig_version(version) >= Some(ZIG_MIN_VERSION) => return path_zig,
        Some(version) => format!("zig {version} on PATH is older than {ZIG_VERSION}"),
        None => "zig is not installed".to_string(),
    };

    let help = format!(
        "zlob needs Zig {ZIG_VERSION} or newer to compile ({why}).\n\
         Install it from https://ziglang.org/download/ or set ZIG to the compiler path."
    );
    if env_flag("ZLOB_NO_ZIG_DOWNLOAD") || env_flag("CARGO_NET_OFFLINE") {
        panic!(
            "{help}\nThe automatic download is turned off (ZLOB_NO_ZIG_DOWNLOAD / CARGO_NET_OFFLINE)."
        );
    }

    match download_zig(host, out_dir) {
        Ok(zig) => {
            println!(
                "cargo:warning=zlob: {why}, using downloaded Zig {ZIG_VERSION} at {}",
                zig.display()
            );
            zig
        }
        Err(e) => panic!("{help}\nThe automatic download failed: {e}"),
    }
}

fn env_flag(name: &str) -> bool {
    matches!(env::var(name).as_deref(), Ok(v) if !v.is_empty() && v != "0" && v != "false")
}

fn zig_version(zig: &Path) -> Option<String> {
    let output = Command::new(zig).arg("version").output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// `0.17.1` and `0.18.0-dev.123+abcdef` both parse; the suffix is ignored.
fn parse_zig_version(version: &str) -> Option<(u32, u32, u32)> {
    let core = version.split(['-', '+']).next()?;
    let mut parts = core.split('.').map(|p| p.parse::<u32>().ok());
    Some((parts.next()??, parts.next()??, parts.next()??))
}

/// Name Zig uses for the host in its release file names, e.g. `x86_64-linux`.
/// The Linux builds are static, so one build serves glibc and musl hosts.
fn zig_host_name(host: &str) -> Option<String> {
    let arch = match host.split('-').next()? {
        "x86_64" => "x86_64",
        "aarch64" => "aarch64",
        "i686" | "i586" => "x86",
        "armv7" | "arm" => "arm",
        "powerpc64le" => "powerpc64le",
        "loongarch64" => "loongarch64",
        "s390x" => "s390x",
        a if a.starts_with("riscv64") => "riscv64",
        _ => return None,
    };
    let os = ["linux", "windows", "freebsd", "netbsd", "openbsd"]
        .into_iter()
        .find(|os| host.contains(os))
        .or(host.contains("apple-darwin").then_some("macos"))?;
    Some(format!("{arch}-{os}"))
}

fn download_zig(host: &str, out_dir: &Path) -> Result<PathBuf, String> {
    let name = zig_host_name(host).ok_or(format!("no Zig build is known for host {host}"))?;
    let (_, ext, sha256) = ZIG_DOWNLOADS
        .iter()
        .find(|(n, _, _)| *n == name)
        .ok_or(format!(
            "Zig {ZIG_VERSION} has no official build for {name}"
        ))?;

    let cache_dir = env::var_os("ZLOB_ZIG_CACHE_DIR")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| out_dir.join("zig-toolchain"));
    let stem = format!("zig-{name}-{ZIG_VERSION}");
    let install_dir = cache_dir.join(&stem);
    let zig = install_dir.join(if host.contains("windows") {
        "zig.exe"
    } else {
        "zig"
    });
    if zig.exists() {
        return Ok(zig);
    }
    std::fs::create_dir_all(&cache_dir).map_err(|e| format!("{}: {e}", cache_dir.display()))?;

    // Per-process names so parallel builds sharing ZLOB_ZIG_CACHE_DIR never
    // see a half-written archive or tree; the last step is one rename.
    let pid = std::process::id();
    let file = format!("{stem}.{ext}");
    let archive = cache_dir.join(format!("{file}.{pid}.partial"));
    let unpack_dir = cache_dir.join(format!("{stem}.{pid}.unpack"));

    // Zig asks automated builds to use a mirror when they can; any mirror is
    // safe because the archive must match the pinned checksum.
    let mut urls = Vec::new();
    if let Some(mirror) = env::var("ZLOB_ZIG_MIRROR").ok().filter(|m| !m.is_empty()) {
        urls.push(format!(
            "{}/{file}?source=zlob-rust-build",
            mirror.trim_end_matches('/')
        ));
    }
    urls.push(format!("https://ziglang.org/download/{ZIG_VERSION}/{file}"));

    let mut errors = Vec::new();
    let mut downloaded = false;
    for url in &urls {
        match fetch(url, &archive).and_then(|()| verify_sha256(&archive, sha256)) {
            Ok(()) => {
                downloaded = true;
                break;
            }
            Err(e) => errors.push(format!("{url}: {e}")),
        }
    }
    if !downloaded {
        let _ = std::fs::remove_file(&archive);
        return Err(errors.join("; "));
    }

    let _ = std::fs::remove_dir_all(&unpack_dir);
    std::fs::create_dir_all(&unpack_dir).map_err(|e| e.to_string())?;
    // Windows ships bsdtar, which also reads .zip. Name it by full path: under
    // Git Bash a bare `tar` is GNU tar, which does not.
    let tar = match env::var_os("SystemRoot") {
        Some(root) if host.contains("windows") => {
            PathBuf::from(root).join("System32").join("tar.exe")
        }
        _ => PathBuf::from("tar"),
    };
    let status = Command::new(&tar)
        .arg("-xf")
        .arg(&archive)
        .arg("-C")
        .arg(&unpack_dir)
        .status()
        .map_err(|e| format!("cannot run {}: {e}", tar.display()))?;
    let _ = std::fs::remove_file(&archive);
    if !status.success() {
        let _ = std::fs::remove_dir_all(&unpack_dir);
        return Err(format!(
            "{} could not unpack {file} ({status})",
            tar.display()
        ));
    }

    // Losing this rename to another build is fine: its tree is the same.
    let renamed = std::fs::rename(unpack_dir.join(&stem), &install_dir);
    let _ = std::fs::remove_dir_all(&unpack_dir);
    if zig.exists() {
        Ok(zig)
    } else {
        Err(match renamed {
            Err(e) => format!("cannot move Zig into {}: {e}", install_dir.display()),
            Ok(()) => format!("{file} did not contain {stem}/zig"),
        })
    }
}

fn fetch(url: &str, dest: &Path) -> Result<(), String> {
    let status = Command::new("curl")
        .args(["--fail", "--location", "--silent", "--show-error"])
        .args([
            "--proto",
            "=https",
            "--retry",
            "3",
            "--connect-timeout",
            "30",
        ])
        .arg("--output")
        .arg(dest)
        .arg(url)
        .status()
        .map_err(|e| format!("cannot run curl: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("curl failed ({status})"))
    }
}

fn verify_sha256(path: &Path, expected: &str) -> Result<(), String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;

    let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = file.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let actual: String = hasher
        .finalize()
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
