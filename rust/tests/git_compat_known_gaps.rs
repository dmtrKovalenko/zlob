#![cfg(not(windows))]
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::process::Command;
use zlob::walk::{WalkBuilder, WalkFlags};
mod common;
use common::{git_available, git_init, git_kept};

fn kept(cwd: &Path) -> BTreeSet<String> {
    git_kept(cwd)
        .into_iter()
        .filter(|p| p != ".gitignore")
        .collect()
}

fn walk_kept(root: &Path) -> BTreeSet<String> {
    WalkBuilder::new(root)
        .unwrap()
        .options(WalkFlags::GITIGNORE)
        .threads(1)
        .collect()
        .unwrap()
        .iter()
        .filter(|e| !e.is_dir())
        .map(|e| e.relative_path().to_string_lossy().into_owned())
        .filter(|p| p != ".gitignore")
        .collect()
}

/// We *DO NOT* support outside of base directories ignore files
#[test]
fn parent_gitignore_above_walk_root_is_not_applied() {
    if !git_available() {
        eprintln!("skipping: `git` not on PATH");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    fs::create_dir_all(root.join("src/deep")).unwrap();
    for f in ["src/app.log", "src/keep.rs", "src/deep/d.log"] {
        fs::write(root.join(f), "x").unwrap();
    }
    fs::write(root.join(".gitignore"), "*.log\n").unwrap();
    git_init(root);

    // git, asked from inside src/, applies the parent rule.
    let git = kept(&root.join("src"));
    assert_eq!(
        git,
        BTreeSet::from(["keep.rs".to_string()]),
        "sanity: git should apply the parent .gitignore"
    );

    // zlob, rooted at src/, never sees it.
    let walk = walk_kept(&root.join("src"));
    assert_eq!(
        walk,
        BTreeSet::from([
            "keep.rs".to_string(),
            "app.log".to_string(),
            "deep/d.log".to_string(),
        ]),
        "expected the documented gap (no parent-directory discovery). If this \
         now matches git, delete this test and fold the case into git_compat.rs"
    );
}

/// matching is always case-sensitive unlike git has a setting for it
#[test]
fn matching_is_case_sensitive_even_where_git_is_not() {
    if !git_available() {
        eprintln!("skipping: `git` not on PATH");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    fs::create_dir(root.join("Logs")).unwrap();
    fs::write(root.join("Logs/a.txt"), "x").unwrap();
    fs::write(root.join("README.MD"), "x").unwrap();
    fs::write(root.join(".gitignore"), "logs/\n").unwrap();
    git_init(root);

    let ignorecase = Command::new("git")
        .args(["config", "core.ignorecase"])
        .current_dir(root)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "true")
        .unwrap_or(false);
    if !ignorecase {
        eprintln!("skipping: git is case-sensitive here, no divergence to pin");
        return;
    }

    // git folds case: `logs/` matches `Logs`.
    assert_eq!(
        kept(root),
        BTreeSet::from(["README.MD".to_string()]),
        "sanity: git with core.ignorecase=true should match Logs"
    );

    // zlob does not.
    assert_eq!(
        walk_kept(root),
        BTreeSet::from(["Logs/a.txt".to_string(), "README.MD".to_string()]),
        "expected the documented gap (case-sensitive matching). If this now \
         matches git, delete this test and fold the case into git_compat.rs"
    );
}

/// We do not support .git/info/exclude and core.excludesFile from git config
/// any configuration outside of .gitignore files are out of scope
#[test]
fn info_exclude_and_global_excludes_are_not_consulted() {
    if !git_available() {
        eprintln!("skipping: `git` not on PATH");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    for f in ["a.log", "keep.rs"] {
        fs::write(root.join(f), "x").unwrap();
    }
    git_init(root);
    fs::write(root.join(".git/info/exclude"), "*.log\n").unwrap();

    // git honours info/exclude.
    assert_eq!(
        kept(root),
        BTreeSet::from(["keep.rs".to_string()]),
        "sanity: git should honour .git/info/exclude"
    );

    // zlob skips .git entirely and never reads it.
    assert_eq!(
        walk_kept(root),
        BTreeSet::from(["a.log".to_string(), "keep.rs".to_string()]),
        "expected the documented gap (info/exclude not consulted). If this now \
         matches git, delete this test and fold the case into git_compat.rs"
    );
}
