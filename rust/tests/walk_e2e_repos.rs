use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// (`owner/name` on GitHub, local clone dir name).
const REPO_POOL: &[(&str, &str)] = &[
    ("dmtrKovalenko/fff.nvim", "fff"),
    ("BurntSushi/ripgrep", "ripgrep"),
    ("sharkdp/fd", "fd"),
    ("casey/just", "just"),
    ("ajeetdsouza/zoxide", "zoxide"),
    ("helix-editor/helix", "helix"),
    ("astral-sh/ruff", "ruff"),
    ("biomejs/biome", "biome"),
    ("denoland/deno_lint", "deno_lint"),
    ("nickel-lang/nickel", "nickel"),
    ("typst/typst", "typst"),
    ("gleam-lang/gleam", "gleam"),
    ("pretzelhammer/rust-blog", "rust-blog"),
    ("tokio-rs/mini-redis", "mini-redis"),
];

/// CI/network can be flaky; tolerate a few clone failures but require that a
/// healthy majority of the pool actually got walked.
const MIN_REPOS_REQUIRED: usize = 5;

fn cache_dir() -> PathBuf {
    std::env::temp_dir().join("zlob_e2e_repos")
}

/// Clones `owner/name` (depth 1) into the cache, returning the path. Returns
/// `None` if the clone fails or is skipped (offline mode with no cache).
fn clone_repo(slug: &str, dir_name: &str) -> Option<PathBuf> {
    let dest = cache_dir().join(dir_name);
    if dest.join(".git").exists() {
        return Some(dest);
    }
    if std::env::var_os("ZLOB_E2E_OFFLINE").is_some() {
        return None;
    }
    fs::create_dir_all(cache_dir()).ok()?;
    let url = format!("https://github.com/{slug}");
    let status = Command::new("git")
        .args(["clone", "--depth", "1", "--quiet", &url])
        .arg(&dest)
        .status();
    match status {
        Ok(s) if s.success() => Some(dest),
        _ => {
            // Leave no half-clone behind to confuse the next run.
            let _ = fs::remove_dir_all(&dest);
            None
        }
    }
}

/// Name of the directory we create and gitignore ourselves, so the
/// trash-leak assertion is valid for *every* repo regardless of whether it
/// already ignores `target/` (some repos, e.g. blogs, commit `target/`).
const TRASH_DIR: &str = "zlob_e2e_trash";

/// Creates `<repo>/<TRASH_DIR>/` full of build-artifact-looking trash and adds
/// a root `.gitignore` rule for it (appending, so existing rules are kept), so
/// a correct gitignore-aware walker must skip all of it. Returns how many
/// trash entries were created on disk.
fn spam_ignored_dir(root: &Path) -> usize {
    // Ensure our trash dir is gitignored. Append rather than overwrite so the
    // repo's own .gitignore stays intact (and `ignore`/zlob both still need a
    // real `.git`, which the clone provides).
    let gi = root.join(".gitignore");
    let mut contents = fs::read_to_string(&gi).unwrap_or_default();
    if !contents.contains(TRASH_DIR) {
        if !contents.ends_with('\n') && !contents.is_empty() {
            contents.push('\n');
        }
        contents.push_str(&format!("{TRASH_DIR}/\n"));
        fs::write(&gi, contents).unwrap();
    }

    let trash = root.join(TRASH_DIR);
    let mut created = 0usize;
    let mut write = |p: PathBuf| {
        if fs::write(&p, b"trash").is_ok() {
            created += 1;
        }
    };
    for profile in ["debug", "release"] {
        let deps = trash.join(profile).join("deps");
        let fingerprint = trash.join(profile).join(".fingerprint").join("zlob-e2e");
        let build = trash
            .join(profile)
            .join("build")
            .join("zlob-e2e")
            .join("out");
        for d in [&deps, &fingerprint, &build] {
            fs::create_dir_all(d).unwrap();
        }
        for i in 0..200 {
            write(deps.join(format!("libjunk_{i:03}.rlib")));
            write(deps.join(format!("junk_{i:03}.d")));
        }
        for i in 0..40 {
            write(fingerprint.join(format!("dep-lib-junk-{i}")));
            write(build.join(format!("artifact_{i}.o")));
        }
    }
    write(trash.join("CACHEDIR.TAG"));
    created
}

