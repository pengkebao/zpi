//! Oklab / OKHSL / OKLCH ↔ sRGB conversion, ported from pi-tui's oklab.js
//! (itself a port of Björn Ottosson's reference implementation, MIT).
//!
//! OKHSL saturation is relative to the sRGB gamut at each hue and lightness,
//! which is what makes pi's theme colors render identically to its JS TUI.

const std = @import("std");

/// An sRGB color in 0-255 channels.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

const LINEAR_SRGB_TO_LMS = [_][3]f64{
    .{ 0.4122214694707629, 0.5363325372617349, 0.0514459932675022 },
    .{ 0.2119034958178251, 0.6806995506452344, 0.1073969535369405 },
    .{ 0.0883024591900564, 0.2817188391361215, 0.6299787016738222 },
};
const LMS_TO_LAB = [_][3]f64{
    .{ 0.210454268309314, 0.793617774702305, -0.0040720430116193 },
    .{ 1.9779985324311684, -2.42859224204858, 0.450593709617411 },
    .{ 0.0259040424655478, 0.7827717124575296, -0.8086757549230774 },
};
const LAB_TO_LMS = [_][3]f64{
    .{ 1, 0.3963377773761749, 0.2158037573099136 },
    .{ 1, -0.1055613458156586, -0.0638541728258133 },
    .{ 1, -0.0894841775298119, -1.2914855480194092 },
};
const LMS_TO_LINEAR_SRGB = [_][3]f64{
    .{ 4.0767416360759583, -3.3077115392580629, 0.2309699031821043 },
    .{ -1.2684379732850315, 2.6097573492876882, -0.341319376002657 },
    .{ -0.0041960761386756, -0.7034186179359362, 1.7076146940746117 },
};
const SATURATION_FIT = [_]struct { plane: [2]f64, poly: [5]f64 }{
    .{
        .plane = .{ -1.8817031, -0.80936501 },
        .poly = .{ 1.19086277, 1.76576728, 0.59662641, 0.75515197, 0.56771245 },
    },
    .{
        .plane = .{ 1.8144408, -1.19445267 },
        .poly = .{ 0.73956515, -0.45954404, 0.08285427, 0.12541073, -0.14503204 },
    },
    .{
        .plane = .{ 0.13110758, 1.81333971 },
        .poly = .{ 1.35733652, -0.00915799, -1.1513021, -0.50559606, 0.00692167 },
    },
};

/// Normalize a hue (degrees) into [0, 360).
fn normAngle(h: f64) f64 {
    return h - 360.0 * std.math.floor(h / 360.0);
}

const K1: f64 = 0.206;
const K2: f64 = 0.03;
const K3: f64 = (1 + K1) / (1 + K2);

fn linearToSrgb(v: f64) f64 {
    return if (v > 0.0031308) 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055 else 12.92 * v;
}

fn matVec(m: [3][3]f64, v: [3]f64) [3]f64 {
    var out: [3]f64 = undefined;
    for (0..3) |i| {
        out[i] = m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2];
    }
    return out;
}

fn oklabToLinearSrgb(lab: [3]f64) [3]f64 {
    var lms = matVec(LAB_TO_LMS, lab);
    // cube each LMS component
    for (&lms) |*v| v.* = v.* * v.* * v.*;
    return matVec(LMS_TO_LINEAR_SRGB, lms);
}

fn linearSrgbToRgb(linear: [3]f64) Rgb {
    var ch: [3]u8 = undefined;
    for (0..3) |i| {
        var v = linearToSrgb(linear[i]);
        v = @min(@max(v, 0.0), 1.0);
        ch[i] = @intFromFloat(@as(f64, @round(v * 255.0)));
    }
    return .{ .r = ch[0], .g = ch[1], .b = ch[2] };
}

fn lmsSlopes(a: f64, b: f64) [3]f64 {
    var out: [3]f64 = undefined;
    for (0..3) |i| out[i] = LAB_TO_LMS[i][1] * a + LAB_TO_LMS[i][2] * b;
    return out;
}

