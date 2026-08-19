//! Regression tests for https://github.com/dmtrKovalenko/fff/issues/799.
//!
//! Filenames are byte strings on Unix and may contain arbitrary invalid
//! UTF-8. Every offset zlob reports (`relative_offset`, `basename_offset`)
//! is a *byte* offset into the raw path bytes — applying one to a lossily
//! decoded `String` (where each invalid sequence became a 3-byte U+FFFD)
//! panics with "byte index N is not a char boundary". These tests pin down
//! that the raw byte offsets stay correct for multibyte/invalid names and
//! that the `*_lossy` accessors give consumers char-boundary-safe values.
use std::path::{Path, PathBuf};
use zlob::walk::{WalkBuilder, WalkFlags};

/// One directory chain from the fff#799 reproducer tarball
/// (fff-invalid-utf8-repro.tar.gz, sha256 fc001103...), byte-exact: four
/// nested directories plus one empty file, names full of invalid UTF-8,
/// DEL/newline control bytes, and truncated multibyte sequences.
const REPRO_COMPONENTS: &[(&str, bool)] = &[
    // (hex-encoded name, is_dir)
    ("64617461322e6361622e657874726163746564", true),
    (
        "2366711cf02a03386b398b0b95824b120cd90135e777c6356ab77ead67ed0be428e3c5a7c49084cd62468cef4f780b46a97ff5e2be8afefd0962a9cfae50f861a2f637fcfe62f44c32aa96392ce1873f392ce18785905893a6c8f7b9b80b39f9cacc576a22f42758c9bd1e3071bbf041ee629cf0bbd09771b2",
        true,
    ),
    (
        "33516e5b0214f6bdf7056a22dd6886262defcb33811eb9d4bf84b321422cd4b2beb87e5db8c4aedf7fae5e45a5c5fae7e9ba39b1547f8cc3778738f9a94391b3875f20c4cb0a1b4b163938f39558e66ab0e81d0bcacd4139fd62cbf3bcfd9142a29ab511ad9c7766390abad8143428261982ba754133515066a9edf0d34c13e33e35858f65eee4adb6144fdb11546fc442574121adb24191fb95ae6ee3c40a9d787cde8cf1941c8ca7e4f903f2a5b5eaee4b5fe5b18ad62b3a48dc67431d94e0d6503b8e7bf48cd7c3be9c8569598e6f23db3222",
        true,
    ),
    (
        "6248697c3afe892703961a9d668d9ac88f557d357768c5e665ac9abc505920a44c06a56fff",
        true,
    ),
    (
        "07fa04794121fad9f17a52a373a636bec7d08d0fa68e1e7a61ce8751bbf68d06ab74fe07206dde4cadb44730f93b49f2987148fe1f28093980f5df7fcbac6b46d9837e31e97e1bae9f581a665209e43f783f06a65666d1853a9f36dea3b56aa3dcfdf7c08ccdbd7423b460de92c7157f506c1f6057fab76abb2bdae6056ccadc49dac6f5ee1e8af2c499f60dc350e3df6a5b9f38135b5dbd60c182e099af1d1f6d3c9ba26dda282e77ec59bde5afcf3e1204f7f8fd8d67bb6bdb37b65cee783f888f8454cf5d967b239ee8cd956dc3e616",
        false,
    ),
];

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

#[cfg(unix)]
fn os_str(bytes: &[u8]) -> &std::ffi::OsStr {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::OsStr::from_bytes(bytes)
}

#[cfg(unix)]
fn path_bytes_of(p: &Path) -> &[u8] {
    use std::os::unix::ffi::OsStrExt;
    p.as_os_str().as_bytes()
}

/// Builds the reproducer chain under `root`. Returns `false` when the
/// filesystem refuses the invalid-UTF-8 names (e.g. APFS/ZFS with utf8only),
/// in which case the caller skips.
#[cfg(unix)]
fn build_repro_tree(root: &Path) -> bool {
    let mut cur = PathBuf::from(root);
    for (hex, is_dir) in REPRO_COMPONENTS {
        cur.push(os_str(&unhex(hex)));
        let ok = if *is_dir {
            std::fs::create_dir(&cur).is_ok()
        } else {
            std::fs::write(&cur, b"").is_ok()
        };
        if !ok {
            return false;
        }
    }
    true
}

