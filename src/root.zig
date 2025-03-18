const std = @import("std");

const httpz = @import("httpz");
const Brotli = @import("brotli");
const br = Brotli.init(Brotli.Settings{});

const consts = @import("consts.zig");
const config = @import("config");

const DsSdk = @This();
const log = std.log.scoped(.ds_sdk);

const default_execute_script_attributes: []const []const u8 = &[_][]const u8{consts.default_execute_script_attributes};

res: *httpz.Response,
options: InitOptions,
data: std.ArrayListUnmanaged(u8) = .empty,

/// The type of encoding to use with the SSE response
pub const Encoding = enum {
    // use brotli encoding
    br,
    // use gzip encoding
    gzip,
};

pub const InitOptions = struct {
    /// Select 'br'/'gzip' encoding. Requires 'sse.sendEncoded()' to send the final encoded msg
    encoding: ?Encoding = null,
    /// Minimum size to trigger encoding.
    enc_min_size: u16 = 256,
};

pub const ExecuteScriptOptions = struct {
    /// Used by the backend to replay events.
    event_id: ?[]const u8 = null,
    /// How long for the browser to wait before reconnecting if the connection is lost.
    retry_duration: u32 = consts.default_sse_retry_duration,
    /// A list of 'key value' attributes to add to the script element.
    attributes: []const []const u8 = default_execute_script_attributes,
    /// Whether to remove the script after execution.
    auto_remove: bool = consts.default_execute_script_auto_remove,
};

pub const MergeFragmentsOptions = struct {
    /// Used by the backend to replay events.
    event_id: ?[]const u8 = null,
    /// How long for the browser to wait before reconnecting if the connection is lost.
    retry_duration: u32 = consts.default_sse_retry_duration,
    /// The CSS selector to use to insert the fragments.
    selector: ?[]const u8 = null,
    /// The mode to use when merging the fragment into the DOM.
    merge_mode: consts.FragmentMergeMode = consts.default_fragment_merge_mode,
    /// amount of time used for animations
    settle_duration: u32 = consts.default_fragments_settle_duration,
    /// Whether to use view transitions.
    use_view_transition: bool = consts.default_fragments_use_view_transitions,
};

pub const MergeSignalsOptions = struct {
    /// Used by the backend to replay events.
    event_id: ?[]const u8 = null,
    /// How long for the browser to wait before reconnecting if the connection is lost.
    retry_duration: u32 = consts.default_sse_retry_duration,
    /// Whether to merge the signal only if it does not already exist.
    only_if_missing: bool = consts.default_merge_signals_only_if_missing,
};

pub const RemoveFragmentsOptions = struct {
    /// Used by the backend to replay events.
    event_id: ?[]const u8 = null,
    /// How long for the browser to wait before reconnecting if the connection is lost.
    retry_duration: u32 = consts.default_sse_retry_duration,
    /// amount of time used for animations
    settle_duration: u32 = consts.default_fragments_settle_duration,
    /// Whether to use view transitions.
    use_view_transition: bool = consts.default_fragments_use_view_transitions,
};

pub const RemoveSignalsOptions = struct {
    /// Used by the backend to replay events.
    event_id: ?[]const u8 = null,
    /// How long for the browser to wait before reconnecting if the connection is lost.
    retry_duration: u32 = consts.default_sse_retry_duration,
};

pub const EventSettings = struct {
    event: consts.EventType,
    /// Used by the backend to replay events.
    event_id: ?[]const u8 = null,
    /// How long for the browser to wait before reconnecting if the connection is lost.
    retry_duration: u32 = consts.default_sse_retry_duration,
};

/// Initialise SSE connection
pub fn init(
    res: *@import("httpz").Response,
    options: InitOptions,
) !DsSdk {
    res.content_type = .EVENTS;
    res.header("Cache-Control", "no-cache");

    if (config.http1) {
        res.header("Connection", "keep-alive");
    }

    res.conn.handover = .close;

    // Wait for final encoding in sendEncoded() to write header, if an encoding is selected
    if (options.encoding == null) try res.write();

    return DsSdk{
        .res = res,
        .options = options,
    };
}

