const std = @import("std");
const httpz = @import("httpz");
const BrotliEncoder = @import("brotli").Encoder;

const consts = @import("consts.zig");
const config = @import("config");

const DsSdk = @This();
const log = std.log.scoped(.ds_sdk);

const sse_header = "HTTP/1.1 200 \r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n";

options: consts.InitOptions,
arena: std.mem.Allocator,
stream: std.net.Stream,
writer: std.io.AnyWriter = undefined,
data: std.ArrayListUnmanaged(u8) = .empty,
enc: ?BrotliEncoder = null,

/// Initialise SSE connection for datastar with brotli
pub fn init(
    res: *httpz.Response,
    options: consts.InitOptions,
) !DsSdk {
    // setup response connection for SSE
    res.conn.handover = .close;
    try res.conn.stream.writeAll(sse_header);

    // Initialise brotli encoder if necessary
    var enc: ?BrotliEncoder = null;
    if (!options.encoding)
        try res.conn.stream.writeAll("\r\n")
    else {
        if (options.keep_alive) {
            // set brotli encoder for streaming
            enc = try BrotliEncoder.init(res.arena, .{ .process = .stream });
            try res.conn.stream.writeAll("Content-Encoding: br\r\n\r\n");
        } else
        // set brotli encoder for oneshot
        enc = try BrotliEncoder.init(res.arena, .{});
    }

    return DsSdk{
        .options = options,
        .arena = res.arena,
        .stream = res.conn.stream,
        .enc = enc,
    };
}

// Deinit Cleanup before closing the SSE connection
pub fn deinit(self: *DsSdk) !void {
    if (!self.options.encoding) return;
    if (!self.options.keep_alive)
        // compress oneshot and send response
        try self.sendEncoded()
    else
        // Finish Brotli stream
        try self.stream.writeAll(&BrotliEncoder.streamEnd);
    // Destroy encoder instance
    self.enc.?.deinit();
}

/// Helper function that reads datastar signals from the request.
pub fn readSignals(comptime T: type, req: *httpz.Request) !T {
    log.info("readSignals", .{});
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
    self: *DsSdk,
    settings: consts.EventSettings,
) !void {
    self.writer.print("event: {}\n", .{settings.event}) catch |err| {
        log.err("writer.print(event): {}", .{err});
        return err;
    };

    if (settings.event_id) |id| {
        try self.writer.print("id: {s}\n", .{id});
    }

    if (settings.retry_duration != consts.default_sse_retry_duration) {
        try self.writer.print("retry: {d}\n", .{settings.retry_duration});
    }
}