/// Byte-level invariants every reported entry must satisfy, independent of
/// the name's encoding.
fn assert_byte_invariants(root: &Path, results: &zlob::walk::WalkResults) {
    #[cfg(unix)]
    let root_bytes = path_bytes_of(root);
    #[cfg(not(unix))]
    let root_bytes = root.to_str().unwrap().as_bytes();

    for e in results.iter() {
        let pb = e.path_bytes();
        assert!(pb.starts_with(root_bytes));
        assert_eq!(pb[root_bytes.len()], b'/');

        // relative_offset lands exactly after "root/"
        let rel = e.relative_path_bytes();
        assert_eq!(rel, &pb[root_bytes.len() + 1..]);

        // basename_offset points right past the last '/' of the full path
        let last_slash = pb.iter().rposition(|&b| b == b'/').unwrap();
        let boff = e.basename_offset_in_relative() as usize;
        assert_eq!(
            rel.len() - (pb.len() - (last_slash + 1)),
            boff,
            "basename offset must sit after the last slash: {:?}",
            String::from_utf8_lossy(pb)
        );

        // the reported path resolves on disk
        assert!(
            std::fs::symlink_metadata(e.path()).is_ok(),
            "reported path does not exist: {:?}",
            String::from_utf8_lossy(pb)
        );

        // the lossy offset is always safe to slice the lossy string with,
        // and the slice is exactly the lossily decoded basename
        let lossy = e.relative_path_lossy();
        let loff = e.basename_offset_in_relative_lossy();
        assert!(
            lossy.is_char_boundary(loff),
            "lossy offset {loff} not a char boundary in {lossy:?}"
        );
        assert_eq!(lossy[loff..], *String::from_utf8_lossy(&rel[boff..]));
    }
}

#[cfg(unix)]
#[test]
fn invalid_utf8_names_from_fff_799_repro() {
    let dir = tempfile::tempdir().unwrap();
    if !build_repro_tree(dir.path()) {
        eprintln!("filesystem rejects invalid UTF-8 names; skipping");
        return;
    }

    let results = WalkBuilder::new(dir.path())
        .unwrap()
        .options(WalkFlags::empty())
        .threads(1)
        .collect()
        .unwrap();
    assert_eq!(results.len(), REPRO_COMPONENTS.len());
    assert_byte_invariants(dir.path(), &results);

    // ground truth: same entry set as walkdir, byte for byte
    let mut expected: Vec<Vec<u8>> = walkdir::WalkDir::new(dir.path())
        .min_depth(1)
        .into_iter()
        .map(|e| path_bytes_of(e.unwrap().path()).to_vec())
        .collect();
    let mut got: Vec<Vec<u8>> = results.iter().map(|e| e.path_bytes().to_vec()).collect();
    expected.sort();
    got.sort();
    assert_eq!(got, expected);

    // The deepest file is the fff#799 crash shape: lossy decoding inflates
    // the invalid bytes, so the raw byte offset is NOT usable on the lossy
    // string while the lossy offset is. If this stops holding the fixture
    // no longer exercises the bug.
    let deep = results
        .iter()
        .max_by_key(|e| e.depth())
        .expect("non-empty walk");
    let raw_off = deep.basename_offset_in_relative() as usize;
    let lossy = deep.relative_path_lossy();
    assert!(lossy.len() > deep.relative_path_bytes().len());
    assert!(
        !lossy.is_char_boundary(raw_off),
        "fixture must reproduce the raw-offset-inside-U+FFFD shape"
    );
    assert!(deep.basename_offset_in_relative_lossy() > raw_off);
}

#[test]
fn valid_multibyte_unicode_names() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir(root.join("ünïcode")).unwrap();
    std::fs::create_dir(root.join("ünïcode/日本語ディレクトリ")).unwrap();
    std::fs::write(root.join("ünïcode/日本語ディレクトリ/файл-🚀.txt"), b"x").unwrap();
    std::fs::write(root.join("straße.md"), b"y").unwrap();

    let results = WalkBuilder::new(root)
        .unwrap()
        .options(WalkFlags::empty())
        .threads(1)
        .collect()
        .unwrap();
    assert_eq!(results.len(), 4);
    assert_byte_invariants(root, &results);

    for e in results.iter() {
        // valid UTF-8: lossy view is identical and the offsets agree
        assert_eq!(
            e.relative_path_lossy().as_bytes(),
            e.relative_path_bytes()
        );
        assert_eq!(
            e.basename_offset_in_relative_lossy(),
            e.basename_offset_in_relative() as usize
        );
    }

    let rocket = results
        .iter()
        .find(|e| e.basename() == Some("файл-🚀.txt"))
        .expect("multibyte file reported with intact basename");
    assert_eq!(
        rocket.relative_path().to_str().unwrap(),
        "ünïcode/日本語ディレクトリ/файл-🚀.txt"
    );
    let lossy = rocket.relative_path_lossy();
    assert_eq!(
        &lossy[rocket.basename_offset_in_relative_lossy()..],
        "файл-🚀.txt"
    );
}
