// Property-test corpus comparing zlob's gitignore behavior to git itself (mostly vibed)
#![cfg(not(windows))] // windows CI is too slow for this

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use proptest::prelude::*;

mod common;
use common::{git_available, git_ignored_paths, git_init, git_kept};
use zlob::walk::{WalkBuilder, WalkFlags};
use zlob::{ZlobFlags, zlob};

const DIRS: &[&str] = &[
    "a",
    "a/b",
    "a/b/c",
    "a/b/c/d",
    "a/b/c/d/e",
    "logs",
    "a/logs",
    "build",
    "build/keep",
    "node_modules",
    "x",
    "x/node_modules",
    "dir.d",
    "plain",
    "foo",
    "foo/xbar",
    "src",
    "src/deep",
    "deep",
    ".hidden",
    "sp ace",
    "up",
    "up/logs",
];
const FILES: &[&str] = &[
    "top.txt",
    "top.log",
    "Makefile",
    ".keep",
    "a/f.txt",
    "a/f.log",
    "a/b/g.txt",
    "a/b/c/h.txt",
    "a/b/c/d/deep1.txt",
    "a/b/c/d/e/deep2.txt",
    "a/b/c/d/e/noext",
    "a/b/c/h.o",
    "logs/l1.txt",
    "a/logs/l2.txt",
    "up/logs/l3.txt",
    "build/b.o",
    "build/keep/k.txt",
    "node_modules/n.js",
    "x/node_modules/h.txt",
    "dir.d/x.md",
    "dir.d/noext",
    "plain/y.txt",
    "foo/xbar/deep.txt",
    "src/lib.rs",
    "src/noext",
    "src/deep/a.txt",
    "deep/d.txt",
    ".hidden/hf.txt",
    "sp ace/s.txt",
    "a[1].txt",
    "#hash.txt",
    "bang!.txt",
    "star*.log",
    "q?y",
];

/// (label, .gitignore contents)
fn corpus() -> Vec<(&'static str, String)> {
    let raw: &[&str] = &[
        // --- basename patterns
        "logs",
        "logs/",
        "*.log",
        "*.o",
        "?.txt",
        "[abc].txt",
        "[!abc].txt",
        // --- anchored
        "/logs",
        "/logs/",
        "/top.txt",
        "a/b",
        "a/b/",
        "/a/b/c/",
        // --- doublestar
        "**",
        "/**/",
        "**/",
        "**/logs",
        "**/logs/",
        "a/**",
        "a/**/",
        "a/**/c/",
        "a/**/*.txt",
        "**/*.o",
        "/**/node_modules/",
        "**/node_modules/",
        // --- wildcard dirs
        "*/",
        "*/logs/",
        "dir.*/",
        "/build*/",
        "src/*/",
        "foo/*bar/",
        "**/deep/",
        // --- negation basics
        "*.log\n!top.log",
        "*\n!*.txt",
        "*\n!*.*\n!/**/",
        "*\n!*.*\n!**/",
        "logs/\n!logs/l1.txt",
        "/build/\n!/build/keep/",
        "a/\n!a/b/\n!a/b/g.txt",
        // --- last-match-wins ordering
        "!*.txt\n*.txt",
        "*.txt\n!*.txt",
        "*.txt\n!a/*.txt\n*.txt",
        // --- escapes & literals
        "\\#hash.txt",
        "bang\\!.txt",
        "a\\[1\\].txt",
        "sp\\ ace/",
        "*.log ",
        // Escaped-byte handling: `\\.` is a literal dot, so `*\\.log` must behave
        // exactly like `*.log`, and `\\*` / `\\?` name literal metacharacters.
        "*\\.log",
        "star\\*.log",
        "q\\?y",
        "*\\.txt",
        // Runs of doublestars fold to one (`**/**` == `**`); the long form also
        // guards the pattern segment budget.
        "**/**",
        "a/**/**",
        "a/**/**/**/b",
        "**/**/a.txt",
        "**/**/logs/",
        // Symlinks are files to git, even when they point at a directory:
        // `linkdir/` must miss and `linkdir` must hit.
        "linkdir/",
        "linkdir",
        "link.txt",
        "*.link",
        "a/uplink/",
        "a/uplink",
        // Deep nesting: ancestor resolution over several levels.
        "a/b/c/d/",
        "a/b/c/d/e/",
        "**/e/",
        "a/**/e/noext",
        "a/b/c/d/*",
        "a/b/c/d/\n!a/b/c/d/e",
        // --- comments / blanks
        "# comment\n\n*.log\n   \n",
        "\\!important.txt\n*.log",
        // --- deep interactions
        "*\n!a/\n!a/b/\n!a/b/c/\n!*.txt",
        "**/*.txt\n!a/**/*.txt",
        "build\nkeep",
        "node_modules\n!x/node_modules",
        // --- trailing-slash + doublestar combos
        "a/**/logs/",
        "up/**",
        "/up/logs",
        "**/x/**",
    ];
    raw.iter().map(|s| (*s, s.to_string())).collect()
}

