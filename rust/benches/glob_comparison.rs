//! Criterion benchmarks comparing zlob against the `glob` and `globset` crates,
//! exercised against a real-world large source tree (e.g. a Linux kernel
//! checkout) supplied via the `BIG_REPO` env var.
//!
//! Two benchmark groups are exercised:
//!
//! 1. `fs_walk` - resolve a glob pattern against a real filesystem tree.
//!    - zlob:    `zlob_at(repo, pattern, RECOMMENDED)`
//!    - glob:    `glob::glob(pattern)` (crate has no `at()` so we chdir during the bench)
//!    - globset: `walkdir + globset::GlobSet::is_match`
//!
//! 2. `path_match` - filter the in-memory list of every path in the repo.
//!    - zlob:    `zlob_match_paths(pattern, &paths, ...)`
//!    - glob:    `glob::Pattern::matches` over the slice
//!    - globset: `globset::GlobMatcher::is_match` over the slice
//!
//! Patterns are taken from `bench/profile_big_repo.zig` and represent
//! realistic globs run on a Linux kernel tree.
//!
//! Configuration:
//!   BIG_REPO=/path/to/repo cargo bench --bench glob_comparison
//!
//! NOTE on parity:
//!   - The `glob` crate does **not** support `{a,b}` brace expansion. Any
//!     pattern containing braces is automatically skipped for the `glob`
//!     bencher and run only for zlob/globset.
//!   - For globset we set `literal_separator(true)` so `*` does not cross
//!     `/`, which matches what zlob and `glob` do.

use std::env;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};

use zlob::{zlob_at, zlob_match_paths, ZlobFlags};

fn repo_path() -> &'static Path {
    static REPO: OnceLock<PathBuf> = OnceLock::new();
    REPO.get_or_init(|| {
        let p = env::var_os("REPO").map(PathBuf::from).expect(
            "REPO env var is required (set REPO=/path/to/large/source/tree, \
             e.g. a Linux kernel checkout)",
        );
        if !p.is_dir() {
            panic!(
                "Benchmark repository not found at {} \
                 (set REPO=/path/to/repo). \
                 The benchmark expects a large source tree (e.g. a Linux kernel checkout).",
                p.display()
            );
        }
        p
    })
    .as_path()
}

/// Snapshot of every regular file in the repo, as paths relative to repo root.
/// Built once via `walkdir`. Used by the `path_match` group.
fn path_corpus() -> &'static [String] {
    static CORPUS: OnceLock<Vec<String>> = OnceLock::new();
    CORPUS
        .get_or_init(|| {
            let root = repo_path();
            let mut paths: Vec<String> = walkdir::WalkDir::new(root)
                .into_iter()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_type().is_file())
                .filter_map(|e| {
                    e.path()
                        .strip_prefix(root)
                        .ok()
                        .and_then(|p| p.to_str().map(|s| s.to_string()))
                })
                .collect();
            paths.shrink_to_fit();
            eprintln!(
                "[bench] loaded {} paths from {}",
                paths.len(),
                root.display()
            );
            paths
        })
        .as_slice()
}

struct PatternSpec {
    label: &'static str,
    pattern: &'static str,
    supports_brace: bool,
    /// FS-walk sample count; smaller for the heavy ones.
    fs_samples: usize,
}

const PATTERNS: &[PatternSpec] = &[
    PatternSpec {
        label: "fs_star_c", // fs/*.c            ~71 matches
        pattern: "fs/*.c",
        supports_brace: false,
        fs_samples: 100,
    },
    PatternSpec {
        label: "top_makefile", // */Makefile        top-level makefiles
        pattern: "*/Makefile",
        supports_brace: false,
        fs_samples: 100,
    },
    PatternSpec {
        label: "bracket_star_c", // [fk]*/*.c
        pattern: "[fk]*/*.c",
        supports_brace: false,
        fs_samples: 60,
    },
    PatternSpec {
        label: "drivers_star_c", // drivers/*/*.c
        pattern: "drivers/*/*.c",
        supports_brace: false,
        fs_samples: 40,
    },
    PatternSpec {
        label: "drivers_recursive_c",  // drivers/**/*.c   STRESS: 20k+ matches (symlink-free)
        pattern: "drivers/**/*.c",
        supports_brace: false,
        fs_samples: 15,
    },
    PatternSpec {
        label: "net_recursive_c",      // net/**/*.c       symlink-free recursive subtree
        pattern: "net/**/*.c",
        supports_brace: false,
        fs_samples: 30,
    },
    PatternSpec {
        label: "net_brace_c_h",        // net/**/*.{c,h}   symlink-free recursive + brace
        pattern: "net/**/*.{c,h}",
        supports_brace: true,
        fs_samples: 30,
    },
    PatternSpec {
        label: "all_recursive_c",      // **/*.c           full tree - WARNING: hits symlink loops in `glob` crate
        pattern: "**/*.c",
        supports_brace: false,
        fs_samples: 10,
    },
];