fn maxSaturation(a: f64, b: f64) f64 {
    var channel: usize = 2;
    for (0..3) |i| {
        const plane = SATURATION_FIT[i].plane;
        if (i == 2 or plane[0] * a + plane[1] * b > 1) {
            channel = i;
            break;
        }
    }
    const poly = SATURATION_FIT[channel].poly;
    const weights = LMS_TO_LINEAR_SRGB[channel];
    const saturation = poly[0] + poly[1] * a + poly[2] * b + poly[3] * a * a + poly[4] * a * b;
    const slopes = lmsSlopes(a, b);
    var base: [3]f64 = undefined;
    for (0..3) |i| base[i] = 1 + saturation * slopes[i];
    // f = Σ weights[i]·base[i]³
    var f: f64 = 0;
    var f1: f64 = 0;
    var f2: f64 = 0;
    for (0..3) |i| {
        f += weights[i] * base[i] * base[i] * base[i];
        f1 += weights[i] * 3 * slopes[i] * base[i] * base[i];
        f2 += weights[i] * 6 * slopes[i] * slopes[i] * base[i];
    }
    return saturation - (f * f1) / (f1 * f1 - 0.5 * f * f2);
}

fn cusp(a: f64, b: f64) [2]f64 {
    const saturation = maxSaturation(a, b);
    const lin = oklabToLinearSrgb(.{ 1, saturation * a, saturation * b });
    var mx: f64 = lin[0];
    if (lin[1] > mx) mx = lin[1];
    if (lin[2] > mx) mx = lin[2];
    const lightness = std.math.cbrt(1.0 / mx);
    return .{ lightness, lightness * saturation };
}

fn maxChroma(a: f64, b: f64, lightness: f64, peak: [2]f64) f64 {
    const cuspL = peak[0];
    const cuspC = peak[1];
    if (lightness <= cuspL) return (cuspC * lightness) / cuspL;
    const t = (cuspC * (lightness - 1)) / (cuspL - 1);
    const slopes = lmsSlopes(a, b);
    var lms: [3]f64 = undefined;
    var cubes: [3]f64 = undefined;
    var first: [3]f64 = undefined;
    var second: [3]f64 = undefined;
    for (0..3) |i| {
        lms[i] = lightness + t * slopes[i];
        cubes[i] = lms[i] * lms[i] * lms[i];
        first[i] = 3 * slopes[i] * lms[i] * lms[i];
        second[i] = 6 * slopes[i] * slopes[i] * lms[i];
    }
    var min_step: f64 = std.math.inf(f64);
    for (LMS_TO_LINEAR_SRGB) |row| {
        var f: f64 = 0;
        var f1: f64 = 0;
        var f2: f64 = 0;
        for (0..3) |i| {
            f += row[i] * cubes[i];
            f1 += row[i] * first[i];
            f2 += row[i] * second[i];
        }
        f -= 1; // (dot(row, cubes) - 1)
        const u = f1 / (f1 * f1 - 0.5 * f * f2);
        const step = if (u >= 0) -f * u else std.math.inf(f64);
        if (step < min_step) min_step = step;
    }
    return t + min_step;
}

fn chromaStops(L: f64, a: f64, b: f64) [3]f64 {
    const peak = cusp(a, b);
    const cMax = maxChroma(a, b, L, peak);
    const denom = @min(L * (peak[1] / peak[0]), (1 - L) * (peak[1] / (1 - peak[0])));
    const k = cMax / denom;
    const midS: f64 = 0.11516993 + 1.0 /
        (7.4477897 +
            4.1590124 * b +
            a * (-2.19557347 +
                1.75198401 * b +
                a * (-2.13704948 - 10.02301043 * b + a * (-4.24894561 + 5.38770819 * b + 4.69891013 * a))));
    const midT: f64 = 0.11239642 + 1.0 /
        (1.6132032 -
            0.68124379 * b +
            a * (0.40370612 +
                0.90148123 * b +
                a * (-0.27087943 + 0.6122399 * b + a * (0.00299215 - 0.45399568 * b - 0.14661872 * a))));
    const a1 = 1.0 / ((L * midS) * (L * midS) * (L * midS) * (L * midS));
    const a2 = 1.0 / (((1 - L) * midT) * ((1 - L) * midT) * ((1 - L) * midT) * ((1 - L) * midT));
    const cMid = 0.9 * k * std.math.sqrt(std.math.sqrt(1.0 / (a1 + a2)));
    const b1 = 1.0 / ((L * 0.4) * (L * 0.4));
    const b2 = 1.0 / (((1 - L) * 0.8) * ((1 - L) * 0.8));
    const c0 = std.math.sqrt(1.0 / (b1 + b2));
    return .{ c0, cMid, cMax };
}

