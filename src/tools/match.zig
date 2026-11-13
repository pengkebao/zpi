//! Native pattern matchers for the filesystem tools (find/grep), so we do not
//! depend on external binaries (grep/find do not exist on Windows).
//!
//! - `globMatch`: `*` (not `/`), `**` (any, incl. `/`), `?` (one, not `/`), `[...]`
//! - `regexMatch`: a small backtracking engine covering `.`, `*`, `+`, `?`,
//!   `[...]`, `^`, `$`, `\` (enough for typical grep patterns; no `|`/groups)

const std = @import("std");

/// Match `path` against `pattern` using glob semantics.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globRec(pattern, path);
}

fn globRec(pat_in: []const u8, path_in: []const u8) bool {
    var pat = pat_in;
    var path = path_in;
    while (pat.len > 0) {
        if (pat[0] == '*') {
            var i: usize = 0;
            while (i < pat.len and pat[i] == '*') i += 1;
            const stars = i;
            const rest = pat[i..];
            if (stars >= 2) {
                // `**` — matches any sequence of characters (including '/').
                if (rest.len == 0) return true; // trailing `**`
                if (rest[0] == '/') {
                    // `**/` — zero or more whole path segments.
                    const after = rest[1..];
                    if (globRec(after, path)) return true; // zero segments
                    var j: usize = 0;
                    while (j < path.len) : (j += 1) {
                        if (globRec(after, path[j..])) return true;
                    }
                    return false;
                }
                var j: usize = 0;
                while (j <= path.len) : (j += 1) {
                    if (globRec(rest, path[j..])) return true;
                }
                return false;
            }
            // single `*` — any run of characters except '/'.
            var j: usize = 0;
            while (j <= path.len) : (j += 1) {
                if (globRec(rest, path[j..])) return true;
                if (j < path.len and path[j] == '/') break;
            }
            return false;
        } else if (pat[0] == '?') {
            if (path.len == 0 or path[0] == '/') return false;
            pat = pat[1..];
            path = path[1..];
        } else if (pat[0] == '[') {
            var neg = false;
            var i: usize = 1;
            if (i < pat.len and (pat[i] == '^' or pat[i] == '!')) {
                neg = true;
                i += 1;
            }
            if (path.len == 0) return false;
            var matched = false;
            while (i < pat.len and pat[i] != ']') : (i += 1) {
                if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
                    if (path[0] >= pat[i] and path[0] <= pat[i + 2]) matched = true;
                    i += 2;
                } else if (pat[i] == path[0]) {
                    matched = true;
                }
            }
            if (matched != neg) {
                pat = pat[i + 1 ..]; // skip past ']'
                path = path[1..];
            } else {
                return false;
            }
        } else {
            if (path.len == 0 or path[0] != pat[0]) return false;
            pat = pat[1..];
            path = path[1..];
        }
    }
    return path.len == 0;
}

/// Match `line` against the basic regex `pattern` (grep semantics: the pattern
/// may match anywhere in the line). Supported: `.`, `*`, `+`, `?`, `[...]`,
/// `^`, `$`, `\`. Not supported: `|`, `()`, backreferences.
pub fn regexMatch(pattern: []const u8, line: []const u8) bool {
    var p = pattern;
    var start_anchor = false;
    if (p.len > 0 and p[0] == '^') {
        start_anchor = true;
        p = p[1..];
    }
    var end_anchor = false;
    if (p.len > 0 and p[p.len - 1] == '$') {
        end_anchor = true;
        p = p[0 .. p.len - 1];
    }
    if (start_anchor) return matchPrefix(p, line, end_anchor);
    var i: usize = 0;
    while (i <= line.len) : (i += 1) {
        if (matchPrefix(p, line[i..], end_anchor)) return true;
    }
    return false;
}

/// Match `p` against the start of `s`. If `end_anchor`, the match must consume
/// all of `s`.
/// Number of pattern characters the atom at `p[0]` spans (a character class
/// `[...]` spans several).
fn atomWidth(c: u8, p: []const u8) usize {
    if (c == '\\') return 2;
    if (c == '[') {
        var i: usize = 1;
        while (i < p.len and p[i] != ']') i += 1;
        return i + 1; // include the ']'
    }
    return 1;
}