/// `.DS_Store` and the like are macOS filesystem artifacts that can be present
/// (even tracked) in a clone on one platform and absent on another, and the
/// `ignore` crate and zlob treat such tracked dotfiles slightly differently.
/// They are pure noise for a cross-platform *walker* comparison, so both sides
/// drop them before the path sets are compared.
fn is_os_noise(rel: &str) -> bool {
    rel.rsplit('/').next() == Some(".DS_Store") || rel == ".DS_Store"
}

/// Relative-path set produced by `walkdir` (no filtering). This is the OS
/// ground truth for a plain traversal.
fn walkdir_paths(root: &Path) -> BTreeMap<String, std::fs::Metadata> {
    walkdir::WalkDir::new(root)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.depth() > 0) // walkdir yields the root itself; zlob does not
        .map(|e| {
            let rel = rel_to_string(e.path().strip_prefix(root).unwrap());
            // symlink_metadata: lstat semantics, matching zlob (it never
            // follows symlinks by default).
            let md = fs::symlink_metadata(e.path()).unwrap();
            (rel, md)
        })
        .filter(|(rel, _)| !is_os_noise(rel))
        .collect()
}

/// Relative-path set produced by the `ignore` crate, configured to the exact
/// feature set zlob implements: hidden filtering + nested `.gitignore` only
/// (no global gitignore, no `.git/info/exclude`, no `.ignore`, no parent lookups).
fn ignore_paths(root: &Path) -> std::collections::BTreeSet<String> {
    ignore::WalkBuilder::new(root)
        .standard_filters(false)
        .hidden(true)
        .git_ignore(true)
        .build()
        .filter_map(Result::ok)
        .filter(|e| e.depth() > 0)
        .map(|e| rel_to_string(e.path().strip_prefix(root).unwrap()))
        .filter(|rel| !is_os_noise(rel))
        .collect()
}

fn rel_to_string(p: &Path) -> String {
    // Normalize separators so the comparison is identical on Windows
    // (`\`) and Unix (`/`).
    p.to_string_lossy().replace('\\', "/")
}

/// zlob plain walk -> set of relative paths.
fn zlob_plain_paths(root: &Path) -> std::collections::BTreeSet<String> {
    zlob::walk::WalkBuilder::new(root)
        .unwrap()
        .options(zlob::walk::WalkFlags::empty())
        .collect()
        .unwrap()
        .iter()
        .map(|e| rel_to_string(e.relative_path()))
        .filter(|rel| !is_os_noise(rel))
        .collect()
}

/// Pretty diff of two path sets, capped, for failure messages.
fn diff_report(
    label_a: &str,
    a: &std::collections::BTreeSet<String>,
    label_b: &str,
    b: &std::collections::BTreeSet<String>,
) -> String {
    let mut s = String::new();
    for p in a.difference(b).take(25) {
        s.push_str(&format!("\n    only in {label_a}: {p}"));
    }
    for p in b.difference(a).take(25) {
        s.push_str(&format!("\n    only in {label_b}: {p}"));
    }
    s
}

