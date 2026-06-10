//! Criterion benchmark: zlob::walk vs walkdir vs the ignore crate.
//!
//! Three synthetic tree sizes (small ~250, medium ~2.5k, large ~25k entries),
//! three workloads:
//!   - walk_plain:     raw traversal, no filtering (vs walkdir)
//!   - walk_gitignore: nested .gitignore + hidden filtering (vs ignore crate)
//!   - walk_metadata:  traversal + size/mtime per entry (vs walkdir + metadata())
//!
//! Throughput is reported in entries/second (of the unfiltered tree size).
//!
//! Run with: cargo bench --bench walk_comparison
//! For real-world numbers on an existing big repo, see examples/walk_bench.rs.

use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};

struct TreeSpec {
    name: &'static str,
    top_dirs: usize,
    files_per_dir: usize,
    subdirs_per_dir: usize,
    files_per_subdir: usize,
}

const TREES: &[TreeSpec] = &[
    TreeSpec {
        name: "small",
        top_dirs: 8,
        files_per_dir: 16,
        subdirs_per_dir: 1,
        files_per_subdir: 8,
    },
    TreeSpec {
        name: "medium",
        top_dirs: 32,
        files_per_dir: 32,
        subdirs_per_dir: 2,
        files_per_subdir: 16,
    },
    TreeSpec {
        name: "large",
        top_dirs: 64,
        files_per_dir: 64,
        subdirs_per_dir: 4,
        files_per_subdir: 64,
    },
];

/// Builds a source-tree-like hierarchy with root + nested .gitignore files
/// and ignorable noise (target/, *.log, *.tmp with a negation).
/// Returns the total number of entries created (excluding the root itself).
fn build_tree(root: &Path, spec: &TreeSpec) -> usize {
    struct B {
        count: usize,
    }
    impl B {
        fn write(&mut self, p: std::path::PathBuf, data: &str) {
            fs::write(p, data).unwrap();
            self.count += 1;
        }
        fn mkdir(&mut self, p: std::path::PathBuf) {
            fs::create_dir(p).unwrap();
            self.count += 1;
        }
    }
    let mut b = B { count: 0 };

    b.write(root.join(".gitignore"), "target/\n*.log\nnode_modules/\n");
    b.mkdir(root.join("target"));
    for i in 0..16 {
        b.write(root.join(format!("target/junk{i}.bin")), "x");
    }

    for d in 0..spec.top_dirs {
        let dir = root.join(format!("dir{d:03}"));
        b.mkdir(dir.clone());
        if d % 2 == 0 {
            b.write(dir.join(".gitignore"), "*.tmp\n!keep.tmp\n");
        }
        for f in 0..spec.files_per_dir {
            b.write(dir.join(format!("file{f:03}.rs")), "fn x() {}");
        }
        b.write(dir.join("scratch.tmp"), "");
        b.write(dir.join("trace.log"), "");
        for s in 0..spec.subdirs_per_dir {
            let sub = dir.join(format!("sub{s}"));
            b.mkdir(sub.clone());
            for f in 0..spec.files_per_subdir {
                b.write(sub.join(format!("inner{f:03}.txt")), "data");
            }
        }
    }
    b.count
}

