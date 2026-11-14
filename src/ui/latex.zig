//! LaTeX → unicode text conversion for markdown math blocks and inline math
//! (pi: pi-tui latex.js + the latexBlock markdown extension). A pragmatic
//! subset: symbol tables (Greek letters, operators, relations, arrows),
//! \frac → a/b, \sqrt → √(…), super/subscripts mapped to unicode when the
//! characters exist, \left/\right stripping, \text/\mathrm shells, and
//! unknown commands keeping their name without the backslash. Anything
//! ambiguous renders the original source — pi likewise falls back to raw.

const std = @import("std");

const Symbol = struct { name: []const u8, glyph: []const u8 };

const symbols = [_]Symbol{
    // Greek lowercase
    .{ .name = "alpha", .glyph = "α" },     .{ .name = "beta", .glyph = "β" },
    .{ .name = "gamma", .glyph = "γ" },     .{ .name = "delta", .glyph = "δ" },
    .{ .name = "epsilon", .glyph = "ϵ" },   .{ .name = "varepsilon", .glyph = "ε" },
    .{ .name = "zeta", .glyph = "ζ" },      .{ .name = "eta", .glyph = "η" },
    .{ .name = "theta", .glyph = "θ" },     .{ .name = "vartheta", .glyph = "ϑ" },
    .{ .name = "iota", .glyph = "ι" },      .{ .name = "kappa", .glyph = "κ" },
    .{ .name = "lambda", .glyph = "λ" },    .{ .name = "mu", .glyph = "μ" },
    .{ .name = "nu", .glyph = "ν" },        .{ .name = "xi", .glyph = "ξ" },
    .{ .name = "pi", .glyph = "π" },        .{ .name = "rho", .glyph = "ρ" },
    .{ .name = "sigma", .glyph = "σ" },     .{ .name = "varsigma", .glyph = "ς" },
    .{ .name = "tau", .glyph = "τ" },       .{ .name = "upsilon", .glyph = "υ" },
    .{ .name = "phi", .glyph = "ϕ" },       .{ .name = "varphi", .glyph = "φ" },
    .{ .name = "chi", .glyph = "χ" },       .{ .name = "psi", .glyph = "ψ" },
    .{ .name = "omega", .glyph = "ω" },
    // Greek uppercase
    .{ .name = "Gamma", .glyph = "Γ" },     .{ .name = "Delta", .glyph = "Δ" },
    .{ .name = "Theta", .glyph = "Θ" },     .{ .name = "Lambda", .glyph = "Λ" },
    .{ .name = "Xi", .glyph = "Ξ" },        .{ .name = "Pi", .glyph = "Π" },
    .{ .name = "Sigma", .glyph = "Σ" },     .{ .name = "Upsilon", .glyph = "Υ" },
    .{ .name = "Phi", .glyph = "Φ" },       .{ .name = "Psi", .glyph = "Ψ" },
    .{ .name = "Omega", .glyph = "Ω" },
    // Binary operators
    .{ .name = "pm", .glyph = "±" },        .{ .name = "mp", .glyph = "∓" },
    .{ .name = "times", .glyph = "×" },     .{ .name = "div", .glyph = "÷" },
    .{ .name = "cdot", .glyph = "·" },      .{ .name = "ast", .glyph = "∗" },
    .{ .name = "star", .glyph = "⋆" },      .{ .name = "circ", .glyph = "∘" },
    .{ .name = "bullet", .glyph = "•" },    .{ .name = "oplus", .glyph = "⊕" },
    .{ .name = "ominus", .glyph = "⊖" },    .{ .name = "otimes", .glyph = "⊗" },
    .{ .name = "oslash", .glyph = "⊘" },    .{ .name = "odot", .glyph = "⊙" },
    .{ .name = "dagger", .glyph = "†" },    .{ .name = "ddagger", .glyph = "‡" },
    // Relations
    .{ .name = "leq", .glyph = "≤" },       .{ .name = "le", .glyph = "≤" },
    .{ .name = "geq", .glyph = "≥" },       .{ .name = "ge", .glyph = "≥" },
    .{ .name = "neq", .glyph = "≠" },       .{ .name = "ne", .glyph = "≠" },
    .{ .name = "equiv", .glyph = "≡" },     .{ .name = "approx", .glyph = "≈" },
    .{ .name = "sim", .glyph = "∼" },       .{ .name = "simeq", .glyph = "≅" },
    .{ .name = "cong", .glyph = "≅" },      .{ .name = "propto", .glyph = "∝" },
    .{ .name = "ll", .glyph = "≪" },        .{ .name = "gg", .glyph = "≫" },
    // Set relations
    .{ .name = "in", .glyph = "∈" },        .{ .name = "notin", .glyph = "∉" },
    .{ .name = "ni", .glyph = "∋" },        .{ .name = "subset", .glyph = "⊂" },
    .{ .name = "supset", .glyph = "⊃" },    .{ .name = "subseteq", .glyph = "⊆" },
    .{ .name = "supseteq", .glyph = "⊇" },  .{ .name = "cup", .glyph = "∪" },
    .{ .name = "cap", .glyph = "∩" },       .{ .name = "setminus", .glyph = "∖" },
    .{ .name = "emptyset", .glyph = "∅" },  .{ .name = "varnothing", .glyph = "∅" },
    // Big operators / calculus
    .{ .name = "sum", .glyph = "∑" },       .{ .name = "prod", .glyph = "∏" },
    .{ .name = "coprod", .glyph = "∐" },    .{ .name = "int", .glyph = "∫" },
    .{ .name = "iint", .glyph = "∬" },      .{ .name = "iiint", .glyph = "∭" },
    .{ .name = "oint", .glyph = "∮" },      .{ .name = "infty", .glyph = "∞" },
    .{ .name = "partial", .glyph = "∂" },   .{ .name = "nabla", .glyph = "∇" },
    .{ .name = "surd", .glyph = "√" },      .{ .name = "aleph", .glyph = "ℵ" },
    .{ .name = "hbar", .glyph = "ℏ" },      .{ .name = "ell", .glyph = "ℓ" },
    // Logic
    .{ .name = "forall", .glyph = "∀" },    .{ .name = "exists", .glyph = "∃" },
    .{ .name = "nexists", .glyph = "∄" },   .{ .name = "neg", .glyph = "¬" },
    .{ .name = "land", .glyph = "∧" },      .{ .name = "lor", .glyph = "∨" },
    .{ .name = "vdash", .glyph = "⊢" },     .{ .name = "models", .glyph = "⊨" },
    // Arrows
    .{ .name = "to", .glyph = "→" },        .{ .name = "rightarrow", .glyph = "→" },
    .{ .name = "leftarrow", .glyph = "←" }, .{ .name = "Rightarrow", .glyph = "⇒" },
    .{ .name = "Leftarrow", .glyph = "⇐" }, .{ .name = "leftrightarrow", .glyph = "↔" },
    .{ .name = "Leftrightarrow", .glyph = "⇔" }, .{ .name = "uparrow", .glyph = "↑" },
    .{ .name = "downarrow", .glyph = "↓" }, .{ .name = "mapsto", .glyph = "↦" },
    .{ .name = "leadsto", .glyph = "↝" },   .{ .name = "rightleftharpoons", .glyph = "⇌" },
    // Misc
    .{ .name = "ldots", .glyph = "…" },     .{ .name = "dots", .glyph = "…" },
    .{ .name = "cdots", .glyph = "⋯" },     .{ .name = "vdots", .glyph = "⋮" },
    .{ .name = "ddots", .glyph = "⋱" },     .{ .name = "angle", .glyph = "∠" },
    .{ .name = "perp", .glyph = "⊥" },      .{ .name = "parallel", .glyph = "∥" },
    .{ .name = "mid", .glyph = "∣" },       .{ .name = "langle", .glyph = "⟨" },
    .{ .name = "rangle", .glyph = "⟩" },    .{ .name = "prime", .glyph = "′" },
    .{ .name = "degree", .glyph = "°" },    .{ .name = "checkmark", .glyph = "✓" },
    .{ .name = "quad", .glyph = "  " },     .{ .name = "qquad", .glyph = "    " },
};

