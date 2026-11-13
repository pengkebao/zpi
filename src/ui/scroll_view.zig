//! Vertical scroll state of the transcript (pi: components/scroll-view.js),
//! its scrollbar geometry (pi: layout.js getScrollbarGeometry) and the wheel
//! accelerator (pi: wheel-scroll.js).
//!
//! Pure state: nothing here renders or reads the clock. Callers pass the
//! current time in milliseconds where pi would arm a timer, and repaint when
//! `tick` reports that the transient scrollbar just hid.

const std = @import("std");

/// pi: ScrollViewScrollbar. `auto` shows the scrollbar only while the content
/// overflows and there was recent scroll activity; `always` reserves a column.
pub const Scrollbar = enum { hidden, auto, always };

pub const ScrollView = struct {
    /// Stay pinned to the end while the content grows (pi: follow "end").
    follow_end: bool = true,
    scrollbar: Scrollbar = .auto,
    /// How long an `auto` scrollbar stays visible after the last activity.
    hide_delay_ms: i64 = 1000,

    /// First visible content row.
    scroll_top: usize = 0,
    content_height: usize = 0,
    viewport_height: usize = 0,
    following_end: bool = true,
    /// A reveal (search) landed on the bottom and must not re-arm following.
    follow_suppressed_at_end: bool = false,

    transient_visible: bool = false,
    /// Hovered or dragged: the scrollbar stays visible and the thumb is solid.
    active: bool = false,
    /// When the transient scrollbar hides; null while active or already hidden.
    hide_at_ms: ?i64 = null,

    pub const ScrollToOptions = struct {
        /// Landing on the bottom must not resume following (search reveal).
        disable_follow: bool = false,
        /// Pointer navigation (scrollbar press/drag): a target within one
        /// track-row quantum of the end resolves to the end itself, so a
        /// hand resting at the bottom edge holds the end while the stream
        /// grows the document instead of jittering around it.
        snap_end: bool = false,
    };

    pub fn init(follow_end: bool, scrollbar: Scrollbar) ScrollView {
        return .{ .follow_end = follow_end, .following_end = follow_end, .scrollbar = scrollbar };
    }

    pub fn maxScrollTop(self: *const ScrollView) usize {
        return self.content_height -| self.viewport_height;
    }

    pub fn isFollowingEnd(self: *const ScrollView) bool {
        return self.following_end;
    }

    pub fn isScrollbarVisible(self: *const ScrollView) bool {
        return switch (self.scrollbar) {
            .always => self.viewport_height > 0,
            .auto => self.content_height > self.viewport_height and self.transient_visible,
            .hidden => false,
        };
    }

    pub fn setScrollbar(self: *ScrollView, mode: Scrollbar, now_ms: i64) void {
        if (mode == self.scrollbar) return;
        self.scrollbar = mode;
        if (mode != .auto) {
            self.hideTransient();
        } else if (self.active) {
            self.markActivity(now_ms);
        }
    }

    /// Width left for the content: `always` owns the last column.
    pub fn contentWidth(self: *const ScrollView, width: usize) usize {
        return if (self.scrollbar == .always and width > 1) width - 1 else width;
    }

    /// Scroll activity: show the `auto` scrollbar and (re)arm its hide deadline.
    pub fn markActivity(self: *ScrollView, now_ms: i64) void {
        if (self.scrollbar != .auto or self.content_height <= self.viewport_height) return;
        self.transient_visible = true;
        // While hovered or dragged it stays up; the deadline starts on release.
        self.hide_at_ms = if (self.active) null else now_ms + self.hide_delay_ms;
    }

    fn hideTransient(self: *ScrollView) void {
        self.transient_visible = false;
        self.hide_at_ms = null;
    }

    /// Hover/drag state. Returns true when it changed (repaint: the thumb glyph
    /// differs and an `auto` scrollbar becomes visible).
    pub fn setActive(self: *ScrollView, active: bool, now_ms: i64) bool {
        if (active == self.active) return false;
        self.active = active;
        self.markActivity(now_ms);
        return true;
    }

    /// Expire the hide deadline. Returns true when the scrollbar just hid.
    pub fn tick(self: *ScrollView, now_ms: i64) bool {
        const at = self.hide_at_ms orelse return false;
        if (now_ms < at) return false;
        self.hide_at_ms = null;
        if (!self.transient_visible) return false;
        self.transient_visible = false;
        return true;
    }

    /// Scroll to an absolute row, clamped. Returns true when anything changed.
    pub fn scrollTo(self: *ScrollView, requested: isize, options: ScrollToOptions, now_ms: i64) bool {
        const max = self.maxScrollTop();
        var next: usize = if (requested <= 0) 0 else @min(max, @as(usize, @intCast(requested)));
        if (options.snap_end and requested > 0 and max > 0 and next >= max -| self.pointerQuantum()) {
            next = max;
        }
        const next_suppressed = options.disable_follow and next == max;
        const next_following = !next_suppressed and self.follow_end and next == max;
        if (next == self.scroll_top and
            next_following == self.following_end and
            next_suppressed == self.follow_suppressed_at_end)
        {
            return false;
        }
        const moved = next != self.scroll_top;
        self.scroll_top = next;
        self.following_end = next_following;
        self.follow_suppressed_at_end = next_suppressed;
        if (moved) self.markActivity(now_ms);
        return true;
    }

    /// A downward scroll landing this close to the end snaps to it and
    /// re-engages following. While a turn streams, the end recedes with every
    /// chunk; without the snap a small wheel step would land 1-2 rows short,
    /// leaving follow disengaged and the jump hint flashing on each event.
    const SNAP_TO_END_WITHIN: usize = 2;

    /// Scroll by `lines` rows (negative = towards the start). Returns the part
    /// of the request that could not be applied (pi chains it to a parent).
    pub fn scrollBy(self: *ScrollView, lines: isize, now_ms: i64) isize {
        if (lines == 0) return 0;
        const max = self.maxScrollTop();
        // While following, the view is at the end whatever scroll_top says.
        const start: usize = if (self.following_end) max else self.scroll_top;
        var next: usize = blk: {
            if (lines < 0) {
                const up: usize = @intCast(-lines);
                break :blk start -| up;
            }
            break :blk @min(max, start +| @as(usize, @intCast(lines)));
        };
        if (lines > 0 and max > 0 and next >= max -| SNAP_TO_END_WITHIN) next = max;
        const moved: isize = @as(isize, @intCast(next)) - @as(isize, @intCast(start));
        self.scroll_top = next;
        self.following_end = self.follow_end and next == max;
        self.follow_suppressed_at_end = false;
        if (moved != 0) self.markActivity(now_ms);
        return lines - moved;
    }

    pub fn scrollToStart(self: *ScrollView, now_ms: i64) void {
        // Content that fits is at its end as well: following stays armed.
        const following = self.follow_end and self.content_height <= self.viewport_height;
        const changed = self.scroll_top != 0 or self.following_end != following;
        self.scroll_top = 0;
        self.following_end = following;
        self.follow_suppressed_at_end = false;
        if (changed) self.markActivity(now_ms);
    }

    pub fn scrollToEnd(self: *ScrollView, now_ms: i64) void {
        const next = self.maxScrollTop();
        const changed = self.scroll_top != next or self.following_end != self.follow_end;
        self.scroll_top = next;
        self.following_end = self.follow_end;
        self.follow_suppressed_at_end = false;
        if (changed) self.markActivity(now_ms);
    }

    /// Doc rows per track row of thumb travel — the pointer mapping's
    /// granularity. One track row of hand jitter maps to this many doc rows,
    /// so targets closer than this to the end ARE the end (snap_end).
    fn pointerQuantum(self: *const ScrollView) usize {
        const track = self.viewport_height;
        if (track == 0) return 1;
        const content = self.content_height;
        const min_thumb: usize = @min(2, track);
        const ideal: usize = if (content == 0) track else jsRound(
            @as(f64, @floatFromInt(track * track)) / @as(f64, @floatFromInt(content)),
        );
        const thumb = @max(min_thumb, @min(track, ideal));
        const max_thumb_offset = track - thumb;
        const max = self.maxScrollTop();
        if (max_thumb_offset == 0 or max == 0) return 1;
        return @intFromFloat(@ceil(@as(f64, @floatFromInt(max)) / @as(f64, @floatFromInt(max_thumb_offset))));
    }

    /// Feed the measured content and viewport heights (every frame). Following
    /// pins the view to the end as the content grows; otherwise the top row
    /// stays where it is, so new content below never moves the viewport.
    pub fn updateLayout(self: *ScrollView, content_height: usize, viewport_height: usize) void {
        self.content_height = content_height;
        self.viewport_height = viewport_height;
        const max = self.maxScrollTop();
        if (self.following_end) {
            self.scroll_top = max;
        } else {
            self.scroll_top = @min(self.scroll_top, max);
        }
        if (self.scroll_top < max) self.follow_suppressed_at_end = false;
        if (self.follow_end and self.scroll_top == max and !self.follow_suppressed_at_end) {
            self.following_end = true;
        }
        if (self.content_height <= self.viewport_height) self.hideTransient();
    }

    /// Scrollbar track and thumb, in rows relative to the top of the viewport.
    pub const Geometry = struct {
        track_height: usize,
        /// Thumb offset from the top of the track.
        thumb_top: usize,
        thumb_height: usize,
        max_scroll_top: usize,

        pub fn onThumb(self: Geometry, row: usize) bool {
            return row >= self.thumb_top and row < self.thumb_top + self.thumb_height;
        }
    };

    /// The scrollbar to paint, or null when none is shown. `include_hidden_auto`
    /// also measures an `auto` scrollbar that is currently hidden but would
    /// appear on hover (pi: getScrollbarGeometry(box, includeHiddenAuto)).
    pub fn geometry(self: *const ScrollView, include_hidden_auto: bool) ?Geometry {
        const track = self.viewport_height;
        if (track == 0) return null;
        const content = self.content_height;
        const can_reveal = include_hidden_auto and self.scrollbar == .auto and content > track;
        if (!self.isScrollbarVisible() and !can_reveal) return null;

        const min_thumb: usize = @min(2, track);
        // Math.round((track * track) / content); empty content fills the track.
        const ideal: usize = if (content == 0) track else jsRound(
            @as(f64, @floatFromInt(track * track)) / @as(f64, @floatFromInt(content)),
        );
        const thumb = @max(min_thumb, @min(track, ideal));
        const max_scroll_top = content -| track;
        const max_thumb_top = track - thumb;
        const offset: usize = if (max_scroll_top == 0) 0 else jsRound(
            (@as(f64, @floatFromInt(self.scroll_top)) / @as(f64, @floatFromInt(max_scroll_top))) *
                @as(f64, @floatFromInt(max_thumb_top)),
        );
        return .{
            .track_height = track,
            .thumb_top = @min(offset, max_thumb_top),
            .thumb_height = thumb,
            .max_scroll_top = max_scroll_top,
        };
    }

    /// The scroll position that puts the thumb's grabbed cell under the
    /// pointer (pi: scrollScrollbarToPointer). `pointer_row` is relative to the
    /// top of the track and may lie outside it while dragging.
    pub fn scrollTopForPointer(geom: Geometry, pointer_row: isize, grab_offset: usize) usize {
        const max_thumb_offset = geom.track_height - geom.thumb_height;
        if (max_thumb_offset == 0) return 0;
        const wanted = pointer_row - @as(isize, @intCast(grab_offset));
        const thumb_offset: usize = if (wanted <= 0) 0 else @min(max_thumb_offset, @as(usize, @intCast(wanted)));
        return jsRound(
            (@as(f64, @floatFromInt(thumb_offset)) / @as(f64, @floatFromInt(max_thumb_offset))) *
                @as(f64, @floatFromInt(geom.max_scroll_top)),
        );
    }
};