/// Merges one or more fragments into the DOM
pub fn mergeFragments(
    self: *DsSdk,
    /// The HTML fragments to merge into the DOM.
    fragments: []const u8,
    options: consts.MergeFragmentsOptions,
) !void {
    if (fragments.len == 0) return;

    // select writer for direct stream vs brotli
    self.writer = if (!self.options.encoding)
        self.stream.writer().any()
    else
        self.data.writer(self.arena).any();

    // Initialise SSE Event
    try self.initEvent(
        .{
            .event = .merge_fragments,
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );

    if (options.selector) |selector| {
        try self.writer.print(
            "data: " ++ consts.selector_dataline_literal ++ " {s}\n",
            .{selector},
        );
    }

    if (options.merge_mode != consts.default_fragment_merge_mode) {
        try self.writer.print(
            "data: " ++ consts.merge_mode_dataline_literal ++ " {}\n",
            .{options.merge_mode},
        );
    }

    if (options.settle_duration != consts.default_fragments_settle_duration) {
        try self.writer.print(
            "data: " ++ consts.settle_duration_dataline_literal ++ " {d}\n",
            .{options.settle_duration},
        );
    }

    if (options.use_view_transition != consts.default_fragments_use_view_transitions) {
        try self.writer.print(
            "data: " ++ consts.use_view_transition_dataline_literal ++ " {}\n",
            .{options.use_view_transition},
        );
    }

    var iter = std.mem.splitScalar(u8, fragments, '\n');
    while (iter.next()) |elem| {
        try self.writer.print(
            "data: " ++ consts.fragments_dataline_literal ++ " {s}\n",
            .{elem},
        );
    }

    try self.finishResponse();
}

/// Sends a selector to the browser to remove HTML fragments from the DOM.
pub fn removeFragments(
    self: *DsSdk,
    selector: []const u8,
    options: consts.RemoveFragmentsOptions,
) !void {
    if (selector.len == 0) return;

    // select writer for direct stream vs brotli
    self.writer = if (!self.options.encoding)
        self.stream.writer().any()
    else
        self.data.writer(self.arena).any();

    // Initialise SSE Event
    try self.initEvent(
        .{
            .event = .remove_fragments,
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );

    if (options.settle_duration != consts.default_fragments_settle_duration) {
        try self.writer.print(
            "data: " ++ consts.settle_duration_dataline_literal ++ " {d}\n",
            .{options.settle_duration},
        );
    }

    if (options.use_view_transition != consts.default_fragments_use_view_transitions) {
        try self.writer.print(
            "data: " ++ consts.use_view_transition_dataline_literal ++ " {}\n",
            .{options.use_view_transition},
        );
    }

    try self.writer.print(
        "data: " ++ consts.selector_dataline_literal ++ " {s}\n",
        .{selector},
    );

    try self.finishResponse();
}

/// Sends one or more signals to the browser to be merged into the signals.
pub fn mergeSignals(
    self: *DsSdk,
    signals: anytype,
    options: consts.MergeSignalsOptions,
) !void {
    // select writer for direct stream vs brotli
    self.writer = if (!self.options.encoding)
        self.stream.writer().any()
    else
        self.data.writer(self.arena).any();

    // Initialise SSE Event
    try self.initEvent(
        .{
            .event = .merge_signals,
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );

    if (options.only_if_missing != consts.default_merge_signals_only_if_missing) {
        try self.writer.print(
            "data: " ++ consts.only_if_missing_dataline_literal ++ " {}\n",
            .{options.only_if_missing},
        );
    }

    try self.writer.writeAll("data: " ++ consts.signals_dataline_literal ++ " ");
    try std.json.stringify(signals, .{}, self.writer);

    try self.writer.writeAll("\n");
    try self.finishResponse();
}

/// Sends signals to the browser to be removed from the signals.
pub fn removeSignals(
    self: *DsSdk,
    paths: []const []const u8,
    options: consts.RemoveSignalsOptions,
) !void {
    if (paths.len == 0) return;

    // select writer for direct stream vs brotli
    self.writer = if (!self.options.encoding)
        self.stream.writer().any()
    else
        self.data.writer(self.arena).any();

    // Initialise SSE Event
    try self.initEvent(
        .{
            .event = .remove_signals,
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );

    for (paths) |path| {
        try self.writer.print(
            "data: " ++ consts.paths_dataline_literal ++ " {s}\n",
            .{path},
        );
    }

    try self.finishResponse();
}

/// Executes JavaScript in the browser
pub fn executeScript(
    self: *DsSdk,
    /// `script` is a string that represents the JavaScript to be executed by the browser.
    script: []const u8,
    options: consts.ExecuteScriptOptions,
) !void {
    if (script.len == 0) return;

    // select writer for direct stream vs brotli
    self.writer = if (!self.options.encoding)
        self.stream.writer().any()
    else
        self.data.writer(self.arena).any();

    // Initialise SSE Event
    try self.initEvent(
        .{
            .event = .execute_script,
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );

    if (options.attributes.len != 1 or !std.mem.eql(
        u8,
        consts.default_execute_script_attributes,
        options.attributes[0],
    )) {
        for (options.attributes) |attribute| {
            try self.writer.print(
                "data: " ++ consts.attributes_dataline_literal ++ " {s}\n",
                .{attribute},
            );
        }
    }

    if (options.auto_remove != consts.default_execute_script_auto_remove) {
        try self.writer.print(
            "data: " ++ consts.auto_remove_dataline_literal ++ " {}\n",
            .{options.auto_remove},
        );
    }

    var iter = std.mem.splitScalar(u8, script, '\n');
    while (iter.next()) |elem| {
        try self.writer.print(
            "data: " ++ consts.script_dataline_literal ++ " {s}\n",
            .{elem},
        );
    }

    try self.finishResponse();
}

/// Sends an `executeScript` event to redirect the user to a new URL.
pub fn redirect(
    self: *DsSdk,
    url: []const u8,
    options: consts.ExecuteScriptOptions,
) !void {
    if (url.len == 0) return;

    const script = try std.fmt.allocPrint(
        self.arena,
        "setTimeout(() => window.location.href = '{s}')",
        .{url},
    );
    errdefer self.arena.free(script);
    try self.executeScript(script, options);
}

/// Finish response
fn finishResponse(
    self: *DsSdk,
) !void {
    try self.writer.writeByte('\n');
    // Flush brotli encoded response in stream mode
    if (self.options.encoding and self.options.keep_alive) try self.sendEncoded();
}

/// Send brotli encoded msg to the browser
fn sendEncoded(
    self: *DsSdk,
) !void {
    // free data arraylist after sending to stream
    defer {
        self.data.deinit(self.arena);
        self.data = .empty;
    }

    if (!self.options.keep_alive)
        // Check if response size is big enough to trigger encoding
        if (self.data.items.len >= self.options.enc_min_size) {
            // add brotli encoding to response
            try self.stream.writeAll("Content-Encoding: br\r\n\r\n");
        } else {
            // send raw data instead
            try self.stream.writeAll("\r\n");
            try self.stream.writeAll(self.data.items);
            return;
        };

    const to_send = try self.data.toOwnedSlice(self.arena);
    defer self.arena.free(to_send);

    const encoded = try self.enc.?.encode(to_send);
    defer self.arena.free(encoded);

    try self.stream.writeAll(encoded);
}

test {
    @import("std").testing.refAllDecls(DsSdk);
}