fn symbolFor(name: []const u8) ?[]const u8 {
    for (symbols) |sym| {
        if (std.mem.eql(u8, sym.name, name)) return sym.glyph;
    }
    return null;
}

/// Unicode superscript for `c`, when one exists.
fn superscriptOf(c: u8) ?[]const u8 {
    return switch (c) {
        '0'... '9' => switch (c) {
            '0' => "⁰",
            '1' => "¹",
            '2' => "²",
            '3' => "³",
            '4' => "⁴",
            '5' => "⁵",
            '6' => "⁶",
            '7' => "⁷",
            '8' => "⁸",
            else => "⁹",
        },
        '+' => "⁺",
        '-' => "⁻",
        '=' => "⁼",
        '(' => "⁽",
        ')' => "⁾",
        'n' => "ⁿ",
        'i' => "ⁱ",
        else => null,
    };
}

/// Unicode subscript for `c`, when one exists.
fn subscriptOf(c: u8) ?[]const u8 {
    return switch (c) {
        '0'... '9' => switch (c) {
            '0' => "₀",
            '1' => "₁",
            '2' => "₂",
            '3' => "₃",
            '4' => "₄",
            '5' => "₅",
            '6' => "₆",
            '7' => "₇",
            '8' => "₈",
            else => "₉",
        },
        '+' => "₊",
        '-' => "₋",
        '=' => "₌",
        '(' => "₍",
        ')' => "₎",
        'a' => "ₐ",
        'e' => "ₑ",
        'o' => "ₒ",
        'x' => "ₓ",
        'h' => "ₕ",
        'k' => "ₖ",
        'l' => "ₗ",
        'm' => "ₘ",
        'n' => "ₙ",
        'p' => "ₚ",
        's' => "ₛ",
        't' => "ₜ",
        else => null,
    };
}