// ---------------------------------------------------------------------------
// Filesystem walking
// ---------------------------------------------------------------------------

fn bench_fs_walk(c: &mut Criterion) {
    let root = repo_path();
    let original_cwd = env::current_dir().ok();

    let mut group = c.benchmark_group("fs_walk");

    for spec in PATTERNS {
        group.sample_size(spec.fs_samples.max(10));

        // ----- zlob -----
        group.bench_with_input(BenchmarkId::new("zlob", spec.label), spec, |b, spec| {
            b.iter(|| {
                let r = zlob_at(root.to_str().unwrap(), spec.pattern, ZlobFlags::RECOMMENDED)
                    .expect("zlob_at");
                black_box(r.as_ref().map(|m| m.len()).unwrap_or(0))
            });
        });

        // ----- glob crate (skip if pattern uses braces) -----
        if !spec.supports_brace {
            group.bench_with_input(BenchmarkId::new("glob", spec.label), spec, |b, spec| {
                env::set_current_dir(root).expect("chdir");
                b.iter(|| {
                    let mut count = 0usize;
                    for entry in glob::glob(spec.pattern).expect("glob compile") {
                        if entry.is_ok() {
                            count += 1;
                        }
                    }
                    black_box(count)
                });
                if let Some(cwd) = &original_cwd {
                    let _ = env::set_current_dir(cwd);
                }
            });
        }

        // ----- globset + walkdir -----
        group.bench_with_input(
            BenchmarkId::new("globset_walkdir", spec.label),
            spec,
            |b, spec| {
                let glob = globset::GlobBuilder::new(spec.pattern)
                    .literal_separator(true)
                    .build()
                    .expect("globset compile")
                    .compile_matcher();
                b.iter(|| {
                    let mut count = 0usize;
                    for entry in walkdir::WalkDir::new(root)
                        .into_iter()
                        .filter_map(|e| e.ok())
                    {
                        let rel = entry
                            .path()
                            .strip_prefix(root)
                            .unwrap_or_else(|_| entry.path());
                        if glob.is_match(rel) {
                            count += 1;
                        }
                    }
                    black_box(count)
                });
            },
        );
    }

    group.finish();
}

// ---------------------------------------------------------------------------
// In-memory path matching against the full kernel tree
// ---------------------------------------------------------------------------

fn bench_path_match(c: &mut Criterion) {
    let owned = path_corpus();
    let path_refs: Vec<&str> = owned.iter().map(|s| s.as_str()).collect();
    let path_pathbufs: Vec<PathBuf> = owned.iter().map(PathBuf::from).collect();

    let mut group = c.benchmark_group("path_match");
    group.throughput(Throughput::Elements(path_refs.len() as u64));

    for spec in PATTERNS {
        // ----- zlob -----
        group.bench_with_input(BenchmarkId::new("zlob", spec.label), spec, |b, spec| {
            b.iter(|| {
                let m =
                    zlob_match_paths(spec.pattern, black_box(&path_refs), ZlobFlags::RECOMMENDED)
                        .expect("zlob_match_paths");
                black_box(m.as_ref().map(|x| x.len()).unwrap_or(0))
            });
        });

        // ----- glob crate (Pattern::matches) - skip brace patterns -----
        if !spec.supports_brace {
            group.bench_with_input(BenchmarkId::new("glob", spec.label), spec, |b, spec| {
                let compiled = glob::Pattern::new(spec.pattern).expect("glob pattern compile");
                b.iter(|| {
                    let mut count = 0usize;
                    for p in black_box(&path_refs) {
                        if compiled.matches(p) {
                            count += 1;
                        }
                    }
                    black_box(count)
                });
            });
        }

        // ----- globset -----
        group.bench_with_input(BenchmarkId::new("globset", spec.label), spec, |b, spec| {
            let matcher = globset::GlobBuilder::new(spec.pattern)
                .literal_separator(true)
                .build()
                .expect("globset compile")
                .compile_matcher();
            b.iter(|| {
                let mut count = 0usize;
                for p in black_box(&path_pathbufs) {
                    if matcher.is_match(p) {
                        count += 1;
                    }
                }
                black_box(count)
            });
        });
    }

    group.finish();
}

