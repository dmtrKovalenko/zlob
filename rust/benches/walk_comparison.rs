use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use std::fs;
use std::path::Path;
use std::sync::atomic::Ordering;
use zlob::walk::{WalkBuilder, WalkFlags, WalkMetadata, WalkState};

struct TreeSpec {
    name: &'static str,
    top_dirs: usize,
    files_per_dir: usize,
    subdirs_per_dir: usize,
    files_per_subdir: usize,
    ignored_subdirs_per_top: usize,
    ignored_files_per_subdir: usize,
}

const TREES: &[TreeSpec] = &[
    // ~1,002 total ~416 kept
    TreeSpec {
        name: "small",
        top_dirs: 16,
        files_per_dir: 16,
        subdirs_per_dir: 1,
        files_per_subdir: 8,
        ignored_subdirs_per_top: 1,
        ignored_files_per_subdir: 31,
    },
    // ~8,034 total, ~2,144 kept
    TreeSpec {
        name: "medium",
        top_dirs: 32,
        files_per_dir: 32,
        subdirs_per_dir: 2,
        files_per_subdir: 16,
        ignored_subdirs_per_top: 4,
        ignored_files_per_subdir: 44,
    },
    // ~136,498 total, ~70,720 kept
    TreeSpec {
        name: "large",
        top_dirs: 64,
        files_per_dir: 64,
        subdirs_per_dir: 16,
        files_per_subdir: 64,
        ignored_subdirs_per_top: 4,
        ignored_files_per_subdir: 255,
    },
];

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
    // A real (empty) git repo. zlob skips `.git` unconditionally and the
    // `ignore` crate needs it present to activate .gitignore handling, so it
    // does not change the comparable entry set. Created directly with fs (not
    // through `b`) so it is excluded from the expected count, matching both
    // walkers' view (.git is skipped by zlob and by ignore).
    fs::create_dir(root.join(".git")).unwrap();
    fs::write(root.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();

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
        // Ignored `node_modules/` subtree: created on disk (so the plain walks
        // see every file) but matched by the root `node_modules/` rule, so the
        // gitignore-aware walks prune it without opening it. `node_modules`
        // holds `ignored_subdirs_per_top` package dirs, each with
        // `ignored_files_per_subdir` files — the build-artifact bulk that
        // dominates a real working tree.
        if spec.ignored_subdirs_per_top > 0 {
            let nm = dir.join("node_modules");
            b.mkdir(nm.clone());
            for p in 0..spec.ignored_subdirs_per_top {
                let pkg = nm.join(format!("pkg{p:03}"));
                b.mkdir(pkg.clone());
                for f in 0..spec.ignored_files_per_subdir {
                    b.write(pkg.join(format!("m{f:04}.js")), "module.exports={}");
                }
            }
        }
    }
    b.count
}

fn consume_path(path: &[u8]) -> u64 {
    let mut h: u64 = path.len() as u64;
    for &b in path {
        h = h.wrapping_add(b as u64);
    }
    std::hint::black_box(h)
}

// --- zlob: streaming walks (no result allocation), matches walkdir/ignore ---

fn zlob_run_serial(root: &Path, gitignore: bool) -> u64 {
    // `run_serial` takes a plain `FnMut` with no `Sync` bound (the API mirrors
    // walkdir's serial iterator), so the accumulator is just a local — no
    // atomics, no synchronization taxing the single-threaded numbers.
    let mut acc: u64 = 0;
    let mut b = WalkBuilder::new(root);
    b.options(if gitignore {
        WalkFlags::RECOMMENDED
    } else {
        WalkFlags::empty()
    });
    b.run_serial(|e| {
        acc = acc.wrapping_add(consume_path(e.path_bytes()));
        WalkState::Continue
    })
    .unwrap();
    acc
}

fn zlob_run_parallel(root: &Path, gitignore: bool) -> u64 {
    // Parallel `run`: the visitor is `Sync` and called from worker threads, so
    // the shared accumulator is atomic (the same shape ignore_parallel uses).
    use std::sync::atomic::AtomicU64;
    let acc = AtomicU64::new(0);
    let mut b = WalkBuilder::new(root);
    b.options(if gitignore {
        WalkFlags::RECOMMENDED
    } else {
        WalkFlags::empty()
    });
    b.run(|e| {
        acc.fetch_add(consume_path(e.path_bytes()), Ordering::Relaxed);
        WalkState::Continue
    })
    .unwrap();
    acc.load(Ordering::Relaxed)
}

fn zlob_collect_parallel(root: &Path, gitignore: bool) -> u64 {
    let mut b = WalkBuilder::new(root);
    b.options(if gitignore {
        WalkFlags::RECOMMENDED
    } else {
        WalkFlags::empty()
    });
    let results = b.build().unwrap();
    results.iter().map(|e| consume_path(e.path_bytes())).sum()
}

