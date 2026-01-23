use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let zlob_root = manifest_dir.parent().unwrap(); // Go up from rust/ to zlob/

    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".to_string());
    let zig_version = Command::new(&zig)
        .arg("version")
        .output()
        .expect("Failed to find zig. Please install zig or set the ZIG environment variable.");

    if !zig_version.status.success() {
        panic!("Failed to run zig. Please ensure zig is installed and accessible.");
    }

    let target = env::var("TARGET").unwrap();
    let zig_target = rust_target_to_zig(&target);

    let profile = env::var("PROFILE").unwrap();
    let optimize = match profile.as_str() {
        "release" | "bench" => "ReleaseFast",
        _ => "Debug",
    };

    // Build static library using zig build
    let mut cmd = Command::new(&zig);
    cmd.current_dir(zlob_root)
        .arg("build")
        .arg(format!("-Doptimize={}", optimize))
        .arg("-p")
        .arg(out_dir.as_os_str());

    // Only pass target if not native
    if zig_target != "native" {
        cmd.arg(format!("-Dtarget={}", zig_target));
    }

    // print the output of the zig build
    let output = cmd.output().expect("Failed to run zig build");
    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        if !stdout.is_empty() {
            for line in stdout.lines() {
                println!("cargo:warning={}", line);
            }
        }
        if !stderr.is_empty() {
            for line in stderr.lines() {
                println!("cargo:warning={}", line);
            }
        }

        println!("cargo:warning=Command: {:?}", cmd);
        panic!("zig build failed with status: {}", output.status);
    }

    let status = cmd.status().expect("Failed to run zig build");
    if !status.success() {
        panic!(
            "zig build failed with status: {}\nCommand: {:?}",
            status, cmd
        );
    }

    // Link the static library
    println!("cargo:rustc-link-search=native={}/lib", out_dir.display());
    println!("cargo:rustc-link-lib=static=zlob");

    // debug only rebuild information
    println!("cargo:rerun-if-changed=../src/");
    println!("cargo:rerun-if-changed=../build.zig");
    println!("cargo:rerun-if-changed=../include/zlob.h");
}

fn rust_target_to_zig(target: &str) -> &'static str {
    match target {
        // Linux
        "x86_64-unknown-linux-gnu" => "x86_64-linux-gnu",
        "x86_64-unknown-linux-musl" => "x86_64-linux-musl",
        "aarch64-unknown-linux-gnu" => "aarch64-linux-gnu",
        "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
        "i686-unknown-linux-gnu" => "x86-linux-gnu",
        "armv7-unknown-linux-gnueabihf" => "arm-linux-gnueabihf",

        // macOS
        "x86_64-apple-darwin" => "x86_64-macos",
        "aarch64-apple-darwin" => "aarch64-macos",

        // Windows
        "x86_64-pc-windows-gnu" => "x86_64-windows-gnu",
        "x86_64-pc-windows-msvc" => "x86_64-windows-msvc",
        "i686-pc-windows-gnu" => "x86-windows-gnu",
        "i686-pc-windows-msvc" => "x86-windows-msvc",
        "aarch64-pc-windows-msvc" => "aarch64-windows-msvc",

        // FreeBSD
        "x86_64-unknown-freebsd" => "x86_64-freebsd",
        "aarch64-unknown-freebsd" => "aarch64-freebsd",

        // Use native for unknown targets
        _ => "native",
    }
}