#[test]
fn walker_parity_on_popular_repos() {
    let mut walked = 0usize;
    let mut failures: Vec<String> = Vec::new();

    for (slug, dir_name) in REPO_POOL {
        let Some(root) = clone_repo(slug, dir_name) else {
            eprintln!("skip {slug}: clone unavailable");
            continue;
        };
        walked += 1;

        let trash = spam_ignored_dir(&root);

        // --- 1. PLAIN: zlob must match walkdir's path set exactly. ---
        let zlob_plain = zlob_plain_paths(&root);
        let walkdir_ref = walkdir_paths(&root);
        let walkdir_set: std::collections::BTreeSet<String> = walkdir_ref.keys().cloned().collect();

        let plain_ok = zlob_plain == walkdir_set;

        // --- 2. GITIGNORE: zlob must match the ignore crate, no leak. ---
        let zlob_git = zlob::walk::WalkBuilder::new(&root)
            .unwrap()
            .collect()
            .unwrap();
        let zlob_git_set: std::collections::BTreeSet<String> = zlob_git
            .iter()
            .map(|e| rel_to_string(e.relative_path()))
            .filter(|rel| !is_os_noise(rel))
            .collect();
        let ignore_set = ignore_paths(&root);

        let gitignore_ok = zlob_git_set == ignore_set;
        // None of the trash we injected into our own gitignored dir may appear.
        let leaked: Vec<String> = zlob_git_set
            .iter()
            .filter(|p| p.starts_with(&format!("{TRASH_DIR}/")) || p.as_str() == TRASH_DIR)
            .cloned()
            .collect();

        // --- 3. METADATA: zlob size/kind must match the OS ground truth. ---
        // Compare against the walkdir reference's lstat metadata for every
        // entry zlob reports in the plain walk.
        let zlob_meta = zlob::walk::WalkBuilder::new(&root)
            .unwrap()
            .options(zlob::walk::WalkFlags::empty())
            .metadata(zlob::walk::WalkMetadata::SIZE)
            .collect()
            .unwrap();

        let mut meta_mismatches: Vec<String> = Vec::new();
        for e in zlob_meta.iter() {
            let rel = rel_to_string(e.relative_path());
            let Some(md) = walkdir_ref.get(&rel) else {
                continue; // path-set divergence already reported above
            };
            // Kind must agree (lstat semantics on both sides).
            let kind_ok = e.is_dir() == md.is_dir()
                && e.is_file() == md.is_file()
                && e.is_symlink() == md.file_type().is_symlink();
            if !kind_ok {
                meta_mismatches.push(format!(
                    "{rel}: kind zlob(file={},dir={},link={}) vs fs(file={},dir={},link={})",
                    e.is_file(),
                    e.is_dir(),
                    e.is_symlink(),
                    md.is_file(),
                    md.is_dir(),
                    md.file_type().is_symlink(),
                ));
                continue;
            }
            // Size must match for regular files.
            if md.is_file() {
                if let Some(sz) = e.size() {
                    if sz != md.len() {
                        meta_mismatches.push(format!("{rel}: size zlob={sz} vs fs={}", md.len()));
                    }
                } else {
                    meta_mismatches.push(format!("{rel}: zlob reported no size"));
                }
            }
        }

        let meta_ok = meta_mismatches.is_empty();
        let ok = plain_ok && gitignore_ok && leaked.is_empty() && meta_ok;

        println!(
            "{:>12}: plain zlob={} walkdir={} | gitignore zlob={} ignore={} | trash={trash} leaked={} | meta_mismatch={} {}",
            dir_name,
            zlob_plain.len(),
            walkdir_set.len(),
            zlob_git_set.len(),
            ignore_set.len(),
            leaked.len(),
            meta_mismatches.len(),
            if ok { "OK" } else { "MISMATCH" },
        );

        if !ok {
            let mut detail = format!("repo {slug}:");
            if !plain_ok {
                detail.push_str(&format!(
                    "\n  PLAIN path-set mismatch (zlob vs walkdir):{}",
                    diff_report("zlob", &zlob_plain, "walkdir", &walkdir_set)
                ));
            }
            if !gitignore_ok {
                detail.push_str(&format!(
                    "\n  GITIGNORE path-set mismatch (zlob vs ignore):{}",
                    diff_report("zlob", &zlob_git_set, "ignore", &ignore_set)
                ));
            }
            if !leaked.is_empty() {
                detail.push_str(&format!(
                    "\n  LEAKED {} gitignored target/ entries, e.g. {:?}",
                    leaked.len(),
                    &leaked[..leaked.len().min(10)]
                ));
            }
            if !meta_ok {
                detail.push_str("\n  METADATA mismatches:");
                for m in meta_mismatches.iter().take(25) {
                    detail.push_str(&format!("\n    {m}"));
                }
            }
            failures.push(detail);
        }
    }

    assert!(
        walked >= MIN_REPOS_REQUIRED,
        "only {walked} repos were walked (need >= {MIN_REPOS_REQUIRED}); network/clone problem?"
    );
    assert!(
        failures.is_empty(),
        "walker parity failures:\n{}",
        failures.join("\n")
    );
}
