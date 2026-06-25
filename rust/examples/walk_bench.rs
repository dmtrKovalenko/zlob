//! Quick wall-clock comparison on a real directory tree.
//! Usage: cargo run --release --example walk_bench -- <path> [iters]

use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

fn timeit<F: FnMut() -> usize>(name: &str, iters: usize, mut f: F) {
    // warmup
    let n = f();
    let mut best = f64::MAX;
    for _ in 0..iters {
        let t = Instant::now();
        let r = f();
        let el = t.elapsed().as_secs_f64() * 1000.0;
        assert_eq!(r, n);
        if el < best {
            best = el;
        }
    }
    println!("{name:38} {best:9.2} ms  ({n} entries)");
}

fn main() {
    let root = std::env::args().nth(1).unwrap_or_else(|| ".".to_string());
    let iters: usize = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(5);

    println!("tree: {root}\n");

    timeit("zlob plain serial", iters, || {
        zlob::walk::WalkBuilder::new(&root)
            .git_ignore(false)
            .hidden(false)
            .threads(1)
            .build()
            .unwrap()
            .len()
    });

    timeit("zlob plain parallel (.build)", iters, || {
        zlob::walk::WalkBuilder::new(&root)
            .git_ignore(false)
            .hidden(false)
            .build()
            .unwrap()
            .len()
    });

    timeit("zlob plain parallel (.run)", iters, || {
        let count = AtomicUsize::new(0);
        zlob::walk::WalkBuilder::new(&root)
            .git_ignore(false)
            .hidden(false)
            .run(|_| {
                count.fetch_add(1, Ordering::Relaxed);
                zlob::walk::WalkState::Continue
            })
            .unwrap();
        count.load(Ordering::Relaxed)
    });

    timeit("walkdir", iters, || {
        walkdir::WalkDir::new(&root)
            .into_iter()
            .filter_map(Result::ok)
            .count()
            - 1 // walkdir yields the root itself
    });

    println!();

    timeit("zlob gitignore serial", iters, || {
        let count = AtomicUsize::new(0);
        zlob::walk::WalkBuilder::new(&root)
            .threads(1)
            .run(|_| {
                count.fetch_add(1, Ordering::Relaxed);
                zlob::walk::WalkState::Continue
            })
            .unwrap();
        count.load(Ordering::Relaxed)
    });

    timeit("zlob gitignore parallel (.run)", iters, || {
        let count = AtomicUsize::new(0);
        zlob::walk::WalkBuilder::new(&root)
            .run(|_| {
                count.fetch_add(1, Ordering::Relaxed);
                zlob::walk::WalkState::Continue
            })
            .unwrap();
        count.load(Ordering::Relaxed)
    });

    timeit("zlob gitignore parallel (.build)", iters, || {
        zlob::walk::WalkBuilder::new(&root)
            .build()
            .unwrap()
            .len()
    });

    timeit("ignore serial", iters, || {
        ignore::WalkBuilder::new(&root)
            .build()
            .filter_map(Result::ok)
            .count()
            - 1
    });

    timeit("ignore parallel", iters, || {
        let count = AtomicUsize::new(0);
        ignore::WalkBuilder::new(&root).build_parallel().run(|| {
            Box::new(|e| {
                if e.is_ok() {
                    count.fetch_add(1, Ordering::Relaxed);
                }
                ignore::WalkState::Continue
            })
        });
        count.load(Ordering::Relaxed) - 1
    });

    println!();

    timeit("zlob meta(size+mtime) parallel", iters, || {
        zlob::walk::WalkBuilder::new(&root)
            .git_ignore(false)
            .hidden(false)
            .metadata(zlob::walk::WalkMetadata {
                size: true,
                modified: true,
                ..Default::default()
            })
            .build()
            .unwrap()
            .len()
    });

    timeit("walkdir + metadata()", iters, || {
        walkdir::WalkDir::new(&root)
            .into_iter()
            .filter_map(Result::ok)
            .inspect(|e| {
                std::hint::black_box(e.metadata().map(|m| m.len()).unwrap_or(0));
            })
            .count()
            - 1
    });
}
