# Datastar Zig SDK

An implementation of the Datastar SDK in Zig with framework integration for http.zig, and possibility to use brotli encoding for one shot compression of short lived connection or continuous compression for long lived streams.

```zig
const datastar = @import("datastar");

// Creates a new `ServerSentEventGenerator`.
var sse = try datastar.init(res, .{});
// Merges HTML fragments into the DOM.
try sse.mergeFragments("<div id='question'>What do you put in a toaster?</div>", .{});
// Merges signals into the signals.
try sse.mergeSignals(.{ .response = "", .answer = "bread" }, .{});


// Creates a new `ServerSentEventGenerator` with brotli encoding while streaming
var sse = try datastar.init(res, .{ .encoding = true, .keep_alive = true });
defer sse.deinit() catch {};
// Merges HTML fragments into the DOM.
try sse.mergeFragments("<div id='question'>What do you put in a toaster?</div>", .{});
// Merges signals into the signals.
try sse.mergeSignals(.{ .response = "", .answer = "bread" }, .{});


// Creates a new `ServerSentEventGenerator` with oneshot brotli encoding of the whole final response
var sse = try datastar.init(res, .{ .encoding = true, .enc_min_size = 256 });
defer sse.deinit() catch {};
// Merges HTML fragments into the DOM.
try sse.mergeFragments("<div id='question'>What do you put in a toaster?</div>", .{});
// Merges signals into the signals.
try sse.mergeSignals(.{ .response = "", .answer = "bread" }, .{});

```