/// Symlinks as `(link, target)`. git records a symlink as a file entry and
/// never descends it, so a dir-only pattern must not match a link that points at
/// a directory (`linkdir/` misses, `linkdir` hits) — an easy thing to get wrong
/// if `is_dir` comes from `stat` rather than `lstat`. A dangling link is
/// included because it must still be reported rather than treated as missing.
const SYMLINKS: &[(&str, &str)] = &[
    ("link.txt", "top.txt"),
    ("linkdir", "a"),
    ("a/uplink", "../logs"),
    ("broken.link", "nowhere-at-all"),
];

/// Every path the fixture contains, directories included. This is the domain
/// over which per-path verdicts are compared; `ls-files` can only speak about
/// files, so directory correctness needs `check-ignore`.
fn all_paths() -> Vec<String> {
    let mut v: Vec<String> = DIRS
        .iter()
        .chain(FILES.iter())
        .chain(SYMLINKS.iter().map(|(link, _)| link))
        .map(|s| (*s).to_string())
        .collect();
    v.sort();
    v
}

fn build_tree(root: &Path) {
    for d in DIRS {
        fs::create_dir_all(root.join(d)).unwrap();
    }
    for f in FILES {
        fs::write(root.join(f), "x").unwrap();
    }
    for (link, target) in SYMLINKS {
        std::os::unix::fs::symlink(target, root.join(link)).unwrap();
    }
    git_init(root);
}

/// Directories that may host a nested .gitignore during fuzzing.
const IGNORE_HOSTS: &[&str] = &["", "a", "a/b", "a/b/c/d", "src", "up", "build"];

/// Install a case: `spec` maps host dir -> contents. Hosts not named are cleared.
fn set_gitignores(root: &Path, spec: &[(String, String)]) {
    for h in IGNORE_HOSTS {
        let p = if h.is_empty() {
            root.join(".gitignore")
        } else {
            root.join(h).join(".gitignore")
        };
        let _ = fs::remove_file(&p);
        if let Some((_, body)) = spec.iter().find(|(d, _)| d == h) {
            fs::write(&p, format!("{body}\n")).unwrap();
        }
    }
}

const SEGS: &[&str] = &[
    // Ordered roughly plain -> exotic: `prop::sample::select` shrinks toward
    // index 0, so a failure is reduced to the least exotic segment that still
    // reproduces it.
    "a",
    "b",
    "c",
    "logs",
    "build",
    "keep",
    "node_modules",
    "src",
    "deep",
    "up",
    "x",
    "f.txt",
    "g.txt",
    "h.o",
    "noext",
    "Makefile",
    ".keep",
    ".hidden",
    "sp ace",
    "#hash.txt",
    "*",
    "**",
    "*.txt",
    "*.log",
    "*.o",
    "*.*",
    "?.txt",
    "??.txt",
    "d*",
    "*e",
    "a*c",
    "dir.*",
    "[abc]*",
    "[!abc]*",
    "[a-c]*",
    // Runs of stars: `***`/`****` must behave as `**`, while `**a`/`a**`/`b**c`
    // are ordinary single-segment patterns.
    "***",
    "****",
    "**a",
    "a**",
    "b**c",
    // Backslash escapes, including escaped bytes after a leading `*` — those
    // must not take the raw-suffix fast path, which compares byte-for-byte.
    "\\#hash.txt",
    "bang\\!.txt",
    "a\\[1\\].txt",
    "sp\\ ace",
    "*\\.log",
    "*\\.txt",
    "star\\*.log",
    "q\\?y",
];