/// JavaScript's Math.round for non-negative values: halves round up.
fn jsRound(x: f64) usize {
    return @intFromFloat(@floor(x + 0.5));
}

/// pi: WheelScrollLines — a fixed line count per wheel event, or `auto`.
pub const WheelLines = union(enum) {
    auto,
    fixed: usize,
};

/// Converts wheel events into line counts (pi: WheelScrollAccelerator).
///
/// In `auto` mode on terminals that do not accelerate wheel input themselves,
/// the count follows event velocity: an isolated notch moves one line, a fast
/// spin up to six per event (notches 100 ms apart move 1 line each, 50 ms
/// apart 2, 20 ms apart 5).
pub const WheelScrollAccelerator = struct {
    lines: WheelLines = .auto,
    /// False where the terminal already delivers accelerated, per-line events
    /// (a local macOS terminal): every event is then exactly one line.
    accelerate: bool = true,
    last_time: ?f64 = null,
    last_direction: i8 = 0,
    average_gap: ?f64 = null,
    carry: f64 = 0,

    // Events closer than this belong to one physical notch (Ghostty emits them
    // ~4 ms apart) or come from a high-resolution source: one line each.
    const BURST_GAP_MS: f64 = 5;
    // A pause longer than this ends a scroll gesture.
    const GESTURE_GAP_MS: f64 = 200;
    // Average event gap that maps to one line per event.
    const REFERENCE_GAP_MS: f64 = 100;
    const MAX_AUTO_LINES: f64 = 6;

    /// Whether the terminal pre-accelerates the wheel: local macOS only. Over
    /// SSH the client platform is unknown, so events are treated as notches.
    pub fn terminalAcceleratesWheel(is_macos: bool, over_ssh: bool) bool {
        return is_macos and !over_ssh;
    }

    pub fn reset(self: *WheelScrollAccelerator) void {
        self.last_time = null;
        self.last_direction = 0;
        self.average_gap = null;
        self.carry = 0;
    }

    /// The positive line count for a wheel event in `direction` (-1 up, +1
    /// down) at time `now_ms`.
    pub fn next(self: *WheelScrollAccelerator, direction: i8, now_ms: f64) usize {
        switch (self.lines) {
            .fixed => |n| return @max(1, n),
            .auto => {},
        }
        if (!self.accelerate) return 1;
        const same_gesture = if (self.last_time) |last|
            direction == self.last_direction and now_ms - last <= GESTURE_GAP_MS
        else
            false;
        const gap: f64 = if (self.last_time) |last| now_ms - last else 0;
        self.last_time = now_ms;
        self.last_direction = direction;
        if (!same_gesture) {
            self.average_gap = null;
            self.carry = 0;
            return 1;
        }
        if (gap < BURST_GAP_MS) return 1;
        const avg = if (self.average_gap) |a| (a + gap) / 2 else gap;
        self.average_gap = avg;
        const lines = @min(MAX_AUTO_LINES, @max(1, REFERENCE_GAP_MS / avg)) + self.carry;
        const whole = @floor(lines);
        self.carry = lines - whole;
        return @intFromFloat(whole);
    }
};

