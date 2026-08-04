#![allow(dead_code)] // each binary uses a subset

use std::collections::BTreeSet;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

fn scrubbed(args: &[&str]) -> Command {
    let mut cmd = Command::new("git");
    cmd.args(["-c", "core.excludesFile=", "-c", "core.attributesFile="])
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null");
    cmd
}

pub fn git_available() -> bool {
    Command::new("git")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

pub fn git_init(root: &Path) {
    let status = scrubbed(&["init", "-q"])
        .current_dir(root)
        .status()
        .expect("failed to spawn git");
    assert!(status.success(), "git init failed in {root:?}");
}

pub fn git_kept(cwd: &Path) -> BTreeSet<String> {
    let out = scrubbed(&["ls-files", "--others", "--exclude-standard", "-z"])
        .current_dir(cwd)
        .output()
        .expect("failed to spawn git");
    assert!(
        out.status.success(),
        "git ls-files failed in {cwd:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    split_nul(&out.stdout)
}

pub fn git_ignored_paths(root: &Path, paths: &[String]) -> BTreeSet<String> {
    let mut child = scrubbed(&["check-ignore", "--stdin", "-z"])
        .current_dir(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to spawn git");
    {
        let stdin = child.stdin.as_mut().expect("stdin piped");
        for p in paths {
            stdin.write_all(p.as_bytes()).unwrap();
            stdin.write_all(&[0]).unwrap();
        }
    }
    let out = child.wait_with_output().expect("git check-ignore");
    let code = out.status.code().unwrap_or(-1);
    assert!(
        code == 0 || code == 1,
        "git check-ignore failed ({code}) in {root:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    split_nul(&out.stdout)
}

fn split_nul(bytes: &[u8]) -> BTreeSet<String> {
    bytes
        .split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect()
}