/// Helper function that reads datastar signals from the request.
pub fn readSignals(comptime T: type, req: *httpz.Request) !T {
    switch (req.method) {
        .GET => {
            const query = try req.query();
            const signals = query.get(consts.datastar_key) orelse return error.MissingDatastarKey;

            return std.json.parseFromSliceLeaky(T, req.arena, signals, .{});
        },
        else => {
            const body = req.body() orelse return error.MissingBody;

            return std.json.parseFromSliceLeaky(T, req.arena, body, .{});
        },
    }
}

/// Initialise SSE event/id/retry
fn initEvent(
    writer: std.io.AnyWriter,
    settings: EventSettings,
) !void {
    writer.print("event: {}\n", .{settings.event}) catch |err| {
        log.err("writer.print(event): {}", .{err});
        return err;
    };
    if (settings.event_id) |id| {
        try writer.print("id: {s}\n", .{id});
    }

    if (settings.retry_duration != consts.default_sse_retry_duration) {
        try writer.print("retry: {d}\n", .{settings.retry_duration});
    }
}

/// Merges one or more fragments into the DOM
pub fn mergeFragments(
    self: *DsSdk,
    /// The HTML fragments to merge into the DOM.
    fragments: []const u8,
    options: MergeFragmentsOptions,
) !void {
    const writer = if (self.options.encoding == null)
        self.res.conn.stream.writer().any()
    else
        self.data.writer(self.res.arena).any();

    try initEvent(
        writer,
        .{
            .event = .merge_fragments,
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );

    if (options.selector) |selector| {
        try writer.print(
            "data: " ++ consts.selector_dataline_literal ++ " {s}\n",
            .{selector},
        );
    } else {
        return error{test_err}.test_err;
    }

    if (options.merge_mode != consts.default_fragment_merge_mode) {
        try writer.print(
            "data: " ++ consts.merge_mode_dataline_literal ++ " {}\n",
            .{options.merge_mode},
        );
    }

    if (options.settle_duration != consts.default_fragments_settle_duration) {
        try writer.print(
            "data: " ++ consts.settle_duration_dataline_literal ++ " {d}\n",
            .{options.settle_duration},
        );
    }

    if (options.use_view_transition != consts.default_fragments_use_view_transitions) {
        try writer.print(
            "data: " ++ consts.use_view_transition_dataline_literal ++ " {}\n",
            .{options.use_view_transition},
        );
    }

    var iter = std.mem.splitScalar(u8, fragments, '\n');
    while (iter.next()) |elem| {
        try writer.print(
            "data: " ++ consts.fragments_dataline_literal ++ " {s}\n",
            .{elem},
        );
    }

    try writer.writeByte('\n');
}

/// Sends a selector to the browser to remove HTML fragments from the DOM.
pub fn removeFragments(
    self: *DsSdk,
    selector: []const u8,
    options: RemoveFragmentsOptions,
) !void {
    const writer = if (self.options.encoding == null)
        self.res.conn.stream.writer().any()
    else
        self.data.writer(self.res.arena).any();

    try initEvent(
        writer,
        .{
            .event = .remove_fragments,
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );

    if (options.settle_duration != consts.default_fragments_settle_duration) {
        try writer.print(
            "data: " ++ consts.settle_duration_dataline_literal ++ " {d}\n",
            .{options.settle_duration},
        );
    }

    if (options.use_view_transition != consts.default_fragments_use_view_transitions) {
        try writer.print(
            "data: " ++ consts.use_view_transition_dataline_literal ++ " {}\n",
            .{options.use_view_transition},
        );
    }

    try writer.print(
        "data: " ++ consts.selector_dataline_literal ++ " {s}\n",
        .{selector},
    );

    try writer.writeByte('\n');
}

/// Sends one or more signals to the browser to be merged into the signals.
pub fn mergeSignals(
    self: *DsSdk,
    signals: anytype,
    options: MergeSignalsOptions,
) !void {
    const writer = if (self.options.encoding == null)
        self.res.conn.stream.writer().any()
    else
        self.data.writer(self.res.arena).any();

    try initEvent(
        writer,
        .{
            .event = .merge_signals,
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );

    if (options.only_if_missing != consts.default_merge_signals_only_if_missing) {
        try writer.print(
            "data: " ++ consts.only_if_missing_dataline_literal ++ " {}\n",
            .{options.only_if_missing},
        );
    }

    try writer.writeAll("data: " ++ consts.signals_dataline_literal ++ " ");
    try std.json.stringify(signals, .{}, writer);

    try writer.writeAll("\n\n");
}

/// Sends signals to the browser to be removed from the signals.
pub fn removeSignals(
    self: *DsSdk,
    paths: []const []const u8,
    options: RemoveSignalsOptions,
) !void {
    const writer = if (self.options.encoding == null)
        self.res.conn.stream.writer().any()
    else
        self.data.writer(self.res.arena).any();

    try initEvent(
        writer,
        .{
            .event = .remove_signals,
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );

    for (paths) |path| {
        try writer.print(
            "data: " ++ consts.paths_dataline_literal ++ " {s}\n",
            .{path},
        );
    }

    try writer.writeByte('\n');
}

/// Executes JavaScript in the browser
pub fn executeScript(
    self: *DsSdk,
    /// `script` is a string that represents the JavaScript to be executed by the browser.
    script: []const u8,
    options: ExecuteScriptOptions,
) !void {
    const writer = if (self.options.encoding == null)
        self.res.conn.stream.writer().any()
    else
        self.data.writer(self.res.arena).any();

    try initEvent(
        writer,
        .{
            .event = .execute_script,
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );

    if (options.attributes.len != 1 or !std.mem.eql(
        u8,
        default_execute_script_attributes[0],
        options.attributes[0],
    )) {
        for (options.attributes) |attribute| {
            try writer.print(
                "data: " ++ consts.attributes_dataline_literal ++ " {s}\n",
                .{attribute},
            );
        }
    }

    if (options.auto_remove != consts.default_execute_script_auto_remove) {
        try writer.print(
            "data: " ++ consts.auto_remove_dataline_literal ++ " {}\n",
            .{options.auto_remove},
        );
    }

    var iter = std.mem.splitScalar(u8, script, '\n');
    while (iter.next()) |elem| {
        try writer.print(
            "data: " ++ consts.script_dataline_literal ++ " {s}\n",
            .{elem},
        );
    }

    try writer.writeByte('\n');
}

/// Sends an `executeScript` event to redirect the user to a new URL.
pub fn redirect(
    self: *DsSdk,
    url: []const u8,
    options: ExecuteScriptOptions,
) !void {
    const script = try std.fmt.allocPrint(
        self.res.arena,
        "setTimeout(() => window.location.href = '{s}')",
        .{url},
    );
    errdefer self.res.arena.free(script);
    try self.executeScript(script, options);
}

/// Send encoded msg to the browser
pub fn sendEncoded(
    self: *DsSdk,
) !void {
    const encoding = if (self.options.encoding) |enc| enc else return;

    const writer = self.res.conn.stream.writer();

    if (self.data.items.len > self.options.enc_min_size) {
        self.res.header("Content-Encoding", @tagName(encoding));
        try self.res.write();

        switch (encoding) {
            .br => {
                const encoded = try br.encode(self.res.arena, try self.data.toOwnedSlice(self.res.arena));
                writer.writeAll(encoded) catch |err| {
                    log.err("brotli cannot write to stream: {}", .{err});
                    return err;
                };
            },
            .gzip => {
                var fbs = std.io.fixedBufferStream(try self.data.toOwnedSlice(self.res.arena));
                std.compress.gzip.compress(fbs.reader(), writer, .{}) catch |err| {
                    log.err("gzip cannot write to stream: {}", .{err});
                    return err;
                };
            },
        }
    } else {
        try self.res.write();
        try writer.writeAll(self.data.items);
    }
}

test {
    @import("std").testing.refAllDecls(DsSdk);
}