// ---- tests ----

const t = std.testing;

test "ScrollView follows the end while content grows" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(5, 10);
    try t.expectEqual(@as(usize, 0), sv.scroll_top); // fits: nothing to scroll
    try t.expect(sv.isFollowingEnd());
    sv.updateLayout(30, 10);
    try t.expectEqual(@as(usize, 20), sv.scroll_top); // pinned to the end
    sv.updateLayout(45, 10);
    try t.expectEqual(@as(usize, 35), sv.scroll_top);
    try t.expect(sv.isFollowingEnd());
}

test "ScrollView scrolled up stays put when content grows" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    try t.expectEqual(@as(isize, 0), sv.scrollBy(-30, 0));
    try t.expectEqual(@as(usize, 60), sv.scroll_top);
    try t.expect(!sv.isFollowingEnd());
    // New content below: the top row does not move (the viewport is anchored).
    sv.updateLayout(140, 10);
    try t.expectEqual(@as(usize, 60), sv.scroll_top);
    try t.expect(!sv.isFollowingEnd());
}

test "ScrollView scrollBy clamps at both ends and reports the leftover" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    // Following: a scroll down has nowhere to go.
    try t.expectEqual(@as(isize, 5), sv.scrollBy(5, 0));
    try t.expectEqual(@as(usize, 90), sv.scroll_top);
    try t.expect(sv.isFollowingEnd());
    // Up past the start: clamped, leftover reported.
    try t.expectEqual(@as(isize, -10), sv.scrollBy(-100, 0));
    try t.expectEqual(@as(usize, 0), sv.scroll_top);
    try t.expect(!sv.isFollowingEnd());
    // Back down to the end re-arms following.
    try t.expectEqual(@as(isize, 0), sv.scrollBy(90, 0));
    try t.expectEqual(@as(usize, 90), sv.scroll_top);
    try t.expect(sv.isFollowingEnd());
    try t.expectEqual(@as(isize, 0), sv.scrollBy(0, 0));
}

