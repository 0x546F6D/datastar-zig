# Datastar Zig SDK

An implementation of the Datastar SDK in Zig with framework integration for http.zig, and possibility to use brotli/gzip encoding for short lived connections.

```zig
const datastar = @import("datastar");

// Creates a new `ServerSentEventGenerator`.
var sse = try datastar.init(res, .{});
// Merges HTML fragments into the DOM.
try sse.mergeFragments("<div id='question'>What do you put in a toaster?</div>", .{});
// Merges signals into the signals.
try sse.mergeSignals(.{ .response = "", .answer = "bread" }, .{});


// Creates a new `ServerSentEventGenerator` with brotli encoding
var sse = try datastar.init(res, .{ .encoding = .br });
defer sse.sendEncoded() catch {};
// Merges HTML fragments into the DOM.
try sse.mergeFragments("<div id='question'>What do you put in a toaster?</div>", .{});
// Merges signals into the signals.
try sse.mergeSignals(.{ .response = "", .answer = "bread" }, .{});

```