fn okhslToOklabLightness(x: f64) f64 {
    return (x * x + K1 * x) / (K3 * (x + K2));
}

/// Convert OKHSL to sRGB channels (0-255, rounded), clipping out-of-gamut
/// channels. `hue` in degrees, `saturation` and `lightness` in 0-1.
pub fn okhslToRgb(hue: f64, saturation: f64, lightness: f64) Rgb {
    const L = okhslToOklabLightness(lightness);
    var lab: [3]f64 = .{ L, 0, 0 };
    if (L > 0 and L < 1 and saturation > 0) {
        const angle = (2 * std.math.pi * normAngle(hue)) / 360;
        const a = std.math.cos(angle);
        const b = std.math.sin(angle);
        const stops = chromaStops(L, a, b);
        const c0 = stops[0];
        const cMid = stops[1];
        const cMax = stops[2];
        var chroma: f64 = 0;
        if (saturation < 0.8) {
            const t = 1.25 * saturation;
            const k1 = 0.8 * c0;
            chroma = (t * k1) / (1 - (1 - k1 / cMid) * t);
        } else {
            const t = 5 * (saturation - 0.8);
            const k1 = (0.2 * cMid * cMid * 1.25 * 1.25) / c0;
            chroma = cMid + (t * k1) / (1 - (1 - k1 / (cMax - cMid)) * t);
        }
        lab = .{ L, chroma * a, chroma * b };
    }
    return linearSrgbToRgb(oklabToLinearSrgb(lab));
}

/// Convert OKLCH to sRGB channels. `l` and `c` in 0-1-ish, `h` in degrees.
pub fn oklchToRgb(l: f64, c: f64, h: f64) Rgb {
    const angle = (2 * std.math.pi * normAngle(h)) / 360;
    const a = c * std.math.cos(angle);
    const b = c * std.math.sin(angle);
    return linearSrgbToRgb(oklabToLinearSrgb(.{ l, a, b }));
}

test "okhslToRgb matches pi-tui reference values" {
    // pi dark theme: border okhsl(231 57% 65%) → rgb(95,168,204)
    const border = okhslToRgb(231, 0.57, 0.65);
    try std.testing.expectEqual(@as(u8, 95), border.r);
    try std.testing.expectEqual(@as(u8, 168), border.g);
    try std.testing.expectEqual(@as(u8, 204), border.b);
    // error red okhsl(20 72% 67%) → rgb(234,127,129)
    const red = okhslToRgb(20, 0.72, 0.67);
    try std.testing.expectEqual(@as(u8, 234), red.r);
    try std.testing.expectEqual(@as(u8, 127), red.g);
    try std.testing.expectEqual(@as(u8, 129), red.b);
    // dim okhsl(229 8% 56%) → rgb(126,136,142)
    const dim = okhslToRgb(229, 0.08, 0.56);
    try std.testing.expectEqual(@as(u8, 126), dim.r);
    try std.testing.expectEqual(@as(u8, 136), dim.g);
    try std.testing.expectEqual(@as(u8, 142), dim.b);
}

test "okhslToRgb gray (saturation 0)" {
    // pi-tui: okhsl(0 0% 50%) → rgb(119,119,119)
    const g = okhslToRgb(0, 0, 0.5);
    try std.testing.expectEqual(@as(u8, 119), g.r);
    try std.testing.expect(g.r == g.g and g.g == g.b);
}