test "ScrollView scrollBy from following starts at the end" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    // A stale scroll_top must not matter while following.
    sv.scroll_top = 3;
    _ = sv.scrollBy(-4, 0);
    try t.expectEqual(@as(usize, 86), sv.scroll_top);
}

test "ScrollView scrollTo clamps and re-arms following at the end" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    try t.expect(sv.scrollTo(40, .{}, 0));
    try t.expectEqual(@as(usize, 40), sv.scroll_top);
    try t.expect(!sv.isFollowingEnd());
    try t.expect(!sv.scrollTo(40, .{}, 0)); // no change
    try t.expect(sv.scrollTo(-7, .{}, 0));
    try t.expectEqual(@as(usize, 0), sv.scroll_top);
    try t.expect(sv.scrollTo(5000, .{}, 0));
    try t.expectEqual(@as(usize, 90), sv.scroll_top);
    try t.expect(sv.isFollowingEnd());
}

test "ScrollView disable_follow at the end suppresses following until it leaves" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    _ = sv.scrollBy(-50, 0);
    // A search reveal that lands exactly on the last page.
    try t.expect(sv.scrollTo(90, .{ .disable_follow = true }, 0));
    try t.expectEqual(@as(usize, 90), sv.scroll_top);
    try t.expect(!sv.isFollowingEnd());
    try t.expect(sv.follow_suppressed_at_end);
    // Growth keeps the top row: it is no longer the end, suppression clears.
    sv.updateLayout(120, 10);
    try t.expectEqual(@as(usize, 90), sv.scroll_top);
    try t.expect(!sv.follow_suppressed_at_end);
    try t.expect(!sv.isFollowingEnd());
    // Reaching the end normally follows again.
    _ = sv.scrollBy(1000, 0);
    try t.expect(sv.isFollowingEnd());
    sv.updateLayout(150, 10);
    try t.expectEqual(@as(usize, 140), sv.scroll_top);
}