/// One `.gitignore` line: optional `!`, optional anchoring `/`, 1-4 segments,
/// optional trailing `/`, optional trailing space (which git trims).
fn pattern_line() -> impl Strategy<Value = String> {
    (
        prop::bool::weighted(0.25),
        prop::bool::weighted(0.33),
        prop::collection::vec(prop::sample::select(SEGS), 1..4),
        prop::bool::weighted(0.33),
        prop::bool::weighted(0.06),
    )
        .prop_map(|(negated, anchored, segs, dir_only, trailing_space)| {
            let mut line = String::new();
            if negated {
                line.push('!');
            }
            if anchored {
                line.push('/');
            }
            line.push_str(&segs.join("/"));
            if dir_only {
                line.push('/');
            }
            if trailing_space {
                line.push(' ');
            }
            line
        })
        // Lines git ignores entirely would only dilute the search space.
        .prop_filter("degenerate line", |l| {
            let body = l.trim_start_matches('!');
            !body.is_empty() && body != "/" && body != "/ "
        })
}

/// The body of one `.gitignore` file: pattern lines plus the occasional comment
/// or blank, which exercise the parser's line filtering.
fn gitignore_body() -> impl Strategy<Value = String> {
    prop::collection::vec(
        prop_oneof![
            10 => pattern_line(),
            1 => Just("# comment".to_string()),
            1 => Just(String::new()),
        ],
        1..5,
    )
    .prop_map(|lines| lines.join("\n"))
}

/// A whole case: the root `.gitignore` plus up to two nested ones, so nested
/// precedence and parent/child interaction are covered.
fn gitignore_case() -> impl Strategy<Value = Vec<(String, String)>> {
    (
        gitignore_body(),
        prop::collection::vec(
            (prop::sample::select(&IGNORE_HOSTS[1..]), gitignore_body()),
            0..3,
        ),
    )
        .prop_map(|(root, nested)| {
            let mut spec = vec![(String::new(), root)];
            for (host, body) in nested {
                // One .gitignore per directory; keep the first for a host.
                if !spec.iter().any(|(d, _)| d == host) {
                    spec.push((host.to_string(), body));
                }
            }
            spec
        })
}

/// Surface 2: `IgnoreRules::is_ignored`, the post-walk query API. Separate
/// ancestor resolution from the walk itself, and reachable for paths the walk
/// pruned and never visited.
fn zlob_rules_ignored(root: &Path, paths: &[String], threads: usize) -> BTreeSet<String> {
    let results = WalkBuilder::new(root)
        .unwrap()
        .options(WalkFlags::GITIGNORE)
        .threads(threads)
        .collect()
        .unwrap();
    let rules = results.ignore_rules().expect("rules are always retained");
    paths
        .iter()
        .filter(|p| rules.is_ignored(p))
        .cloned()
        .collect()
}

/// Thread counts every case is walked at. The walker is a parallel
/// work-stealing design, so an answer that is only correct single-threaded is
/// not correct: pruning decisions are taken concurrently on different subtrees
/// and each worker resolves ignore rules against its own node chain.
const THREAD_COUNTS: &[usize] = &[1, 2, 4, 8];

/// Surface 1: files kept by a gitignore-aware walk. Hidden files are
/// included because git has no notion of "hidden", and directories are dropped
/// because git does not track them.
fn zlob_kept(root: &Path, threads: usize) -> BTreeSet<String> {
    WalkBuilder::new(root)
        .unwrap()
        .options(WalkFlags::GITIGNORE)
        .threads(threads)
        .collect()
        .unwrap()
        .iter()
        .filter(|e| !e.is_dir())
        .map(|e| e.relative_path().to_string_lossy().into_owned())
        .filter(|p| p != ".git" && !p.starts_with(".git/"))
        .collect()
}

fn label_of(spec: &[(String, String)]) -> String {
    spec.iter()
        .map(|(d, b)| {
            format!(
                "[{}] {}",
                if d.is_empty() { "/" } else { d },
                b.replace('\n', " \\n ")
            )
        })
        .collect::<Vec<_>>()
        .join("   ||   ")
}