fn walkdir_plain(root: &Path) -> u64 {
    walkdir::WalkDir::new(root)
        .into_iter()
        .filter_map(Result::ok)
        // walkdir yields the root itself; skip it for parity.
        .filter(|e| e.depth() > 0)
        .map(|e| consume_path(e.path().as_os_str().as_encoded_bytes()))
        .sum()
}

fn ignore_builder(root: &Path, gitignore: bool, hidden: bool) -> ignore::WalkBuilder {
    let mut b = ignore::WalkBuilder::new(root);
    b.hidden(hidden)
        .git_ignore(gitignore)
        .git_global(false)
        .git_exclude(false)
        .ignore(gitignore)
        .parents(false);
    b
}

fn ignore_serial(b: &ignore::WalkBuilder) -> u64 {
    b.build()
        .filter_map(Result::ok)
        .filter(|e| e.depth() > 0)
        .map(|e| consume_path(e.path().as_os_str().as_encoded_bytes()))
        .sum()
}

fn ignore_parallel(b: &ignore::WalkBuilder) -> u64 {
    use std::sync::atomic::AtomicU64;
    let acc = AtomicU64::new(0);
    b.build_parallel().run(|| {
        Box::new(|entry| {
            if let Ok(e) = entry {
                if e.depth() > 0 {
                    let v = consume_path(e.path().as_os_str().as_encoded_bytes());
                    acc.fetch_add(v, Ordering::Relaxed);
                }
            }
            ignore::WalkState::Continue
        })
    });
    acc.load(Ordering::Relaxed)
}

fn zlob_count(root: &Path, gitignore: bool) -> usize {
    let mut b = zlob::walk::WalkBuilder::new(root);
    b.options(if gitignore {
        WalkFlags::RECOMMENDED
    } else {
        WalkFlags::empty()
    });
    b.build().unwrap().len()
}

fn ignore_count(b: &ignore::WalkBuilder) -> usize {
    b.build()
        .filter_map(Result::ok)
        .filter(|e| e.depth() > 0)
        .count()
}

/// Fails the bench loudly if the libraries don't agree on what they're
/// counting — otherwise the throughput numbers would compare different amounts
/// of work. (Parity is about the visited *set*; the per-entry reducer values
/// can legitimately differ since the libraries report slightly different path
/// strings, e.g. with/without a leading "./".)
fn assert_parity(root: &Path) {
    let zp = zlob_count(root, false);
    let wp = walkdir::WalkDir::new(root)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.depth() > 0)
        .count();
    assert_eq!(
        zp, wp,
        "plain entry-count mismatch: zlob={zp} walkdir={wp} (comparison would be unfair)"
    );

    let zg = zlob_count(root, true);
    let plain_ig = ignore_builder(root, false, false);
    let gi_ig = ignore_builder(root, true, true);
    let is = ignore_count(&gi_ig);
    assert_eq!(
        ignore_count(&plain_ig),
        wp,
        "plain ignore count != walkdir count"
    );
    assert_eq!(
        zg, is,
        "gitignore entry-count mismatch: zlob={zg} ignore={is}"
    );
}

