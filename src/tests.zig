const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;

const RadioController = @import("controller.zig").RadioController;
const HttpHandler = @import("handler.zig").HttpHandler;

////////////////////////////////////////////////////////////////////////////////
// Tester Helper Class
////////////////////////////////////////////////////////////////////////////////

const Tester = struct {
    controller: RadioController(HttpHandler.WebsocketHandler),
    server: ?httpz.Server(HttpHandler),
    client: ?websocket.Client,
    server_thread: std.Thread = undefined,

    pub fn init() !Tester {
        return .{
            .controller = try RadioController(HttpHandler.WebsocketHandler).init(std.testing.allocator, .{}),
            .server = null,
            .client = null,
        };
    }

    pub fn deinit(self: *Tester) void {
        if (self.client) |*client| client.deinit();
        if (self.server) |*server| server.deinit();
        self.controller.deinit();
    }

    fn ws(handler: HttpHandler, req: *httpz.Request, res: *httpz.Response) !void {
        if (try httpz.upgradeWebsocket(HttpHandler.WebsocketHandler, req, res, &HttpHandler.WebsocketHandler.Context{ .controller = handler.controller }) == false) {
            res.status = 500;
            res.body = "Invalid websocket";
        }
    }

    pub fn setup(self: *Tester) !void {
        // Start controller
        try self.controller.start();

        // Create and start server
        self.server = try httpz.Server(HttpHandler).init(std.testing.allocator, .{ .address = "127.0.0.1", .port = 9001 }, HttpHandler.init(&self.controller));
        (try self.server.?.router(.{})).get("/ws", ws, .{});
        self.server_thread = try std.Thread.spawn(.{}, httpz.Server(HttpHandler).listen, .{&self.server.?});

        // Create and start client
        self.client = try websocket.Client.init(std.testing.allocator, .{ .host = "127.0.0.1", .port = 9001 });
        try self.client.?.handshake("/ws", .{ .timeout_ms = 1000, .headers = "Host: 127.0.0.1:9001" });
        try self.client.?.readTimeout(500);
    }

    pub fn teardown(self: *Tester) void {
        // Stop client
        if (self.client) |*client| client.close(.{}) catch unreachable;

        // Stop controller
        self.controller.stop() catch unreachable;

        // Stop server
        if (self.server) |*server| server.stop();
        self.server_thread.join();
    }

    pub fn writeText(self: *Tester, data: []const u8) !void {
        var buf: [8192]u8 = undefined;
        @memcpy(buf[0..data.len], data);
        try self.client.?.writeText(buf[0..data.len]);
    }

    pub fn writeJson(self: *Tester, value: anytype) !void {
        var buf: [8192]u8 = undefined;
        var writer = std.io.Writer.fixed(&buf);
        try std.json.Stringify.value(value, .{}, &writer);
        try self.writeText(writer.buffered());
    }

    pub fn read(self: *Tester, message_type: websocket.MessageType, timeout_ms: usize) ![]const u8 {
        const tic = std.time.milliTimestamp();

        while (true) {
            if (std.time.milliTimestamp() - tic > timeout_ms) return error.Timeout;

            const message = (try self.client.?.read()) orelse continue;
            defer self.client.?.done(message);

            if (message.type == message_type) {
                return std.testing.allocator.dupe(u8, message.data);
            }
        }
    }

    pub fn readBinary(self: *Tester, timeout_ms: usize) ![]const u8 {
        return self.read(.binary, timeout_ms);
    }

    pub fn readText(self: *Tester, timeout_ms: usize) ![]const u8 {
        return self.read(.text, timeout_ms);
    }

    pub fn readJson(self: *Tester, T: type, timeout_ms: usize) !std.json.Parsed(T) {
        const tic = std.time.milliTimestamp();

        while (true) {
            if (std.time.milliTimestamp() - tic > timeout_ms) return error.Timeout;

            const data = try self.readText(timeout_ms);
            defer std.testing.allocator.free(data);

            return std.json.parseFromSlice(T, std.testing.allocator, data, .{ .allocate = .alloc_always }) catch continue;
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Messages for Convenience
////////////////////////////////////////////////////////////////////////////////

const RadioEvent = @import("radio.zig").RadioEvent;
const FrequencySweep = @import("radio.zig").FrequencySweep;
const AudioAgcMode = @import("radio.zig").AudioAgcMode;

const StatusEventMessage = struct { event: []const u8, payload: std.meta.TagPayload(RadioEvent, RadioEvent.status) };
const ScanEventMessage = struct { event: []const u8, payload: std.meta.TagPayload(RadioEvent, RadioEvent.scan) };

const ScanRequestMessage = struct { id: isize, method: []const u8, params: struct { []const FrequencySweep } };
const TuneRequestMessage = struct { id: isize, method: []const u8, params: struct { f64 } };
const AbortScanRequestMessage = struct { id: isize, method: []const u8, params: struct { void } };
const SetAudioBandwidthRequestMessage = struct { id: isize, method: []const u8, params: struct { f32 } };
const SetAudioAgcModeRequestMessage = struct { id: isize, method: []const u8, params: struct { AudioAgcMode } };

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "setup, teardown" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();
}

test "event: audio" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();

    // Should get binary samples every 100 ms
    for (0..3) |_| {
        const data = try tester.readBinary(500);
        defer std.testing.allocator.free(data);

        try std.testing.expect(data.len > 0);
    }
}

test "event: status" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();

    // Should get a status event every 1000 seconds
    for (0..2) |_| {
        const event = try tester.readJson(StatusEventMessage, 2000);
        defer event.deinit();

        try std.testing.expectEqualStrings("status", event.value.event);
    }
}