test "ScrollView suppressed at the end stays put on the same layout" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    _ = sv.scrollBy(-50, 0);
    _ = sv.scrollTo(90, .{ .disable_follow = true }, 0);
    sv.updateLayout(100, 10);
    try t.expect(!sv.isFollowingEnd()); // still suppressed: not re-armed
}

test "ScrollView start and end jumps" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    sv.scrollToStart(0);
    try t.expectEqual(@as(usize, 0), sv.scroll_top);
    try t.expect(!sv.isFollowingEnd());
    sv.scrollToEnd(0);
    try t.expectEqual(@as(usize, 90), sv.scroll_top);
    try t.expect(sv.isFollowingEnd());
    // Content that fits: the start is also the end, following stays armed.
    sv.updateLayout(4, 10);
    sv.scrollToStart(0);
    try t.expect(sv.isFollowingEnd());
}

test "ScrollView shrinking content clamps the top row" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    _ = sv.scrollBy(-10, 0); // top 80
    sv.updateLayout(50, 10); // max 40
    try t.expectEqual(@as(usize, 40), sv.scroll_top);
    try t.expect(sv.isFollowingEnd()); // landed on the end
}

test "ScrollView without follow never pins to the end" {
    var sv = ScrollView.init(false, .hidden);
    sv.updateLayout(100, 10);
    try t.expectEqual(@as(usize, 0), sv.scroll_top);
    _ = sv.scrollBy(1000, 0);
    try t.expectEqual(@as(usize, 90), sv.scroll_top);
    try t.expect(!sv.isFollowingEnd());
    sv.updateLayout(130, 10);
    try t.expectEqual(@as(usize, 90), sv.scroll_top);
}