fn bench_walk(c: &mut Criterion) {
    let trees: Vec<(tempfile::TempDir, &TreeSpec, usize)> = TREES
        .iter()
        .map(|spec| {
            let tmp = tempfile::tempdir().unwrap();
            let n = build_tree(tmp.path(), spec);
            assert_parity(tmp.path());
            (tmp, spec, n)
        })
        .collect();

    fn walkdir_meta(root: &Path) -> u64 {
        walkdir::WalkDir::new(root)
            .into_iter()
            .filter_map(Result::ok)
            .filter_map(|e| e.metadata().ok())
            .map(|m| m.len())
            .sum()
    }

    fn zlob_meta(root: &Path, parallel: bool, gitignore: bool) -> u64 {
        // Streaming walk so it matches walkdir's iterator and ignore's
        // per-entry callback: each entry's size is summed as it is visited,
        // nothing is materialized. Serial uses `run_serial` (plain local,
        // no atomics); parallel uses `run` (atomic shared accumulator).
        let mut b = WalkBuilder::new(root);
        b.options(if gitignore {
            WalkFlags::RECOMMENDED
        } else {
            WalkFlags::empty()
        });
        b.metadata(WalkMetadata::SIZE | WalkMetadata::MTIME | WalkMetadata::INODE);
        if parallel {
            use std::sync::atomic::AtomicU64;
            let acc = AtomicU64::new(0);
            b.run(|e| {
                acc.fetch_add(e.size().unwrap_or(0), Ordering::Relaxed);
                WalkState::Continue
            })
            .unwrap();
            acc.load(Ordering::Relaxed)
        } else {
            let mut acc: u64 = 0;
            b.run_serial(|e| {
                acc = acc.wrapping_add(e.size().unwrap_or(0));
                WalkState::Continue
            })
            .unwrap();
            acc
        }
    }

    fn ignore_meta_parallel(root: &Path, gitignore: bool) -> u64 {
        use std::sync::atomic::AtomicU64;
        let total = AtomicU64::new(0);
        ignore_builder(root, gitignore, gitignore)
            .build_parallel()
            .run(|| {
                Box::new(|entry| {
                    if let Ok(e) = entry {
                        if let Ok(m) = e.metadata() {
                            total.fetch_add(m.len(), Ordering::Relaxed);
                        }
                    }
                    ignore::WalkState::Continue
                })
            });
        total.load(Ordering::Relaxed)
    }

    for (tmp, spec, entries) in &trees {
        let root = tmp.path();
        let mut group = c.benchmark_group(spec.name);
        group.sample_size(30);
        group.throughput(Throughput::Elements(*entries as u64));

        // plain
        group.bench_with_input(BenchmarkId::from_parameter("zlob_serial"), root, |b, r| {
            b.iter(|| std::hint::black_box(zlob_run_serial(r, false)))
        });
        group.bench_with_input(
            BenchmarkId::from_parameter("zlob_parallel"),
            root,
            |b, r| b.iter(|| std::hint::black_box(zlob_run_parallel(r, false))),
        );
        group.bench_with_input(
            BenchmarkId::from_parameter("zlob_collect_parallel"),
            root,
            |b, r| b.iter(|| std::hint::black_box(zlob_collect_parallel(r, false))),
        );
        group.bench_with_input(BenchmarkId::from_parameter("walkdir"), root, |b, r| {
            b.iter(|| std::hint::black_box(walkdir_plain(r)))
        });
        group.bench_with_input(
            BenchmarkId::from_parameter("walkdir_parallel"),
            root,
            |b, r| {
                let builder = ignore_builder(r, false, false);
                b.iter(|| std::hint::black_box(ignore_parallel(&builder)))
            },
        );

        // with gitignore
        group.bench_with_input(
            BenchmarkId::from_parameter("zlob_gitignore_serial"),
            root,
            |b, r| b.iter(|| std::hint::black_box(zlob_run_serial(r, true))),
        );
        group.bench_with_input(
            BenchmarkId::from_parameter("zlob_gitignore_parallel"),
            root,
            |b, r| b.iter(|| std::hint::black_box(zlob_run_parallel(r, true))),
        );
        group.bench_with_input(
            BenchmarkId::from_parameter("zlob_gitignore_collect_parallel"),
            root,
            |b, r| b.iter(|| std::hint::black_box(zlob_collect_parallel(r, true))),
        );
        group.bench_with_input(
            BenchmarkId::from_parameter("ignore_serial"),
            root,
            |b, r| {
                let builder = ignore_builder(r, true, true);
                b.iter(|| std::hint::black_box(ignore_serial(&builder)))
            },
        );
        group.bench_with_input(
            BenchmarkId::from_parameter("ignore_parallel"),
            root,
            |b, r| {
                let builder = ignore_builder(r, true, true);
                b.iter(|| std::hint::black_box(ignore_parallel(&builder)))
            },
        );

        // with metadata
        group.bench_with_input(
            BenchmarkId::from_parameter("zlob_meta_serial"),
            root,
            |b, r| b.iter(|| std::hint::black_box(zlob_meta(r, false, false))),
        );
        group.bench_with_input(
            BenchmarkId::from_parameter("zlob_meta_parallel"),
            root,
            |b, r| b.iter(|| std::hint::black_box(zlob_meta(r, true, false))),
        );
        group.bench_with_input(BenchmarkId::from_parameter("walkdir_meta"), root, |b, r| {
            b.iter(|| std::hint::black_box(walkdir_meta(r)))
        });
        group.bench_with_input(
            BenchmarkId::from_parameter("ignore_meta_parallel"),
            root,
            |b, r| b.iter(|| std::hint::black_box(ignore_meta_parallel(r, false))),
        );

        // gitignore + metadata
        group.bench_with_input(
            BenchmarkId::from_parameter("zlob_meta_gitignore_serial"),
            root,
            |b, r| b.iter(|| std::hint::black_box(zlob_meta(r, false, true))),
        );
        group.bench_with_input(
            BenchmarkId::from_parameter("zlob_meta_gitignore_parallel"),
            root,
            |b, r| b.iter(|| std::hint::black_box(zlob_meta(r, true, true))),
        );
        group.bench_with_input(
            BenchmarkId::from_parameter("ignore_meta_gitignore_parallel"),
            root,
            |b, r| b.iter(|| std::hint::black_box(ignore_meta_parallel(r, true))),
        );

        group.finish();
    }
}

criterion_group!(benches, bench_walk);
criterion_main!(benches);