fn matchPrefix(p: []const u8, s: []const u8, end_anchor: bool) bool {
    if (p.len == 0) return if (end_anchor) s.len == 0 else true;
    const c = p[0];
    const w = atomWidth(c, p);
    // Quantifier following the atom?
    if (p.len >= w + 1) {
        const q = p[w];
        if (q == '*' or q == '+' or q == '?') {
            const min: usize = if (q == '+') @as(usize, 1) else @as(usize, 0);
            var count: usize = 0;
            while (count < s.len and atomMatches(c, p, s[count])) count += 1;
            if (count < min) return false;
            var k: usize = count;
            while (true) {
                if (matchPrefix(p[w + 1 ..], s[k..], end_anchor)) return true;
                if (k == min) break;
                k -= 1;
            }
            return false;
        }
    }
    // Single atom.
    if (s.len == 0) return false;
    if (!atomMatches(c, p, s[0])) return false;
    return matchPrefix(p[w..], s[1..], end_anchor);
}

/// Does the atom at `p[0]` match the single character `ch`?
fn atomMatches(c: u8, p: []const u8, ch: u8) bool {
    if (c == '\\') {
        return p.len >= 2 and p[1] == ch;
    }
    if (c == '.') return true;
    if (c == '[') {
        var neg = false;
        var i: usize = 1;
        if (i < p.len and (p[i] == '^' or p[i] == '!')) {
            neg = true;
            i += 1;
        }
        var matched = false;
        while (i < p.len and p[i] != ']') : (i += 1) {
            if (i + 2 < p.len and p[i + 1] == '-' and p[i + 2] != ']') {
                if (ch >= p[i] and ch <= p[i + 2]) matched = true;
                i += 2;
            } else if (p[i] == ch) {
                matched = true;
            }
        }
        return matched != neg;
    }
    return c == ch;
}

// ── tests ───────────────────────────────────────────────────────────

test "glob: single star" {
    try std.testing.expect(globMatch("*.ts", "foo.ts"));
    try std.testing.expect(globMatch("*.ts", "a.ts"));
    try std.testing.expect(!globMatch("*.ts", "foo.zig"));
    try std.testing.expect(!globMatch("*.ts", "src/foo.ts")); // * does not cross /
}

test "glob: double star" {
    try std.testing.expect(globMatch("**/*.ts", "foo.ts"));
    try std.testing.expect(globMatch("**/*.ts", "src/foo.ts"));
    try std.testing.expect(globMatch("**/*.ts", "a/b/c/foo.ts"));
    try std.testing.expect(!globMatch("**/*.ts", "src/foo.zig"));
    try std.testing.expect(globMatch("src/**/*.spec.ts", "src/a/b.test.spec.ts"));
}

test "glob: question and class" {
    try std.testing.expect(globMatch("f?.ts", "fo.ts"));
    try std.testing.expect(!globMatch("f?.ts", "foo.ts")); // ? is exactly one char
    try std.testing.expect(!globMatch("f?.ts", "f.ts"));
    try std.testing.expect(globMatch("[abc].zig", "a.zig"));
    try std.testing.expect(!globMatch("[abc].zig", "d.zig"));
    try std.testing.expect(globMatch("[!abc].zig", "d.zig"));
}

test "regex: literal and dot" {
    try std.testing.expect(regexMatch("hello", "say hello world"));
    try std.testing.expect(!regexMatch("hello", "say hi"));
    try std.testing.expect(regexMatch("h.llo", "hello"));
    try std.testing.expect(regexMatch("h.llo", "hallo")); // . matches 'a'
}

test "regex: quantifiers" {
    try std.testing.expect(regexMatch("a*", "bbb"));
    try std.testing.expect(regexMatch("a+b", "aaab"));
    try std.testing.expect(!regexMatch("a+b", "b"));
    try std.testing.expect(regexMatch("colou?r", "color"));
    try std.testing.expect(regexMatch("colou?r", "colour"));
}

test "regex: anchors and class" {
    try std.testing.expect(regexMatch("^foo", "foobar"));
    try std.testing.expect(!regexMatch("^foo", "xfoobar"));
    try std.testing.expect(regexMatch("bar$", "foobar"));
    try std.testing.expect(!regexMatch("bar$", "foobarx"));
    try std.testing.expect(regexMatch("^[0-9]+$", "12345"));
    try std.testing.expect(!regexMatch("^[0-9]+$", "12a45"));
    try std.testing.expect(regexMatch("\\.zig$", "a.zig"));
    try std.testing.expect(!regexMatch("\\.zig$", "a.zigx"));
}
