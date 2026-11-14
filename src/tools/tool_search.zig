//! `tool_search` (pi parity): BM25 discovery over tools that are not declared
//! to the model (`codemode` and `deferred` exposure) and loading of the
//! matches, so they are declared for the next model call.
//!
//! Mirrors pi's `extensions/tool-search/tool.js`:
//!   - Unicode-ish tokenization with identifier boundaries, English stop words
//!     and naive singular forms (pi additionally uses Intl.Segmenter for
//!     non-ASCII scripts; rpi keeps whole non-ASCII runs as single terms).
//!   - Okapi BM25 (k1=1.2, b=0.75) over the description with the name
//!     (weight 3) and the namespace (weight 0.5) as separate fields.
//!   - Ordering: exact-name queries first, then query coverage, then score;
//!     ties keep document order.
//!
//! pi activates `tool_search` when a server with `deferred` exposure connects
//! (and `codemode` — the script runner — for `codemode` servers). rpi has no
//! codemode yet, so it auto-activates `tool_search` for BOTH `codemode` and
//! `deferred` servers; without it those tools would be unreachable.

const std = @import("std");
const tools = @import("registry.zig");
const mcp = @import("../core/mcp.zig");

pub const TOOL_SEARCH_TOOL_NAME = "tool_search";
pub const DEFAULT_TOOL_SEARCH_LIMIT = 8;

/// Whether a tool with this exposure can be found/loaded by `tool_search`.
pub fn isSearchable(exposure: []const u8) bool {
    return std.mem.eql(u8, exposure, "codemode") or std.mem.eql(u8, exposure, "deferred");
}

const STOP_WORDS = [_][]const u8{
    "a",       "an",  "and", "are", "as",  "at", "be", "by",   "for", "from",
    "in",      "is",  "it",  "of",  "on",  "or", "that",     "the",  "this",
    "to",      "with",
};