/// Build a fresh fixture tree. Each test owns one (see the `OnceLock`s below):
/// cargo runs tests concurrently, and every case rewrites the `.gitignore`
/// files in place, so a shared tree would let the tests corrupt each other.
fn make_fixture() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    build_tree(dir.path());
    dir
}

/// Install `spec`, then check every zlob surface against every git oracle.
/// Returns `Err(report)` describing all disagreements found for this case.
fn compare(root: &Path, spec: &[(String, String)]) -> Result<(), String> {
    set_gitignores(root, spec);
    let paths = all_paths();

    let mut report = String::new();
    let mut note = |surface: &str, oracle: &str, missing: Vec<String>, extra: Vec<String>| {
        if missing.is_empty() && extra.is_empty() {
            return;
        }
        report.push_str(&format!("  surface {surface} vs {oracle}:\n"));
        if !missing.is_empty() {
            report.push_str(&format!(
                "    zlob wrongly KEPT   : {}\n",
                missing.join(", ")
            ));
        }
        if !extra.is_empty() {
            report.push_str(&format!("    zlob wrongly IGNORED: {}\n", extra.join(", ")));
        }
    };

    // Surface 1: the walk's own enumeration, against the whole-walk oracle, at
    // every thread count. A parallel walk must produce the same answer as a
    // serial one, so each is checked against git rather than against thread 1.
    let git_files = git_kept(root);
    let git_ignored = git_ignored_paths(root, &paths);
    let mut walk_files = BTreeSet::new();
    for &threads in THREAD_COUNTS {
        let kept = zlob_kept(root, threads);
        note(
            &format!("walker-enumeration (threads={threads})"),
            "git ls-files",
            kept.difference(&git_files).cloned().collect(),
            git_files.difference(&kept).cloned().collect(),
        );

        // Surface 2: the reusable rules, against the per-path oracle. This is
        // the only check covering directory verdicts and paths under pruned
        // trees, and the rules are built by the same concurrent walk.
        let rules_ignored = zlob_rules_ignored(root, &paths, threads);
        note(
            &format!("IgnoreRules::is_ignored (threads={threads})"),
            "git check-ignore",
            git_ignored.difference(&rules_ignored).cloned().collect(),
            rules_ignored.difference(&git_ignored).cloned().collect(),
        );

        if threads == THREAD_COUNTS[0] {
            walk_files = kept;
        }
    }
    let rules_ignored = zlob_rules_ignored(root, &paths, 1);

    // Cross-surface consistency: a file the walk emitted must not be reported
    // ignored by the rules, and vice versa. Both agreeing with git implies this,
    // but asserting it directly localises which surface drifted.
    let inconsistent: Vec<String> = FILES
        .iter()
        .map(|f| (*f).to_string())
        .filter(|f| walk_files.contains(f) == rules_ignored.contains(f))
        .collect();
    if !inconsistent.is_empty() {
        report.push_str(&format!(
            "  surfaces disagree with each other on: {}\n",
            inconsistent.join(", ")
        ));
    }

    if report.is_empty() {
        return Ok(());
    }
    Err(format!("gitignore:\n  {}\n{report}", label_of(spec)))
}

/// Fixed corpus of hand-written patterns. Asserted exhaustively — every case
/// runs on every invocation, unlike the sampled property below.
#[test]
fn curated_patterns_match_git() {
    if !git_available() {
        eprintln!("skipping: `git` not on PATH");
        return;
    }
    static FIXTURE: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    let root = FIXTURE.get_or_init(make_fixture).path();
    let mut failures = Vec::new();
    let cases = corpus();
    for (_, body) in &cases {
        let spec = vec![(String::new(), body.clone())];
        if let Err(diff) = compare(root, &spec) {
            failures.push(diff);
        }
    }
    assert!(
        failures.is_empty(),
        "{} / {} curated cases diverge from git:\n{}",
        failures.len(),
        cases.len(),
        failures.join("")
    );
}