test "rpc: invalid request" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();

    // Invalid request data
    {
        try tester.writeText("abc");
        const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
        defer response.deinit();
        try std.testing.expectEqual(-1, response.value.id);
        try std.testing.expectEqual(false, response.value.success);
        try std.testing.expectEqualStrings("Invalid request", response.value.message.?);
    }

    // Invalid request object (missing id)
    {
        try tester.writeJson(struct { method: []const u8, params: struct { usize, usize } }{ .method = "foo", .params = .{ 1, 2 } });
        const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
        defer response.deinit();
        try std.testing.expectEqual(-1, response.value.id);
        try std.testing.expectEqual(false, response.value.success);
        try std.testing.expectEqualStrings("Invalid request", response.value.message.?);
    }
}

test "rpc: unknown method" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();

    try tester.writeJson(struct { id: isize, method: []const u8, params: struct { f32 } }{ .id = 123, .method = "foo", .params = .{5e6} });
    const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
    defer response.deinit();
    try std.testing.expectEqual(123, response.value.id);
    try std.testing.expectEqual(false, response.value.success);
    try std.testing.expectEqualStrings("Unknown method", response.value.message.?);
}

test "rpc: invalid parameters" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();

    try tester.writeJson(struct { id: isize, method: []const u8, params: struct { []const u8 } }{ .id = 123, .method = "tune", .params = .{"bar"} });
    const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
    defer response.deinit();
    try std.testing.expectEqual(123, response.value.id);
    try std.testing.expectEqual(false, response.value.success);
    try std.testing.expectEqualStrings("Invalid parameters", response.value.message.?);
}

test "rpc: scan()" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();

    try tester.writeJson(ScanRequestMessage{ .id = 456, .method = "scan", .params = .{&.{ .{ .start = 5000e3, .stop = 5020e3, .step = 5e3 }, .{ .start = 6000e3, .stop = 6030e3, .step = 10e3 } }} });

    const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
    defer response.deinit();
    try std.testing.expectEqual(456, response.value.id);
    try std.testing.expectEqual(true, response.value.success);
    try std.testing.expectEqual(null, response.value.message);

    for (&[_]f64{ 5000e3, 5005e3, 5010e3, 5015e3, 5020e3, 6000e3, 6010e3, 6020e3, 6030e3 }) |freq| {
        const event = try tester.readJson(ScanEventMessage, 500);
        defer event.deinit();
        try std.testing.expectEqualStrings("scan", event.value.event);
        try std.testing.expectApproxEqAbs(freq, event.value.payload.frequency, 0.1);
        try std.testing.expect(event.value.payload.power_dbfs < 0);
    }
}

test "rpc: abortScan()" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();

    {
        try tester.writeJson(ScanRequestMessage{ .id = 456, .method = "scan", .params = .{&.{
            .{ .start = 5000e3, .stop = 5020e3, .step = 5e3 },
        }} });

        const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
        defer response.deinit();
        try std.testing.expectEqual(456, response.value.id);
        try std.testing.expectEqual(true, response.value.success);
        try std.testing.expectEqual(null, response.value.message);
    }

    for (&[_]f64{ 5000e3, 5005e3, 5010e3 }) |freq| {
        const event = try tester.readJson(ScanEventMessage, 500);
        defer event.deinit();
        try std.testing.expectEqualStrings("scan", event.value.event);
        try std.testing.expectApproxEqAbs(freq, event.value.payload.frequency, 0.1);
        try std.testing.expect(event.value.payload.power_dbfs < 0);
    }

    {
        try tester.writeJson(AbortScanRequestMessage{ .id = 457, .method = "abortScan", .params = .{} });

        const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
        defer response.deinit();
        try std.testing.expectEqual(457, response.value.id);
        try std.testing.expectEqual(true, response.value.success);
        try std.testing.expectEqual(null, response.value.message);
    }

    const event = try tester.readJson(ScanEventMessage, 500);
    defer event.deinit();
    try std.testing.expectEqualStrings("scan", event.value.event);
    try std.testing.expectApproxEqAbs(5015e3, event.value.payload.frequency, 0.1);
    try std.testing.expect(event.value.payload.power_dbfs < 0);

    try std.testing.expectError(error.Timeout, tester.readJson(ScanEventMessage, 500));
}