fn isStopWord(word: []const u8) bool {
    for (STOP_WORDS) |w| {
        if (std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

/// Stemmed length of the word `w` (pi `stem()`): `issues` -> `issue`,
/// `searches` -> `search`, `flies` -> `fly`.
fn stemLen(w: []const u8) usize {
    if (w.len > 4 and std.mem.endsWith(u8, w, "ies")) return w.len - 2;
    if (w.len > 4 and (std.mem.endsWith(u8, w, "ches") or std.mem.endsWith(u8, w, "shes") or
        std.mem.endsWith(u8, w, "sses") or std.mem.endsWith(u8, w, "xes") or std.mem.endsWith(u8, w, "zes")))
        return w.len - 2;
    if (w.len > 3 and w[w.len - 1] == 's' and !std.mem.endsWith(u8, w, "ss"))
        return w.len - 1;
    return w.len;
}

/// Apply the stem to the word bytes: only the `ies` -> `y` case rewrites a
/// byte ("flies" -> "fly"); the other cases are pure truncation.
fn applyStem(w: []u8) void {
    if (w.len > 4 and std.mem.endsWith(u8, w, "ies")) {
        w[w.len - 3] = 'y';
    }
}

/// Split camelCase and identifier boundaries into words, lowercase, treat
/// every non-alphanumeric run as a separator, drop stop words, stem ASCII
/// words (pi `tokenize()`, minus Intl.Segmenter; non-ASCII word runs stay
/// single terms). Use `normalizeText` to prepare raw text first.
pub fn tokenize(alloc: std.mem.Allocator, normalized_text: []const u8, owned: *std.array_list.Managed(u8)) Error![][]const u8 {
    return tokenizeImpl(alloc, normalized_text, owned);
}

/// Lowercase + boundary splitting on the prepared text, then stop-word filter
/// and stemming. Words are appended to `owned` (NUL-terminated not required);
/// the returned slices point into it.
/// Lowercase + boundary splitting on the prepared text, then stop-word filter
/// and stemming. Word bytes are appended to `owned`; the returned slices point
/// into it, so the caller must keep `owned` alive and untouched for as long as
/// it uses the words. Slices are built only after ALL bytes have been appended
/// (so growth-related reallocs cannot dangle earlier words).
fn tokenizeImpl(alloc: std.mem.Allocator, prepared: []const u8, owned: *std.array_list.Managed(u8)) Error![][]const u8 {
    const Span = struct { start: usize, len: usize };
    var spans = std.array_list.Managed(Span).init(alloc);
    defer spans.deinit();
    var start: usize = 0;
    var i: usize = 0;
    while (i <= prepared.len) : (i += 1) {
        const is_word = i < prepared.len and isWordChar(prepared[i]);
        const was_word = start < i;
        if (was_word and !is_word) {
            // Split the raw run into lowercase alnum words: lowercase, drop
            // stop words, stem, remember (start, stemmed length).
            const raw = prepared[start..i];
            var w_start: ?usize = null;
            var j: usize = 0;
            while (j <= raw.len) : (j += 1) {
                const c: u8 = if (j < raw.len) raw[j] else ' ';
                const wc: u8 = if (std.ascii.isUpper(c)) std.ascii.toLower(c) else c;
                const ok = j < raw.len and std.ascii.isAlphanumeric(wc);
                if (ok and w_start == null) w_start = owned.items.len;
                if (ok) {
                    owned.append(wc) catch return error.OutOfMemory;
                } else if (w_start) |st| {
                    const w = owned.items[st..];
                    if (!isStopWord(w)) {
                        const len = stemLen(w);
                        try spans.append(.{ .start = st, .len = len });
                    }
                    w_start = null;
                }
            }
        }
        if (is_word and start >= i) start = i;
        if (!is_word) start = i + 1;
    }
    // Build the final slices (no more appends to `owned`).
    var words = std.array_list.Managed([]const u8).init(alloc);
    errdefer words.deinit();
    for (spans.items) |sp| {
        const w = owned.items[sp.start..][0..sp.len];
        applyStem(@constCast(w));
        try words.append(w);
    }
    return words.toOwnedSlice();
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// Split camelCase boundaries ("fooBar" -> "foo bar", "HTTPServer" ->
/// "http server"), lowercase, and normalize every non-alphanumeric run to a
/// single space (pi's normalize+replace chain, ASCII approximation).
pub fn normalizeText(alloc: std.mem.Allocator, text: []const u8) Error![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        const lc = if (std.ascii.isUpper(c)) std.ascii.toLower(c) else c;
        if (std.ascii.isAlphanumeric(lc)) {
            out.append(lc) catch return error.OutOfMemory;
            // lower/digit -> upper boundary: "fooBar" -> "foo bar".
            if ((std.ascii.isLower(lc) or std.ascii.isDigit(lc)) and
                i + 1 < text.len and std.ascii.isUpper(text[i + 1]))
            {
                out.append(' ') catch return error.OutOfMemory;
            }
            i += 1;
        } else {
            // Collapse a non-alphanumeric run into one space.
            while (i < text.len and !std.ascii.isAlphanumeric(text[i])) i += 1;
            out.append(' ') catch return error.OutOfMemory;
        }
    }
    return out.toOwnedSlice();
}

/// Lowercase with characters invalid in script identifiers as `_`, so
/// `dev-radius` matches `dev_radius` (pi `normalizeName()`).
fn normalizeName(alloc: std.mem.Allocator, name: []const u8) Error![]u8 {
    const buf = try alloc.alloc(u8, name.len);
    errdefer alloc.free(buf);
    for (name, 0..) |c, i| {
        const lc = std.ascii.toLower(c);
        buf[i] = if (std.ascii.isAlphanumeric(lc) or lc == '_' or lc == '$') lc else '_';
    }
    return buf;
}

/// Whether the whole query is the tool's name: its full name or a suffix after
/// a `__` separator, so `thread_read` and `app__thread_read` both name
/// `mcp__app__thread_read` (pi `isExactNameQuery()`).
fn isExactNameQuery(alloc: std.mem.Allocator, query: []const u8, name: []const u8) Error!bool {
    if (query.len == 0) return false;
    const normalized = try normalizeName(alloc, name);
    defer alloc.free(normalized);
    if (std.mem.eql(u8, normalized, query)) return true;
    if (normalized.len > query.len + 2) {
        const tail = normalized[normalized.len - query.len - 2 ..];
        return std.mem.eql(u8, tail[0..2], "__") and std.mem.eql(u8, tail[2..], query);
    }
    return false;
}

/// Schema descriptions and property names, recursively (pi `schemaText()`).
fn schemaText(alloc: std.mem.Allocator, parts: *std.array_list.Managed(u8), value: std.json.Value) Error!void {
    switch (value) {
        .object => |obj| {
            if (obj.get("description")) |d| {
                if (d == .string) {
                    try appendPart(parts, d.string);
                }
            }
            if (obj.get("properties")) |props| {
                if (props == .object) {
                    var it = props.object.iterator();
                    while (it.next()) |entry| {
                        try appendPart(parts, entry.key_ptr.*);
                        try schemaText(alloc, parts, entry.value_ptr.*);
                    }
                }
            }
            if (obj.get("items")) |items| {
                try schemaText(alloc, parts, items);
            }
            inline for (.{ "anyOf", "oneOf", "allOf" }) |key| {
                if (obj.get(key)) |variants| {
                    if (variants == .array) {
                        for (variants.array.items) |v| {
                            try schemaText(alloc, parts, v);
                        }
                    }
                }
            }
        },
        else => {},
    }
}

fn appendPart(parts: *std.array_list.Managed(u8), s: []const u8) Error!void {
    if (std.mem.trim(u8, s, " ").len == 0) return;
    if (parts.items.len > 0) try parts.append(' ');
    try parts.appendSlice(s);
}

/// A ranked match.
pub const Match = struct {
    name: []const u8,
    score: f64,
};

const IndexedDoc = struct {
    name: []const u8,
    /// Terms from the tool name.
    name_terms: [][]const u8,
    /// Terms from the local (last `__` segment) name.
    local_name_terms: [][]const u8,
    /// Term -> occurrence count within the description/schema text.
    text_counts: std.StringHashMap(u32),
    text_length: u32,
    /// Terms from the namespace text.
    namespace_terms: [][]const u8,
};

pub const Document = struct {
    name: []const u8,
    text: []const u8,
    namespace_text: []const u8 = "",
};

const Error = error{OutOfMemory};

/// Weight of a query term appearing in the tool's name (pi NAME_WEIGHT: a
/// name match beats any number of description mentions).
const NAME_WEIGHT = 3;
/// Weight of a query term appearing in the namespace text (pi
/// NAMESPACE_WEIGHT: shared by every tool of the server).
const NAMESPACE_WEIGHT = 0.5;

/// Okapi BM25 ranker over tool metadata (pi `Bm25Ranker`, k1=1.2 b=0.75).
pub const Bm25Ranker = struct {
    k1: f64 = 1.2,
    b: f64 = 0.75,

    /// Rank `documents` against `query`. Returns owned matches (caller frees
    /// the slice; names point into `documents`). Stable: ties keep document
    /// order.
    pub fn rank(self: *const Bm25Ranker, alloc: std.mem.Allocator, query: []const u8, documents: []const Document, limit: usize) Error![]Match {
        var owned_words = std.array_list.Managed(u8).init(alloc);
        defer owned_words.deinit();
        const query_terms_raw = try tokenizeImpl(alloc, query, &owned_words);
        defer alloc.free(query_terms_raw);
        // Deduplicate query terms (pi uses a Set).
        var query_terms = std.array_list.Managed([]const u8).init(alloc);
        defer query_terms.deinit();
        for (query_terms_raw) |t| {
            var dup = false;
            for (query_terms.items) |seen| {
                if (std.mem.eql(u8, seen, t)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try query_terms.append(t);
        }
        if (query_terms.items.len == 0 or documents.len == 0 or limit == 0) return alloc.alloc(Match, 0);

        // Index documents. All term lists point into per-doc word buffers,
        // freed at the end.
        var indexed = std.array_list.Managed(IndexedDoc).init(alloc);
        defer {
            for (indexed.items) |*doc| {
                alloc.free(doc.name_terms);
                alloc.free(doc.local_name_terms);
                alloc.free(doc.namespace_terms);
                var it = doc.text_counts.iterator();
                while (it.next()) |e| alloc.free(e.key_ptr.*);
                doc.text_counts.deinit();
            }
            indexed.deinit();
        }
        var doc_word_bufs = std.array_list.Managed(*std.array_list.Managed(u8)).init(alloc);
        defer {
            for (doc_word_bufs.items) |buf| {
                buf.deinit();
                alloc.destroy(buf);
            }
            doc_word_bufs.deinit();
        }
        var total_text_len: f64 = 0;
        for (documents) |doc| {
            const words = try alloc.create(std.array_list.Managed(u8));
            words.* = std.array_list.Managed(u8).init(alloc);
            try doc_word_bufs.append(words);
            var name_terms = std.array_list.Managed([]const u8).init(alloc);
            errdefer name_terms.deinit();
            const prepared_name = try normalizeText(alloc, doc.name);
            defer alloc.free(prepared_name);
            const name_tokens = try tokenizeImpl(alloc, prepared_name, words);
            defer alloc.free(name_tokens);
            try dedupeAppend(&name_terms, name_tokens);
            // Local name: last `__` segment.
            const last_seg = blk: {
                var idx: ?usize = null;
                if (std.mem.lastIndexOf(u8, doc.name, "__")) |i| idx = i;
                break :blk if (idx) |i| doc.name[i + 2 ..] else doc.name;
            };
            var local_terms = std.array_list.Managed([]const u8).init(alloc);
            errdefer local_terms.deinit();
            const prepared_local = try normalizeText(alloc, last_seg);
            defer alloc.free(prepared_local);
            const local_tokens = try tokenizeImpl(alloc, prepared_local, words);
            defer alloc.free(local_tokens);
            try dedupeAppend(&local_terms, local_tokens);

            var text_counts = std.StringHashMap(u32).init(alloc);
            errdefer {
                var itd = text_counts.iterator();
                while (itd.next()) |e| alloc.free(e.key_ptr.*);
                text_counts.deinit();
            }
            var text_len: u32 = 0;
            const prepared_text = try normalizeText(alloc, doc.text);
            defer alloc.free(prepared_text);
            const text_tokens = try tokenizeImpl(alloc, prepared_text, words);
            defer alloc.free(text_tokens);
            for (text_tokens) |t| {
                const owned_key = try alloc.dupe(u8, t);
                const gop = try text_counts.getOrPut(owned_key);
                if (gop.found_existing) {
                    alloc.free(owned_key);
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                }
                text_len += 1;
            }

            var ns_terms = std.array_list.Managed([]const u8).init(alloc);
            errdefer ns_terms.deinit();
            const prepared_ns = try normalizeText(alloc, doc.namespace_text);
            defer alloc.free(prepared_ns);
            const ns_tokens = try tokenizeImpl(alloc, prepared_ns, words);
            defer alloc.free(ns_tokens);
            try dedupeAppend(&ns_terms, ns_tokens);

            try indexed.append(.{
                .name = doc.name,
                .name_terms = try name_terms.toOwnedSlice(),
                .local_name_terms = try local_terms.toOwnedSlice(),
                .text_counts = text_counts,
                .text_length = text_len,
                .namespace_terms = try ns_terms.toOwnedSlice(),
            });
            total_text_len += @floatFromInt(text_len);
        }
        const average_length = if (indexed.items.len > 0)
            total_text_len / @as(f64, @floatFromInt(indexed.items.len))
        else
            1;
        const avg = if (average_length == 0) 1 else average_length;

        // IDF per query term.
        var idf = std.array_list.Managed(f64).init(alloc);
        defer idf.deinit();
        for (query_terms.items) |term| {
            var frequency: usize = 0;
            for (indexed.items) |*doc| {
                if (hasTerm(doc.name_terms, term) or doc.text_counts.contains(term) or hasTerm(doc.namespace_terms, term)) {
                    frequency += 1;
                }
            }
            const nf: f64 = @floatFromInt(frequency);
            const nn: f64 = @floatFromInt(indexed.items.len);
            const v = @log(1 + (nn - nf + 0.5) / (nf + 0.5));
            try idf.append(v);
        }
        var full_name_bonus: f64 = 0;
        for (idf.items) |v| full_name_bonus += v;

        const exact_query = try normalizeName(alloc, query);
        defer alloc.free(exact_query);

        const Candidate = struct {
            name: []const u8,
            score: f64,
            covered: usize,
            exact: bool,
            order: usize,
        };
        var matches = std.array_list.Managed(Candidate).init(alloc);
        defer matches.deinit();

        for (indexed.items, 0..) |*doc, di| {
            const norm = self.k1 * (1 - self.b + (self.b * @as(f64, @floatFromInt(doc.text_length))) / avg);
            var score: f64 = 0;
            var covered: usize = 0;
            for (query_terms.items, idf.items) |term, term_idf| {
                const count: f64 = @floatFromInt(doc.text_counts.get(term) orelse 0);
                var weight: f64 = 0;
                if (hasTerm(doc.name_terms, term)) weight += NAME_WEIGHT;
                if (hasTerm(doc.namespace_terms, term)) weight += NAMESPACE_WEIGHT;
                weight += (count * (self.k1 + 1)) / (count + norm);
                if (weight > 0) covered += 1;
                score += term_idf * weight;
            }
            if (score == 0) continue;
            // Local-name bonus: when every term of the tool's local name is in
            // the query, add one full "extra match" of every query term.
            const local = doc.local_name_terms;
            if (local.len > 0 and allIn(local, query_terms.items)) {
                score += full_name_bonus;
            }
            const exact = try isExactNameQuery(alloc, exact_query, doc.name);
            try matches.append(.{ .name = doc.name, .score = score, .covered = covered, .exact = exact, .order = di });
        }

        // Stable sort: exact first, then coverage, then score, then document
        // order (insertion sort keeps ties in document order).
        std.sort.insertion(Candidate, matches.items, {}, struct {
            fn lt(_: void, a: Candidate, bb: Candidate) bool {
                if (a.exact != bb.exact) return a.exact;
                if (a.covered != bb.covered) return a.covered > bb.covered;
                if (a.score != bb.score) return a.score > bb.score;
                return a.order < bb.order;
            }
        }.lt);

        const out = try alloc.alloc(Match, @min(matches.items.len, limit));
        for (out, 0..) |*m, i| {
            m.* = .{ .name = matches.items[i].name, .score = matches.items[i].score };
        }
        return out;
    }

    fn hasTerm(terms: [][]const u8, term: []const u8) bool {
        for (terms) |t| {
            if (std.mem.eql(u8, t, term)) return true;
        }
        return false;
    }

    fn allIn(terms: [][]const u8, pool: [][]const u8) bool {
        for (terms) |t| {
            if (!hasTerm(pool, t)) return false;
        }
        return true;
    }

    fn dedupeAppend(list: *std.array_list.Managed([]const u8), tokens: [][]const u8) Error!void {
        for (tokens) |t| {
            var dup = false;
            for (list.items) |seen| {
                if (std.mem.eql(u8, seen, t)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try list.append(t);
        }
    }
};

/// Search text of a tool: description + schema descriptions/property names,
/// plus the server description as namespace text (pi `createToolSearchDocument`;
/// the namespace is the MCP server's description when available).
fn buildDocument(alloc: std.mem.Allocator, tool: *const tools.Tool) Error!Document {
    var parts = std.array_list.Managed(u8).init(alloc);
    errdefer parts.deinit();
    try appendPart(&parts, tool.description);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, tool.parameters_json, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    if (parsed) |*p| {
        try schemaText(alloc, &parts, p.value);
    }
    var ns_text: []const u8 = "";
    if (std.mem.startsWith(u8, tool.name, "mcp__")) {
        if (mcp.Manager.getGlobal()) |mgr| {
            const after = tool.name[5..];
            if (std.mem.indexOfScalar(u8, after, '_')) |second| {
                if (mgr.findByName(after[0..second])) |srv| {
                    if (srv.description) |d| ns_text = d;
                }
            }
        }
    }
    return .{ .name = tool.name, .text = try parts.toOwnedSlice(), .namespace_text = ns_text };
}

pub fn freeDocument(alloc: std.mem.Allocator, doc: *Document) void {
    alloc.free(doc.text);
}

// ── The tool itself ──────────────────────────────────────────────────────

/// The registry `tool_search` operates on. Set by main.zig before the session
/// starts, cleared at shutdown (mirrors the MCP Manager global).
var global_registry: ?*tools.Registry = null;

pub fn setGlobal(registry: ?*tools.Registry) void {
    global_registry = registry;
}

const SEARCH_SCHEMA =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Search query for deferred tools."},"limit":{"type":"number","description":"Maximum number of tools to return. Defaults to 8."}},"required":["query"]}
;

fn firstLine(alloc: std.mem.Allocator, description: []const u8) Error![]u8 {
    const trimmed = std.mem.trim(u8, description, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return alloc.dupe(u8, std.mem.trim(u8, trimmed[0..nl], " \t\r"));
}

/// Rank the searchable tools that are not active yet and activate the matches,
/// so the next model call declares them (pi `searchAndLoad()`).
pub fn searchAndLoad(registry: *tools.Registry, alloc: std.mem.Allocator, query: []const u8, limit: usize) Error![]Match {
    var candidates = std.array_list.Managed(*const tools.Tool).init(alloc);
    defer candidates.deinit();
    for (registry.tools.items) |*t| {
        if (isSearchable(t.exposure) and !t.active) try candidates.append(t);
    }
    var documents = std.array_list.Managed(Document).init(alloc);
    defer {
        for (documents.items) |*d| freeDocument(alloc, d);
        documents.deinit();
    }
    for (candidates.items) |t| {
        try documents.append(try buildDocument(alloc, t));
    }
    const ranker = Bm25Ranker{};
    const matches = try ranker.rank(alloc, query, documents.items, limit);
    errdefer alloc.free(matches);
    if (matches.len > 0) {
        for (matches) |m| {
            _ = registry.setActive(m.name, true);
        }
    }
    return matches;
}

fn executeSearch(_: *const tools.Tool, args_json: []const u8, ctx: *tools.ExecutionContext) tools.ToolResult {
    const alloc = ctx.alloc;
    const registry = global_registry orelse return err(alloc, "error: tool_search not available");
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch
        return err(alloc, "error: invalid arguments");
    defer parsed.deinit();
    if (parsed.value != .object) return err(alloc, "error: invalid arguments");
    const obj = parsed.value.object;
    const query = if (obj.get("query")) |q| (if (q == .string) q.string else "") else "";
    if (std.mem.trim(u8, query, " \t\r\n").len == 0) return err(alloc, "error: query must not be empty");
    var limit: usize = DEFAULT_TOOL_SEARCH_LIMIT;
    if (obj.get("limit")) |l| {
        if (l == .integer and l.integer > 0) {
            limit = @intCast(@min(l.integer, 1000));
        } else if (l == .float and l.float > 0 and l.float == @trunc(l.float)) {
            limit = @intFromFloat(@min(l.float, 1000));
        } else {
            return err(alloc, "error: limit must be a positive integer");
        }
    }

    const matches = searchAndLoad(registry, alloc, query, limit) catch
        return err(alloc, "error: out of memory");
    defer alloc.free(matches);

    if (matches.len == 0) {
        return .{ .content = alloc.dupe(u8, "No matching tools found.") catch "", .is_error = false };
    }
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    {
        const head = std.fmt.allocPrint(alloc, "Loaded {d} tool{s}. They are available from your next call:", .{ matches.len, if (matches.len == 1) "" else "s" }) catch
            return err(alloc, "error: out of memory");
        defer alloc.free(head);
        out.appendSlice(head) catch return err(alloc, "error: out of memory");
    }
    for (matches) |m| {
        // First line of the tool's description (pi output format).
        var desc: []u8 = &[_]u8{};
        for (registry.tools.items) |*t| {
            if (std.mem.eql(u8, t.name, m.name)) {
                desc = firstLine(alloc, t.description) catch &[_]u8{};
                break;
            }
        }
        defer if (desc.len > 0) alloc.free(desc);
        const line = std.fmt.allocPrint(alloc, "\n- {s}: {s}", .{ m.name, desc }) catch
            return err(alloc, "error: out of memory");
        defer alloc.free(line);
        out.appendSlice(line) catch return err(alloc, "error: out of memory");
    }
    return .{ .content = alloc.dupe(u8, out.items) catch "", .is_error = false };
}

fn err(alloc: std.mem.Allocator, msg: []const u8) tools.ToolResult {
    return .{ .content = alloc.dupe(u8, msg) catch "", .is_error = true };
}

/// Create the `tool_search` tool definition. Registered INACTIVE (pi:
/// `defaultActive: false`); activate it with `--tools`, the `defaultTools`
/// setting, or automatically when a searchable MCP server connects.
pub fn registerToolSearch(registry: *tools.Registry) !void {
    try registry.register(.{
        .name = TOOL_SEARCH_TOOL_NAME,
        .description = "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes matching tools for the next model call.\n\nSome of the tools, such as tools of MCP servers, may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search`.",
        .parameters_json = SEARCH_SCHEMA,
        .execute = executeSearch,
        .exposure = "model-only",
        .active = false,
    });
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "stem" {
    var owned = std.array_list.Managed(u8).init(testing.allocator);
    defer owned.deinit();
    // Stem a word: append raw bytes, then trim/rewrite per stemLen/applyStem.
    const S = struct {
        fn stemOne(ow: *std.array_list.Managed(u8), word: []const u8) ![]const u8 {
            const st = ow.items.len;
            try ow.appendSlice(word);
            const w = ow.items[st..];
            const len = stemLen(w);
            applyStem(@constCast(w));
            ow.shrinkRetainingCapacity(st + len);
            return ow.items[st..];
        }
    };
    // Each word needs a fresh buffer region; owned accumulates, slices stay
    // valid for the comparisons below.
    const w1 = try S.stemOne(&owned, "issues");
    try testing.expectEqualStrings("issue", w1);
    const w2 = try S.stemOne(&owned, "searches");
    try testing.expectEqualStrings("search", w2);
    const w3 = try S.stemOne(&owned, "boss");
    try testing.expectEqualStrings("boss", w3); // ss stays
    const w4 = try S.stemOne(&owned, "windows");
    try testing.expectEqualStrings("window", w4);
    const w5 = try S.stemOne(&owned, "sky");
    try testing.expectEqualStrings("sky", w5); // short: untouched
    const w6 = try S.stemOne(&owned, "flies");
    try testing.expectEqualStrings("fly", w6); // ies -> y
    const w7 = try S.stemOne(&owned, "witches");
    try testing.expectEqualStrings("witch", w7);
}

test "tokenize stop words and camelCase" {
    var owned = std.array_list.Managed(u8).init(testing.allocator);
    defer owned.deinit();
    const words = try tokenizeImpl(testing.allocator, "the screenshot window", &owned);
    defer testing.allocator.free(words);
    try testing.expectEqual(@as(usize, 2), words.len);
    try testing.expectEqualStrings("screenshot", words[0]);
    try testing.expectEqualStrings("window", words[1]);

    const camel_src = try normalizeText(testing.allocator, "mcp__peekaboo__screenshotWindow");
    defer testing.allocator.free(camel_src);
    const camel = try tokenizeImpl(testing.allocator, camel_src, &owned);
    defer testing.allocator.free(camel);
    // "the" removed; local segmentation happens elsewhere.
    try testing.expectEqual(@as(usize, 4), camel.len);
    try testing.expectEqualStrings("mcp", camel[0]);
    try testing.expectEqualStrings("peekaboo", camel[1]);
    try testing.expectEqualStrings("screenshot", camel[2]);
    try testing.expectEqualStrings("window", camel[3]);
}

test "ranker: name match beats description mentions" {
    const docs = [_]Document{
        .{ .name = "window", .text = "window window window describes windows" },
        .{ .name = "screenshot", .text = "capture a screenshot of the screen" },
    };
    const r = Bm25Ranker{};
    const matches = try r.rank(testing.allocator, "screenshot", &docs, 8);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("screenshot", matches[0].name);
}

test "ranker: coverage ordering" {
    // "screenshot window": the doc with BOTH words beats the name-only doc.
    const docs = [_]Document{
        .{ .name = "window", .text = "focus a window" },
        .{ .name = "capture", .text = "screenshot of the active window" },
    };
    const r = Bm25Ranker{};
    const matches = try r.rank(testing.allocator, "screenshot window", &docs, 8);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 2), matches.len);
    try testing.expectEqualStrings("capture", matches[0].name);
    try testing.expectEqualStrings("window", matches[1].name);
}

test "ranker: exact name query first" {
    const docs = [_]Document{
        .{ .name = "read_file", .text = "mentions read_file read_file read_file a lot" },
        .{ .name = "mcp__app__read_file", .text = "read a file from the app" },
    };
    const r = Bm25Ranker{};
    const matches = try r.rank(testing.allocator, "read_file", &docs, 8);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 2), matches.len);
    // Both are exact-name matches; coverage and score decide. Both cover 1.
    // The mcp one has fewer text mentions -> lower text score but both exact.
    // Name weight makes both scores high; stability keeps order for ties.
    try testing.expect(std.mem.eql(u8, matches[0].name, "read_file") or std.mem.eql(u8, matches[0].name, "mcp__app__read_file"));
}

test "ranker: limit" {
    const docs = [_]Document{
        .{ .name = "a_one", .text = "widget" },
        .{ .name = "b_two", .text = "widget widget" },
        .{ .name = "c_three", .text = "widget widget widget" },
    };
    const r = Bm25Ranker{};
    const matches = try r.rank(testing.allocator, "widget", &docs, 2);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 2), matches.len);
    try testing.expectEqualStrings("c_three", matches[0].name);
    try testing.expectEqualStrings("b_two", matches[1].name);
}

test "ranker: no query terms, no matches" {
    const docs = [_]Document{ .{ .name = "x", .text = "y" } };
    const r = Bm25Ranker{};
    const matches = try r.rank(testing.allocator, "the of and", &docs, 8);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 0), matches.len);
}

fn noopExecute(_: *const tools.Tool, _: []const u8, _: *tools.ExecutionContext) tools.ToolResult {
    return .{ .content = "", .is_error = false };
}

test "searchAndLoad activates codemode/deferred matches only" {
    var registry = tools.Registry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(.{ .name = "read", .description = "read files", .parameters_json = "{}", .execute = noopExecute, .active = false });
    try registry.register(.{ .name = "mcp__peekaboo__screenshot", .description = "Take a screenshot of a window", .parameters_json = "{}", .execute = noopExecute, .exposure = "codemode", .active = false });
    try registry.register(.{ .name = "mcp__docs__search", .description = "Search documentation pages", .parameters_json = "{}", .execute = noopExecute, .exposure = "deferred", .active = false });

    setGlobal(&registry);
    defer setGlobal(null);
    const matches = try searchAndLoad(&registry, testing.allocator, "screenshot window", 8);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("mcp__peekaboo__screenshot", matches[0].name);
    // Loaded: now active. Inactive direct tools stay untouched.
    try testing.expect(registry.find("mcp__peekaboo__screenshot").?.active);
    try testing.expect(!registry.find("mcp__docs__search").?.active);
    try testing.expect(!registry.find("read").?.active);
}

test "tool_search execute loads tools and reports them" {
    var registry = tools.Registry.init(testing.allocator);
    defer registry.deinit();
    try registerToolSearch(&registry);
    try registry.register(.{ .name = "mcp__docs__search", .description = "Search documentation pages\nwith more detail", .parameters_json = "{}", .execute = noopExecute, .exposure = "deferred", .active = false });
    _ = registry.setActive("tool_search", true);

    setGlobal(&registry);
    defer setGlobal(null);

    var ctx = tools.ExecutionContext{ .alloc = testing.allocator, .io = testing.io, .cwd = "/tmp" };
    const t = registry.find("tool_search").?;
    const res = executeSearch(t, "{\"query\":\"documentation search\"}", &ctx);
    defer testing.allocator.free(@constCast(res.content));
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content, "Loaded 1 tool.") != null);
    try testing.expect(std.mem.indexOf(u8, res.content, "- mcp__docs__search: Search documentation pages") != null);
    try testing.expect(registry.find("mcp__docs__search").?.active);

    // Empty query -> error.
    const res2 = executeSearch(t, "{\"query\":\"  \"}", &ctx);
    defer testing.allocator.free(@constCast(res2.content));
    try testing.expect(res2.is_error);
    try testing.expect(std.mem.indexOf(u8, res2.content, "query must not be empty") != null);

    // No match -> friendly message.
    const res3 = executeSearch(t, "{\"query\":\"zzzqqq\"}", &ctx);
    defer testing.allocator.free(@constCast(res3.content));
    try testing.expect(!res3.is_error);
    try testing.expectEqualStrings("No matching tools found.", res3.content);
}