test "auto scrollbar shows on activity and hides after the delay" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    try t.expect(!sv.isScrollbarVisible()); // no activity yet
    _ = sv.scrollBy(-5, 1000);
    try t.expect(sv.isScrollbarVisible());
    try t.expect(!sv.tick(1999));
    try t.expect(sv.isScrollbarVisible());
    try t.expect(sv.tick(2000)); // just hid: repaint
    try t.expect(!sv.isScrollbarVisible());
    try t.expect(!sv.tick(5000));
    // A scroll that does not move shows nothing.
    sv.scrollToEnd(6000);
    _ = sv.tick(8000);
    _ = sv.scrollBy(3, 9000); // already at the end
    try t.expect(!sv.isScrollbarVisible());
}

test "auto scrollbar stays up while hovered, then hides after the delay" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    try t.expect(sv.setActive(true, 0));
    try t.expect(!sv.setActive(true, 0));
    try t.expect(sv.isScrollbarVisible());
    try t.expect(!sv.tick(60_000)); // no deadline while active
    try t.expect(sv.isScrollbarVisible());
    try t.expect(sv.setActive(false, 60_000));
    try t.expect(!sv.tick(60_999));
    try t.expect(sv.tick(61_000));
    try t.expect(!sv.isScrollbarVisible());
}

test "scrollbar modes and content that fits" {
    var sv = ScrollView.init(true, .always);
    sv.updateLayout(5, 10);
    try t.expect(sv.isScrollbarVisible()); // always: even when it fits
    try t.expectEqual(@as(usize, 79), sv.contentWidth(80));
    try t.expectEqual(@as(usize, 1), sv.contentWidth(1));
    sv.setScrollbar(.hidden, 0);
    try t.expect(!sv.isScrollbarVisible());
    try t.expectEqual(@as(usize, 80), sv.contentWidth(80));
    sv.setScrollbar(.auto, 0);
    _ = sv.scrollBy(-1, 0); // fits: no activity to show
    try t.expect(!sv.isScrollbarVisible());
    // Overflow shown, then the content shrinks to fit: hidden at once.
    sv.updateLayout(100, 10);
    _ = sv.scrollBy(-5, 0);
    try t.expect(sv.isScrollbarVisible());
    sv.updateLayout(6, 10);
    try t.expect(!sv.isScrollbarVisible());
    try t.expect(sv.hide_at_ms == null);
}

