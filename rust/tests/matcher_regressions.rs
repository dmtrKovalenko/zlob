use zlob::{ZlobFlags, ZlobPattern, zlob_match_paths_indices};

#[test]
fn optimized_bracket_negation_matches_general_fnmatch() {
    let paths = [
        "src/a/foo.rs",
        "src/b/foo.rs",
        "src/^/foo.rs",
        "src/]/foo.rs",
        "src/x/foo.ts",
        "b/foo.rs",
    ];
    let flags = ZlobFlags::RECOMMENDED | ZlobFlags::PERIOD;
    for (pattern, expected) in [
        ("**/[^a]/*.rs", vec![1, 2, 3, 5]),
        ("**/[!a]/*.rs", vec![1, 2, 3, 5]),
        ("**/[^]a]/*.rs", vec![1, 2, 5]),
        ("**/[^a-c]/*.rs", vec![2, 3]),
        ("**/[a^]/*.rs", vec![0, 2]),
    ] {
        assert_matches(pattern, &paths, flags, &expected);
    }
}

#[test]
fn recursive_directory_patterns_keep_the_trailing_separator() {
    let paths = [
        "src",
        "src/",
        "src/a.rs",
        "src/nested",
        "src/nested/",
        "src/nested/a.rs",
        "other/",
    ];
    let flags = ZlobFlags::RECOMMENDED | ZlobFlags::PERIOD;
    assert_matches("src/**/", &paths, flags, &[1, 4]);
    assert_matches("{src,lib}/**/", &paths, flags, &[1, 4]);
}

fn assert_matches(pattern: &str, paths: &[&str], flags: ZlobFlags, expected: &[usize]) {
    let compiled = ZlobPattern::compile(pattern, flags).unwrap();
    assert_eq!(
        compiled.match_indices(paths, flags).unwrap().as_slice(),
        expected,
        "compiled batch: {pattern}"
    );
    assert_eq!(
        zlob_match_paths_indices(pattern, paths, flags)
            .unwrap()
            .as_slice(),
        expected,
        "batch: {pattern}"
    );
    for (index, path) in paths.iter().enumerate() {
        assert_eq!(
            compiled.matches_default(path),
            expected.contains(&index),
            "scalar: {pattern}: {path}"
        );
    }
}