test "rpc: tune()" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();

    {
        const status = try tester.readJson(StatusEventMessage, 2000);
        defer status.deinit();
        try std.testing.expectEqualStrings("status", status.value.event);
        try std.testing.expectApproxEqAbs(5000e3, status.value.payload.frequency, 0.1);
    }

    try tester.writeJson(TuneRequestMessage{ .id = 789, .method = "tune", .params = .{2500e3} });

    {
        const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
        defer response.deinit();
        try std.testing.expectEqual(789, response.value.id);
        try std.testing.expectEqual(true, response.value.success);
        try std.testing.expectEqual(null, response.value.message);
    }

    {
        const status = try tester.readJson(StatusEventMessage, 2000);
        defer status.deinit();
        try std.testing.expectEqualStrings("status", status.value.event);
        try std.testing.expectApproxEqAbs(2500e3, status.value.payload.frequency, 0.1);
    }

    try tester.writeJson(TuneRequestMessage{ .id = 790, .method = "tune", .params = .{100e3} });

    {
        const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
        defer response.deinit();
        try std.testing.expectEqual(790, response.value.id);
        try std.testing.expectEqual(false, response.value.success);
        try std.testing.expectEqualStrings("OutOfBounds", response.value.message.?);
    }
}

test "rpc: setAudioBandwidth()" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();

    {
        const status = try tester.readJson(StatusEventMessage, 2000);
        defer status.deinit();
        try std.testing.expectEqualStrings("status", status.value.event);
        try std.testing.expectApproxEqAbs(5e3, status.value.payload.audio_bandwidth, 0.1);
    }

    try tester.writeJson(SetAudioBandwidthRequestMessage{ .id = 789, .method = "setAudioBandwidth", .params = .{3e3} });

    {
        const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
        defer response.deinit();
        try std.testing.expectEqual(789, response.value.id);
        try std.testing.expectEqual(true, response.value.success);
        try std.testing.expectEqual(null, response.value.message);
    }

    {
        const status = try tester.readJson(StatusEventMessage, 2000);
        defer status.deinit();
        try std.testing.expectEqualStrings("status", status.value.event);
        try std.testing.expectApproxEqAbs(3e3, status.value.payload.audio_bandwidth, 0.1);
    }

    try tester.writeJson(SetAudioBandwidthRequestMessage{ .id = 790, .method = "setAudioBandwidth", .params = .{500} });

    {
        const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
        defer response.deinit();
        try std.testing.expectEqual(790, response.value.id);
        try std.testing.expectEqual(false, response.value.success);
        try std.testing.expectEqualStrings("OutOfBounds", response.value.message.?);
    }
}

test "rpc: setAudioAgcMode()" {
    var tester = try Tester.init();
    defer tester.deinit();

    try tester.setup();
    defer tester.teardown();

    {
        const status = try tester.readJson(StatusEventMessage, 2000);
        defer status.deinit();
        try std.testing.expectEqualStrings("status", status.value.event);
        try std.testing.expect(status.value.payload.audio_agc_mode == .preset);
        try std.testing.expectEqual(.Slow, status.value.payload.audio_agc_mode.preset);
    }

    try tester.writeJson(SetAudioAgcModeRequestMessage{ .id = 789, .method = "setAudioAgcMode", .params = .{.{ .preset = .Fast }} });

    {
        const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
        defer response.deinit();
        try std.testing.expectEqual(789, response.value.id);
        try std.testing.expectEqual(true, response.value.success);
        try std.testing.expectEqual(null, response.value.message);
    }

    {
        const status = try tester.readJson(StatusEventMessage, 2000);
        defer status.deinit();
        try std.testing.expectEqualStrings("status", status.value.event);
        try std.testing.expect(status.value.payload.audio_agc_mode == .preset);
        try std.testing.expectEqual(.Fast, status.value.payload.audio_agc_mode.preset);
    }

    try tester.writeJson(SetAudioAgcModeRequestMessage{ .id = 790, .method = "setAudioAgcMode", .params = .{.{ .custom = 1.5 }} });

    {
        const response = try tester.readJson(HttpHandler.WebsocketHandler.ResponseMessage, 500);
        defer response.deinit();
        try std.testing.expectEqual(790, response.value.id);
        try std.testing.expectEqual(true, response.value.success);
        try std.testing.expectEqual(null, response.value.message);
    }

    {
        const status = try tester.readJson(StatusEventMessage, 2000);
        defer status.deinit();
        try std.testing.expectEqualStrings("status", status.value.event);
        try std.testing.expect(status.value.payload.audio_agc_mode == .custom);
        try std.testing.expectApproxEqAbs(1.5, status.value.payload.audio_agc_mode.custom, 0.01);
    }
}