test "scrollbar geometry matches pi's formulas" {
    var sv = ScrollView.init(true, .always);
    sv.updateLayout(100, 10);
    // thumb = max(2, min(10, round(100/100))) = 2; following: offset = 8.
    var g = sv.geometry(false).?;
    try t.expectEqual(@as(usize, 10), g.track_height);
    try t.expectEqual(@as(usize, 2), g.thumb_height);
    try t.expectEqual(@as(usize, 8), g.thumb_top);
    try t.expectEqual(@as(usize, 90), g.max_scroll_top);
    try t.expect(g.onThumb(8) and g.onThumb(9) and !g.onThumb(7));
    // Half way: round(45/90 * 8) = 4.
    _ = sv.scrollTo(45, .{}, 0);
    g = sv.geometry(false).?;
    try t.expectEqual(@as(usize, 4), g.thumb_top);
    // Top.
    sv.scrollToStart(0);
    try t.expectEqual(@as(usize, 0), sv.geometry(false).?.thumb_top);
    // Twice the viewport: thumb = round(400/40) = 10 of 20.
    sv.updateLayout(40, 20);
    g = sv.geometry(false).?;
    try t.expectEqual(@as(usize, 10), g.thumb_height);
    // Content that fits fills the track.
    sv.updateLayout(3, 20);
    g = sv.geometry(false).?;
    try t.expectEqual(@as(usize, 20), g.thumb_height);
    try t.expectEqual(@as(usize, 0), g.thumb_top);
    // A one-row viewport still has a one-row thumb.
    sv.updateLayout(50, 1);
    try t.expectEqual(@as(usize, 1), sv.geometry(false).?.thumb_height);
}

test "scrollbar geometry: hidden auto is measurable for hover only" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(100, 10);
    try t.expect(sv.geometry(false) == null); // hidden: nothing to paint
    try t.expect(sv.geometry(true) != null); // but hovering can reveal it
    sv.updateLayout(5, 10);
    try t.expect(sv.geometry(true) == null); // nothing overflows
    var hidden = ScrollView.init(true, .hidden);
    hidden.updateLayout(100, 10);
    try t.expect(hidden.geometry(true) == null);
}

test "pointer to scroll position inverts the geometry" {
    const g: ScrollView.Geometry = .{ .track_height = 10, .thumb_top = 0, .thumb_height = 2, .max_scroll_top = 90 };
    // Thumb top at row 4 of 8 possible offsets: round(4/8 * 90) = 45.
    try t.expectEqual(@as(usize, 45), ScrollView.scrollTopForPointer(g, 5, 1));
    try t.expectEqual(@as(usize, 0), ScrollView.scrollTopForPointer(g, -3, 1)); // above the track
    try t.expectEqual(@as(usize, 90), ScrollView.scrollTopForPointer(g, 40, 0)); // below it
    try t.expectEqual(@as(usize, 90), ScrollView.scrollTopForPointer(g, 9, 1));
    // A thumb that fills the track cannot move.
    const full: ScrollView.Geometry = .{ .track_height = 5, .thumb_top = 0, .thumb_height = 5, .max_scroll_top = 0 };
    try t.expectEqual(@as(usize, 0), ScrollView.scrollTopForPointer(full, 3, 0));
}

test "pointer drag at the bottom edge snaps to the end (no hint flicker)" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(4000, 25);
    const max = sv.maxScrollTop(); // 3975
    try t.expect(max > 1000);
    // Track quantum: thumb 2 rows in a 25-row track, 23 offsets -> ceil(3975/23).
    const quantum = (max + 21) / 22; // >= ceil(max/23)
    // A drag target one track row short of the end is within the quantum.
    const short_target = max - (quantum / 2);
    _ = sv.scrollTo(@intCast(short_target), .{ .snap_end = true }, 0);
    try t.expectEqual(max, sv.scroll_top);
    try t.expect(sv.isFollowingEnd()); // the hint stays off at the bottom edge
    // Targets well short of the end keep their position (honest scroll).
    sv.scrollToEnd(0);
    _ = sv.scrollTo(@intCast(max -| quantum * 3), .{ .snap_end = true }, 0);
    try t.expect(sv.scroll_top < max);
    try t.expect(!sv.isFollowingEnd());
    // Plain (non-pointer) navigation is untouched: search reveal stays exact.
    var sv2 = ScrollView.init(true, .auto);
    sv2.updateLayout(4000, 25);
    _ = sv2.scrollTo(@intCast(max -| 1), .{ .disable_follow = true }, 0);
    try t.expectEqual(max - 1, sv2.scroll_top);
    try t.expect(!sv2.isFollowingEnd());
}