fn bench_walk(c: &mut Criterion) {
    let trees: Vec<(tempfile::TempDir, &TreeSpec, usize)> = TREES
        .iter()
        .map(|spec| {
            let tmp = tempfile::tempdir().unwrap();
            let n = build_tree(tmp.path(), spec);
            (tmp, spec, n)
        })
        .collect();

    // ---- plain traversal (walkdir replacement) ----
    {
        let mut group = c.benchmark_group("walk_plain");
        group.sample_size(30);
        for (tmp, spec, entries) in &trees {
            let root = tmp.path();
            group.throughput(Throughput::Elements(*entries as u64));

            group.bench_with_input(
                BenchmarkId::new("zlob_serial", spec.name),
                root,
                |b, root| {
                    b.iter(|| {
                        let r = zlob::walk::WalkBuilder::new(root)
                            .git_ignore(false)
                            .hidden(false)
                            .threads(1)
                            .build()
                            .unwrap();
                        std::hint::black_box(r.len())
                    })
                },
            );

            group.bench_with_input(
                BenchmarkId::new("zlob_parallel", spec.name),
                root,
                |b, root| {
                    b.iter(|| {
                        let r = zlob::walk::WalkBuilder::new(root)
                            .git_ignore(false)
                            .hidden(false)
                            .build()
                            .unwrap();
                        std::hint::black_box(r.len())
                    })
                },
            );

            group.bench_with_input(BenchmarkId::new("walkdir", spec.name), root, |b, root| {
                b.iter(|| {
                    let n = walkdir::WalkDir::new(root)
                        .into_iter()
                        .filter_map(Result::ok)
                        .count();
                    std::hint::black_box(n)
                })
            });
        }
        group.finish();
    }

    // ---- gitignore-aware traversal (ignore crate replacement) ----
    {
        let mut group = c.benchmark_group("walk_gitignore");
        group.sample_size(30);
        for (tmp, spec, entries) in &trees {
            let root = tmp.path();
            group.throughput(Throughput::Elements(*entries as u64));

            group.bench_with_input(
                BenchmarkId::new("zlob_serial", spec.name),
                root,
                |b, root| {
                    b.iter(|| {
                        let r = zlob::walk::WalkBuilder::new(root)
                            .threads(1)
                            .build()
                            .unwrap();
                        std::hint::black_box(r.len())
                    })
                },
            );

            group.bench_with_input(
                BenchmarkId::new("zlob_parallel", spec.name),
                root,
                |b, root| {
                    b.iter(|| {
                        let r = zlob::walk::WalkBuilder::new(root).build().unwrap();
                        std::hint::black_box(r.len())
                    })
                },
            );

            group.bench_with_input(
                BenchmarkId::new("ignore_serial", spec.name),
                root,
                |b, root| {
                    b.iter(|| {
                        let n = ignore::WalkBuilder::new(root)
                            .build()
                            .filter_map(Result::ok)
                            .count();
                        std::hint::black_box(n)
                    })
                },
            );

            group.bench_with_input(
                BenchmarkId::new("ignore_parallel", spec.name),
                root,
                |b, root| {
                    b.iter(|| {
                        let count = AtomicUsize::new(0);
                        ignore::WalkBuilder::new(root).build_parallel().run(|| {
                            Box::new(|entry| {
                                if entry.is_ok() {
                                    count.fetch_add(1, Ordering::Relaxed);
                                }
                                ignore::WalkState::Continue
                            })
                        });
                        std::hint::black_box(count.load(Ordering::Relaxed))
                    })
                },
            );
        }
        group.finish();
    }

    // ---- traversal + per-entry metadata (size + mtime) ----
    {
        let mut group = c.benchmark_group("walk_metadata");
        group.sample_size(30);
        for (tmp, spec, entries) in &trees {
            let root = tmp.path();
            group.throughput(Throughput::Elements(*entries as u64));

            group.bench_with_input(
                BenchmarkId::new("zlob_size_mtime", spec.name),
                root,
                |b, root| {
                    b.iter(|| {
                        let r = zlob::walk::WalkBuilder::new(root)
                            .git_ignore(false)
                            .hidden(false)
                            .metadata(zlob::walk::WalkMetadata {
                                size: true,
                                modified: true,
                                ..Default::default()
                            })
                            .build()
                            .unwrap();
                        let total: u64 = r.iter().filter_map(|e| e.size()).sum();
                        std::hint::black_box(total)
                    })
                },
            );

            group.bench_with_input(
                BenchmarkId::new("walkdir_metadata", spec.name),
                root,
                |b, root| {
                    b.iter(|| {
                        let total: u64 = walkdir::WalkDir::new(root)
                            .into_iter()
                            .filter_map(Result::ok)
                            .filter_map(|e| e.metadata().ok())
                            .map(|m| m.len())
                            .sum();
                        std::hint::black_box(total)
                    })
                },
            );
        }
        group.finish();
    }
}

criterion_group!(benches, bench_walk);
criterion_main!(benches);
