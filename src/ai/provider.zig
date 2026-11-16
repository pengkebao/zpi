//! Multi-protocol provider dispatch (Phase 6).
//! AnyProvider is a tagged union over the four implemented wire protocols;
//! the agent session holds one and dispatches streamChat by tag. api kind
//! comes from the model catalog / models.json "api" field.

const std = @import("std");
const config = @import("../core/config.zig");
const openai = @import("openai.zig");
const anthropic = @import("anthropic.zig");
const google = @import("google.zig");
const responses = @import("responses.zig");

pub const ApiKind = enum {
    openai_completions,
    anthropic_messages,
    openai_responses,
    google_generative_ai,

    pub fn fromStr(s: []const u8) ?ApiKind {
        if (std.mem.eql(u8, s, "openai-completions")) return .openai_completions;
        if (std.mem.eql(u8, s, "anthropic-messages")) return .anthropic_messages;
        if (std.mem.eql(u8, s, "openai-responses")) return .openai_responses;
        if (std.mem.eql(u8, s, "google-generative-ai")) return .google_generative_ai;
        return null;
    }

    pub fn wireName(self: ApiKind) []const u8 {
        return switch (self) {
            .openai_completions => "openai-completions",
            .anthropic_messages => "anthropic-messages",
            .openai_responses => "openai-responses",
            .google_generative_ai => "google-generative-ai",
        };
    }
};

pub const AnyProvider = union(ApiKind) {
    openai_completions: *openai.OpenAiProvider,
    anthropic_messages: *anthropic.AnthropicProvider,
    openai_responses: *responses.ResponsesProvider,
    google_generative_ai: *google.GoogleProvider,

    pub fn deinit(self: AnyProvider) void {
        switch (self) {
            .openai_completions => |p| {
                p.deinit();
                p.alloc.destroy(p);
            },
            .anthropic_messages => |p| {
                p.deinit();
                p.alloc.destroy(p);
            },
            .openai_responses => |p| {
                p.deinit();
                p.alloc.destroy(p);
            },
            .google_generative_ai => |p| {
                p.deinit();
                p.alloc.destroy(p);
            },
        }
    }

    pub fn lastErrorText(self: AnyProvider) []const u8 {
        return switch (self) {
            inline else => |p| p.lastErrorText(),
        };
    }
};

/// Build the right provider for a model (heap-allocated; the union owns the
/// pointer and AnyProvider.deinit destroys it).
pub fn buildFromModel(alloc: std.mem.Allocator, io: std.Io, model: *const config.Config.Model) !AnyProvider {
    const kind = ApiKind.fromStr(model.api) orelse .openai_completions;
    switch (kind) {
        .openai_completions => {
            const p = try alloc.create(openai.OpenAiProvider);
            errdefer alloc.destroy(p);
            p.* = try openai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
            return .{ .openai_completions = p };
        },
        .anthropic_messages => {
            const p = try alloc.create(anthropic.AnthropicProvider);
            errdefer alloc.destroy(p);
            p.* = try anthropic.AnthropicProvider.init(alloc, io, model.base_url, model.api_key, model.max_tokens);
            return .{ .anthropic_messages = p };
        },
        .openai_responses => {
            const p = try alloc.create(responses.ResponsesProvider);
            errdefer alloc.destroy(p);
            p.* = try responses.ResponsesProvider.init(alloc, io, model.base_url, model.api_key, model.max_tokens);
            return .{ .openai_responses = p };
        },
        .google_generative_ai => {
            const p = try alloc.create(google.GoogleProvider);
            errdefer alloc.destroy(p);
            p.* = try google.GoogleProvider.init(alloc, io, model.base_url, model.api_key, model.max_tokens);
            return .{ .google_generative_ai = p };
        },
    }
}

/// Dispatch a streaming chat round to the protocol implementation.
/// tinfo is only consumed by the openai-completions path (thinkingFormat).
pub fn streamDispatch(
    provider: AnyProvider,
    model_id: []const u8,
    messages: []const openai.OpenAiProvider.ChatMessage,
    tools_json: []const u8,
    supports_images: bool,
    thinking_level: config.ThinkingLevel,
    tinfo: openai.OpenAiProvider.ThinkingInfo,
    max_tokens: usize,
    session: anytype,
) !void {
    switch (provider) {
        .openai_completions => |p| {
            return p.streamChat(model_id, messages, tools_json, supports_images, thinking_level, tinfo, max_tokens, session);
        },
        .anthropic_messages => |p| {
            return p.streamChat(model_id, messages, tools_json, supports_images, thinking_level, session);
        },
        .openai_responses => |p| {
            return p.streamChat(model_id, messages, tools_json, supports_images, thinking_level, session);
        },
        .google_generative_ai => |p| {
            return p.streamChat(model_id, messages, tools_json, supports_images, thinking_level, session);
        },
    }
}