const Renderer = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    src: []const u8,
    i: usize = 0,

    fn put(self: *Renderer, text: []const u8) !void {
        try self.out.appendSlice(self.alloc, text);
    }

    /// Content of the brace group at self.i (`{...}`), rendered recursively.
    /// Advances past the closing brace. Null when there is no group.
    fn group(self: *Renderer) ?[]const u8 {
        if (self.i >= self.src.len or self.src[self.i] != '{') return null;
        var depth: usize = 0;
        var j = self.i;
        while (j < self.src.len) : (j += 1) {
            if (self.src[j] == '{') depth += 1;
            if (self.src[j] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (j >= self.src.len) return null;
        const inner = self.src[self.i + 1 .. j];
        self.i = j + 1;
        return inner;
    }

    /// Argument of a prefix command: a brace group or a single character.
    fn arg(self: *Renderer) ?[]const u8 {
        if (self.group()) |g| return g;
        if (self.i < self.src.len) {
            const c = self.src[self.i];
            // A space after a single-char arg binds to the command, not the arg
            // (`x^2 y` means `x^2` then a space).
            if (c == ' ') return null;
            self.i += 1;
            return self.src[self.i - 1 .. self.i];
        }
        return null;
    }

    fn renderSub(self: *Renderer, inner: []const u8, map: *const fn (u8) ?[]const u8, wrap_prefix: []const u8) anyerror!void {
        var sub = Renderer{ .alloc = self.alloc, .src = inner };
        try sub.run();
        const text = try sub.out.toOwnedSlice(self.alloc);
        defer self.alloc.free(text);
        // Map character by character when every char has a unicode form.
        var all_mapped = text.len > 0;
        for (text) |c| {
            if (map(c) == null) all_mapped = false;
        }
        if (all_mapped) {
            for (text) |c| try self.put(map(c).?);
        } else {
            try self.put(wrap_prefix);
            try self.put("{");
            try self.put(text);
            try self.put("}");
        }
    }

    fn run(self: *Renderer) anyerror!void {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\\') {
                self.i += 1;
                if (self.i >= self.src.len) break;
                const start = self.i;
                while (self.i < self.src.len and std.ascii.isAlphabetic(self.src[self.i])) self.i += 1;
                const name = self.src[start..self.i];
                if (name.len == 0) {
                    // Escaped punctuation (\{ \} \$ …): the literal char.
                    try self.put(self.src[start .. start + 1]);
                    self.i = start + 1;
                    continue;
                }
                if (std.mem.eql(u8, name, "frac")) {
                    const num = self.arg() orelse { try self.put(name); continue; };
                    var numr = Renderer{ .alloc = self.alloc, .src = num };
                    try numr.run();
                    const num_text = try numr.out.toOwnedSlice(self.alloc);
                    defer self.alloc.free(num_text);
                    const den = self.arg() orelse { try self.put(num_text); try self.put("/"); continue; };
                    var denr = Renderer{ .alloc = self.alloc, .src = den };
                    try denr.run();
                    const den_text = try denr.out.toOwnedSlice(self.alloc);
                    defer self.alloc.free(den_text);
                    try self.put("(");
                    try self.put(num_text);
                    try self.put(")/(");
                    try self.put(den_text);
                    try self.put(")");
                    continue;
                }
                if (std.mem.eql(u8, name, "sqrt")) {
                    const inner = self.arg() orelse { try self.put(name); continue; };
                    var sub = Renderer{ .alloc = self.alloc, .src = inner };
                    try sub.run();
                    const text = try sub.out.toOwnedSlice(self.alloc);
                    defer self.alloc.free(text);
                    try self.put("√(");
                    try self.put(text);
                    try self.put(")");
                    continue;
                }
                if (std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "mathrm") or
                    std.mem.eql(u8, name, "mathbf") or std.mem.eql(u8, name, "mathit") or
                    std.mem.eql(u8, name, "operatorname"))
                {
                    if (self.group()) |g| try self.put(g);
                    continue;
                }
                if (std.mem.eql(u8, name, "left") or std.mem.eql(u8, name, "right") or
                    std.mem.eql(u8, name, "big") or std.mem.eql(u8, name, "Big") or
                    std.mem.eql(u8, name, "bigg") or std.mem.eql(u8, name, "Bigg"))
                {
                    // The delimiter after \left/\right renders as itself.
                    if (self.i < self.src.len) {
                        const d = self.src[self.i];
                        if (d == '.' ) { self.i += 1; continue; } // \left. / \right.
                        try self.put(self.src[self.i .. self.i + 1]);
                        self.i += 1;
                    }
                    continue;
                }
                if (std.mem.eql(u8, name, "begin") or std.mem.eql(u8, name, "end")) {
                    // \begin{env} / \end{env}: drop the environment name.
                    _ = self.group();
                    continue;
                }
                if (std.mem.eql(u8, name, "hat") or std.mem.eql(u8, name, "bar") or
                    std.mem.eql(u8, name, "vec") or std.mem.eql(u8, name, "tilde"))
                {
                    const inner = self.arg() orelse { try self.put(name); continue; };
                    var sub = Renderer{ .alloc = self.alloc, .src = inner };
                    try sub.run();
                    const text = try sub.out.toOwnedSlice(self.alloc);
                    defer self.alloc.free(text);
                    const accent: []const u8 = if (name[0] == 'h') "̄" else if (name[0] == 'v') "̃" else if (name[0] == 'a') "̂" else "⃗";
                    try self.put(text);
                    try self.put(accent);
                    continue;
                }
                if (std.mem.eql(u8, name, "lim")) {
                    try self.put("lim");
                    continue;
                }
                if (symbolFor(name)) |glyph| {
                    try self.put(glyph);
                    continue;
                }
                // Unknown command: keep the name without the backslash.
                try self.put(name);
                continue;
            }
            if (c == '^' or c == '_') {
                self.i += 1;
                const inner = self.arg() orelse continue;
                if (c == '^') {
                    try self.renderSub(inner, superscriptOf, "^");
                } else {
                    try self.renderSub(inner, subscriptOf, "_");
                }
                continue;
            }
            if (c == '{') {
                if (self.group()) |g| {
                    var sub = Renderer{ .alloc = self.alloc, .src = g };
                    try sub.run();
                    const text = try sub.out.toOwnedSlice(self.alloc);
                    defer self.alloc.free(text);
                    try self.put(text);
                }
                continue;
            }
            if (c == '}') {
                self.i += 1; // stray closing brace: drop
                continue;
            }
            if (c == '&') {
                try self.put("  "); // alignment separator (aligned/envs)
                self.i += 1;
                continue;
            }
            if (c == '\n') {
                try self.put(" ");
                self.i += 1;
                continue;
            }
            const end = std.mem.indexOfAnyPos(u8, self.src, self.i, &.{ '\\', '^', '_', '{', '}', '&', '\n' }) orelse self.src.len;
            try self.put(self.src[self.i..end]);
            self.i = end;
        }
    }
};