test "held at the bottom edge during growth keeps following engaged" {
    var sv = ScrollView.init(true, .auto);
    sv.updateLayout(500, 25);
    sv.scrollToEnd(0);
    // The stream grows the document while the thumb rests at the bottom edge;
    // each pointer re-target lands within a quantum of the (moved) end.
    var top: isize = @intCast(sv.maxScrollTop());
    var grown: usize = 500;
    while (grown < 900) : (grown += 100) {
        sv.updateLayout(grown, 25);
        // Pointer still at the bottom edge: target recomputes, snaps to end.
        const max = sv.maxScrollTop();
        const quantum = (max + 21) / 22;
        top = @intCast(max -| quantum / 2);
        _ = sv.scrollTo(top, .{ .snap_end = true }, 0);
        try t.expect(sv.isFollowingEnd());
        try t.expectEqual(max, sv.scroll_top);
    }
}

test "wheel accelerator follows event velocity" {
    var w = WheelScrollAccelerator{};
    // An isolated notch moves one line.
    try t.expectEqual(@as(usize, 1), w.next(1, 0));
    // Notches 100 ms apart: one line each.
    try t.expectEqual(@as(usize, 1), w.next(1, 100));
    try t.expectEqual(@as(usize, 1), w.next(1, 200));

    w.reset();
    _ = w.next(1, 0);
    try t.expectEqual(@as(usize, 2), w.next(1, 50)); // 50 ms apart
    w.reset();
    _ = w.next(1, 0);
    try t.expectEqual(@as(usize, 5), w.next(1, 20)); // 20 ms apart
    w.reset();
    _ = w.next(1, 0);
    try t.expectEqual(@as(usize, 6), w.next(1, 10)); // capped at six
}

test "wheel accelerator carries fractions and resets on a new gesture" {
    var w = WheelScrollAccelerator{};
    _ = w.next(-1, 0);
    // 40 ms gaps are 2.5 lines per event: 2, then 3 with the carry.
    try t.expectEqual(@as(usize, 2), w.next(-1, 40));
    try t.expectEqual(@as(usize, 3), w.next(-1, 80));
    // A direction change starts over.
    try t.expectEqual(@as(usize, 1), w.next(1, 100));
    // So does a pause longer than the gesture gap.
    try t.expectEqual(@as(usize, 2), w.next(1, 150));
    try t.expectEqual(@as(usize, 1), w.next(1, 400));
    // Events of one physical notch (a burst) move one line each.
    try t.expectEqual(@as(usize, 1), w.next(1, 403));
}

test "wheel accelerator: fixed counts and pre-accelerating terminals" {
    var fixed = WheelScrollAccelerator{ .lines = .{ .fixed = 3 } };
    try t.expectEqual(@as(usize, 3), fixed.next(1, 0));
    try t.expectEqual(@as(usize, 3), fixed.next(1, 5));
    var zero = WheelScrollAccelerator{ .lines = .{ .fixed = 0 } };
    try t.expectEqual(@as(usize, 1), zero.next(1, 0)); // at least one line
    // A local macOS terminal delivers one event per line already.
    var mac = WheelScrollAccelerator{ .accelerate = false };
    try t.expectEqual(@as(usize, 1), mac.next(1, 0));
    try t.expectEqual(@as(usize, 1), mac.next(1, 10));
    try t.expect(WheelScrollAccelerator.terminalAcceleratesWheel(true, false));
    try t.expect(!WheelScrollAccelerator.terminalAcceleratesWheel(true, true));
    try t.expect(!WheelScrollAccelerator.terminalAcceleratesWheel(false, false));
}