// perform randomized fuzzy testing for compatibility between our walker and git itself via ls-files
proptest! {
    #![proptest_config(ProptestConfig {
        cases: 2048,
        max_shrink_iters: 4096,
        // Point persistence at a fixed path: the default `SourceParallel`
        // strategy looks for lib.rs/main.rs and warns when run from tests/.
        failure_persistence: Some(Box::new(proptest::test_runner::FileFailurePersistence::Direct(
            "tests/git_compat.proptest-regressions",
        ))),
        ..ProptestConfig::default()
    })]

    #[test]
    fn generated_patterns_match_git(spec in gitignore_case()) {
        prop_assume!(git_available());
        static FIXTURE: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
        let root = FIXTURE.get_or_init(make_fixture).path();
        if let Err(diff) = compare(root, &spec) {
            prop_assert!(false, "{}", diff);
        }
    }
}

fn cwd_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn interesting(path: &str) -> bool {
    path != ".gitignore" && !path.split('/').any(|c| c.starts_with('.'))
}

fn glob_kept(root: &Path) -> BTreeSet<String> {
    zlob(
        "**/*",
        ZlobFlags::GITIGNORE | ZlobFlags::DOUBLESTAR_RECURSIVE,
    )
    .unwrap()
    .map(|r| r.to_strings())
    .unwrap_or_default()
    .into_iter()
    .map(|p| p.trim_start_matches("./").to_string())
    // Keep everything that is not a real directory. `is_file()` would be wrong:
    // it follows links, so a symlink to a directory — which git records as a
    // plain file entry — would be dropped, as would a dangling one.
    .filter(|p| {
        interesting(p)
            && !root
                .join(p)
                .symlink_metadata()
                .map(|m| m.is_dir())
                .unwrap_or(false)
    })
    .collect()
}

#[test]
fn glob_engine_does_not_read_nested_gitignore() {
    if !git_available() {
        eprintln!("skipping: `git` not on PATH");
        return;
    }
    let _cwd = cwd_lock();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    fs::create_dir(root.join("sub")).unwrap();
    for f in ["top.txt", "sub/a.log", "sub/keep.txt"] {
        fs::write(root.join(f), "x").unwrap();
    }
    fs::write(root.join(".gitignore"), "unrelated\n").unwrap();
    fs::write(root.join("sub/.gitignore"), "*.log\n").unwrap();
    git_init(root);
    std::env::set_current_dir(root).unwrap();

    // git honours sub/.gitignore and drops sub/a.log.
    let git = git_kept(root);
    assert!(
        !git.contains("sub/a.log"),
        "sanity: git should honour sub/.gitignore"
    );

    // The glob engine still yields it.
    let glob = glob_kept(root);
    assert!(
        glob.contains("sub/a.log"),
        "expected the documented limitation (root-only .gitignore on this \
         surface); if this now passes, the glob engine gained nested discovery \
         and this test plus its doc comment should go: {glob:?}"
    );
}

#[test]
fn glob_engine_matches_git() {
    if !git_available() {
        eprintln!("skipping: `git` not on PATH");
        return;
    }
    let _cwd = cwd_lock();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    build_tree(root);
    std::env::set_current_dir(root).unwrap();

    let mut failures = Vec::new();
    let cases = corpus();
    for (_, body) in &cases {
        fs::write(root.join(".gitignore"), format!("{body}\n")).unwrap();
        let git: BTreeSet<String> = git_kept(root)
            .into_iter()
            .filter(|p| interesting(p))
            .collect();
        let glob = glob_kept(root);
        if git == glob {
            continue;
        }
        let missing: Vec<_> = git.difference(&glob).cloned().collect();
        let extra: Vec<_> = glob.difference(&git).cloned().collect();
        let mut msg = format!("  gitignore: {}\n", body.replace('\n', " \\n "));
        if !missing.is_empty() {
            msg.push_str(&format!("    wrongly IGNORED: {}\n", missing.join(", ")));
        }
        if !extra.is_empty() {
            msg.push_str(&format!("    wrongly KEPT   : {}\n", extra.join(", ")));
        }
        failures.push(msg);
    }
    assert!(
        failures.is_empty(),
        "{} / {} patterns diverge from git on the glob surface:\n{}",
        failures.len(),
        cases.len(),
        failures.join("")
    );
}