// ---------------------------------------------------------------------------
// Parity check: print match counts once before benching to expose any
// disagreement between the libraries.
// ---------------------------------------------------------------------------

fn print_parity(c: &mut Criterion) {
    let _ = c; // unused
    let root = repo_path();
    let owned = path_corpus();
    let path_refs: Vec<&str> = owned.iter().map(|s| s.as_str()).collect();
    let path_pathbufs: Vec<PathBuf> = owned.iter().map(PathBuf::from).collect();

    eprintln!("\n[bench] match-count parity (FS walk / path-match):");
    eprintln!(
        "{:<22} {:>10} {:>10} {:>10} | {:>10} {:>10} {:>10}",
        "pattern", "zlob/fs", "glob/fs", "gset/fs", "zlob/p", "glob/p", "gset/p"
    );

    let original_cwd = env::current_dir().ok();

    for spec in PATTERNS {
        // FS walk counts
        let zlob_fs = zlob_at(root.to_str().unwrap(), spec.pattern, ZlobFlags::RECOMMENDED)
            .ok()
            .flatten()
            .map(|m| m.len())
            .unwrap_or(0);

        let glob_fs = if spec.supports_brace {
            None
        } else {
            env::set_current_dir(root).ok();
            let n = glob::glob(spec.pattern)
                .map(|it| it.filter_map(|e| e.ok()).count())
                .unwrap_or(0);
            if let Some(cwd) = &original_cwd {
                let _ = env::set_current_dir(cwd);
            }
            Some(n)
        };

        let gset_fs = {
            let g = globset::GlobBuilder::new(spec.pattern)
                .literal_separator(true)
                .build()
                .unwrap()
                .compile_matcher();
            walkdir::WalkDir::new(root)
                .into_iter()
                .filter_map(|e| e.ok())
                .filter(|e| {
                    let rel = e.path().strip_prefix(root).unwrap_or_else(|_| e.path());
                    g.is_match(rel)
                })
                .count()
        };

        // Path-match counts
        let zlob_p = zlob_match_paths(spec.pattern, &path_refs, ZlobFlags::RECOMMENDED)
            .ok()
            .flatten()
            .map(|m| m.len())
            .unwrap_or(0);

        let glob_p = if spec.supports_brace {
            None
        } else {
            let p = glob::Pattern::new(spec.pattern).unwrap();
            Some(path_refs.iter().filter(|s| p.matches(s)).count())
        };

        let gset_p = {
            let m = globset::GlobBuilder::new(spec.pattern)
                .literal_separator(true)
                .build()
                .unwrap()
                .compile_matcher();
            path_pathbufs.iter().filter(|p| m.is_match(p)).count()
        };

        eprintln!(
            "{:<22} {:>10} {:>10} {:>10} | {:>10} {:>10} {:>10}",
            spec.label,
            zlob_fs,
            glob_fs.map(|n| n.to_string()).unwrap_or_else(|| "-".into()),
            gset_fs,
            zlob_p,
            glob_p.map(|n| n.to_string()).unwrap_or_else(|| "-".into()),
            gset_p
        );
    }
    eprintln!();
}

fn parity_first(c: &mut Criterion) {
    static ONCE: OnceLock<()> = OnceLock::new();
    ONCE.get_or_init(|| print_parity(c));
}

fn all_benches(c: &mut Criterion) {
    parity_first(c);
    bench_fs_walk(c);
    bench_path_match(c);
}

criterion_group!(benches, all_benches);
criterion_main!(benches);
