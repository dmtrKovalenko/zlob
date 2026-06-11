//! End-to-end walker parity test against real repositories.
//!
//! Shallow-clones 10 popular Rust repos, injects a pile of trash into their
//! gitignored `target/` directories, then walks each repo with:
//!   - zlob plain      vs walkdir          (must agree exactly)
//!   - zlob gitignore  vs the ignore crate (must agree exactly)
//!
//! and verifies none of the injected trash leaks through gitignore filtering.
//!
//! Network-bound (git clone), so it is #[ignore]d by default. Run with:
//!   cargo test --release --test walk_e2e_repos -- --ignored --nocapture
//!
//! Clones are cached in $TMPDIR/zlob_e2e_repos and reused across runs.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const REPOS: &[(&str, &str)] = &[
    ("fff", "https://github.com/dmtrKovalenko/fff.nvim"),
    ("ripgrep", "https://github.com/BurntSushi/ripgrep"),
    ("fd", "https://github.com/sharkdp/fd"),
    ("bat", "https://github.com/sharkdp/bat"),
    ("starship", "https://github.com/starship/starship"),
    ("clap", "https://github.com/clap-rs/clap"),
    ("serde", "https://github.com/serde-rs/serde"),
    ("tokio", "https://github.com/tokio-rs/tokio"),
    ("regex", "https://github.com/rust-lang/regex"),
    ("walkdir", "https://github.com/BurntSushi/walkdir"),
];

fn cache_dir() -> PathBuf {
    std::env::temp_dir().join("zlob_e2e_repos")
}

fn clone_repo(name: &str, url: &str) -> PathBuf {
    let dest = cache_dir().join(name);
    if dest.join(".git").exists() {
        return dest;
    }
    fs::create_dir_all(cache_dir()).unwrap();
    let status = Command::new("git")
        .args(["clone", "--depth", "1", "--quiet", url])
        .arg(&dest)
        .status()
        .expect("failed to spawn git");
    assert!(status.success(), "git clone failed for {url}");
    dest
}

/// Fills `<repo>/target/` with build-artifact-looking trash. `target/` is
/// gitignored in every Rust repo, so a correct walker must skip all of it.
fn add_trash(root: &Path) -> usize {
    let target = root.join("target");
    let mut created = 0;
    let mut write = |p: PathBuf| {
        if !p.exists() {
            fs::write(p, "trash").unwrap();
        }
        created += 1;
    };

    for profile in ["debug", "release"] {
        let deps = target.join(profile).join("deps");
        let fingerprint = target.join(profile).join(".fingerprint").join("zlob-e2e");
        let build = target
            .join(profile)
            .join("build")
            .join("zlob-e2e")
            .join("out");
        fs::create_dir_all(&deps).unwrap();
        fs::create_dir_all(&fingerprint).unwrap();
        fs::create_dir_all(&build).unwrap();

        for i in 0..150 {
            write(deps.join(format!("libjunk_{i:03}.rlib")));
            write(deps.join(format!("junk_{i:03}.d")));
        }
        for i in 0..20 {
            write(fingerprint.join(format!("dep-lib-junk-{i}")));
            write(build.join(format!("artifact_{i}.o")));
        }
    }
    write(target.join("CACHEDIR.TAG"));
    created
}

fn count_walkdir(root: &Path) -> usize {
    walkdir::WalkDir::new(root)
        .into_iter()
        .filter_map(Result::ok)
        .count()
        - 1 // walkdir yields the root itself; zlob does not
}

/// ignore crate configured to the exact feature set zlob implements:
/// hidden filtering + (nested) .gitignore files. Global gitignore,
/// .git/info/exclude, .ignore files and parent-directory discovery are
/// disabled on both sides.
fn count_ignore_crate(root: &Path) -> usize {
    ignore::WalkBuilder::new(root)
        .standard_filters(false)
        .hidden(true)
        .git_ignore(true)
        .build()
        .filter_map(Result::ok)
        .count()
        - 1
}

#[test]
#[ignore = "network-bound: shallow-clones 10 repos (cached in $TMPDIR/zlob_e2e_repos)"]
fn walker_parity_on_popular_repos() {
    let mut failures = Vec::new();

    for (name, url) in REPOS {
        let root = clone_repo(name, url);
        let trash = add_trash(&root);

        // 1. Plain traversal must agree with walkdir entry-for-entry count.
        let zlob_plain = zlob::walk::WalkBuilder::new(&root)
            .git_ignore(false)
            .hidden(false)
            .build()
            .unwrap()
            .len();
        let walkdir_n = count_walkdir(&root);

        // 2. Gitignore traversal must agree with the ignore crate.
        let zlob_git = zlob::walk::WalkBuilder::new(&root).build().unwrap();
        let ignore_n = count_ignore_crate(&root);

        // 3. None of the injected target/ trash may leak through.
        let leaked = zlob_git
            .iter()
            .filter(|e| e.rel_path().starts_with("target"))
            .count();

        let ok = zlob_plain == walkdir_n && zlob_git.len() == ignore_n && leaked == 0;
        println!(
            "{:>10}: plain zlob={zlob_plain} walkdir={walkdir_n} | gitignore zlob={} ignore={ignore_n} | trash added={trash} leaked={leaked} {}",
            name,
            zlob_git.len(),
            if ok { "OK" } else { "MISMATCH" },
        );

        if !ok {
            // Dump the symmetric difference on gitignore walks to make
            // divergence debugging trivial.
            if zlob_git.len() != ignore_n {
                use std::collections::HashSet;
                let zlob_set: HashSet<String> = zlob_git
                    .iter()
                    .map(|e| e.rel_path().to_string_lossy().into_owned())
                    .collect();
                let ignore_set: HashSet<String> = ignore::WalkBuilder::new(&root)
                    .standard_filters(false)
                    .hidden(true)
                    .git_ignore(true)
                    .build()
                    .filter_map(Result::ok)
                    .filter(|e| e.depth() > 0)
                    .map(|e| {
                        e.path()
                            .strip_prefix(&root)
                            .unwrap()
                            .to_string_lossy()
                            .into_owned()
                    })
                    .collect();
                for p in zlob_set.difference(&ignore_set).take(20) {
                    println!("    only in zlob:   {p}");
                }
                for p in ignore_set.difference(&zlob_set).take(20) {
                    println!("    only in ignore: {p}");
                }
            }
            failures.push(*name);
        }
    }

    assert!(failures.is_empty(), "walker mismatch on: {failures:?}");
}