/// Convert LaTeX `src` to display text. Always succeeds (unknown constructs
/// degrade to readable text instead of failing, so callers rarely need the
/// raw fallback).
pub fn render(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var r = Renderer{ .alloc = alloc, .src = src };
    try r.run();
    return r.out.toOwnedSlice(alloc);
}

// ---- tests ----

const t = std.testing;

test "latex: greek and operators" {
    const out = try render(t.allocator, "\\alpha + \\beta \\leq \\infty");
    defer t.allocator.free(out);
    try t.expectEqualStrings("α + β ≤ ∞", out);
}

test "latex: frac and sqrt" {
    const out = try render(t.allocator, "\\frac{a+b}{c} \\sqrt{x+1}");
    defer t.allocator.free(out);
    try t.expectEqualStrings("(a+b)/(c) √(x+1)", out);
}

test "latex: super/subscripts" {
    const out = try render(t.allocator, "x^{2} + y_1 \\geq x^{n}");
    defer t.allocator.free(out);
    try t.expectEqualStrings("x² + y₁ ≥ xⁿ", out);
}

test "latex: unknown command keeps name" {
    const out = try render(t.allocator, "\\unknowncmd{x}");
    defer t.allocator.free(out);
    try t.expectEqualStrings("unknowncmdx", out);
}
