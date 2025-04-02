const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;

const RadioController = @import("controller.zig").RadioController;
const RadioEvent = @import("radio.zig").RadioEvent;

pub const HttpHandler = struct {
    controller: *RadioController(WebsocketHandler),

    pub fn init(controller: *RadioController(WebsocketHandler)) HttpHandler {
        return .{ .controller = controller };
    }

    pub const WebsocketHandler = struct {
        conn: *websocket.Conn,
        controller: *RadioController(WebsocketHandler),

        pub const Context = struct { controller: *RadioController(WebsocketHandler) };

        pub fn init(conn: *websocket.Conn, ctx: *const Context) !WebsocketHandler {
            std.log.info("New connection from {}", .{conn.address});
            return .{ .conn = conn, .controller = ctx.controller };
        }

        pub fn afterInit(self: *WebsocketHandler) !void {
            try self.controller.addListener(self);
        }

        pub fn close(self: *WebsocketHandler) void {
            std.log.info("Closed connection from {}", .{self.conn.address});
            self.controller.removeListener(self);
        }

        ////////////////////////////////////////////////////////////////////////
        // RPC
        ////////////////////////////////////////////////////////////////////////

        const Methods = &[_]Method{
            Method.init("scan", RadioController(WebsocketHandler).scan),
            Method.init("abortScan", RadioController(WebsocketHandler).abortScan),
            Method.init("tune", RadioController(WebsocketHandler).tune),
            Method.init("setAudioBandwidth", RadioController(WebsocketHandler).setAudioBandwidth),
            Method.init("setAudioAgcMode", RadioController(WebsocketHandler).setAudioAgcMode),
        };

        pub const RequestMessage = struct {
            id: isize,
            method: []const u8,
            params: std.json.Value,
        };

        pub const ResponseMessage = struct {
            id: isize,
            success: bool,
            message: ?[]const u8,
        };

        const Method = struct {
            name: []const u8,
            handler: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: isize, value: std.json.Value) ResponseMessage,

            pub fn init(name: []const u8, comptime function: anytype) Method {
                const gen = struct {
                    fn handler(ptr: *anyopaque, allocator: std.mem.Allocator, id: isize, value: std.json.Value) ResponseMessage {
                        comptime var types: [@typeInfo(@TypeOf(function)).@"fn".params.len]type = undefined;
                        inline for (@typeInfo(@TypeOf(function)).@"fn".params, 0..) |p, i| types[i] = p.type.?;

                        const params = std.json.parseFromValue(std.meta.Tuple(types[1..]), allocator, value, .{}) catch {
                            return ResponseMessage{ .id = id, .success = false, .message = "Invalid parameters" };
                        };

                        @call(.auto, function, .{@as(types[0], @ptrCast(@alignCast(ptr)))} ++ params.value) catch |err| {
                            return ResponseMessage{ .id = id, .success = false, .message = @errorName(err) };
                        };

                        return ResponseMessage{ .id = id, .success = true, .message = null };
                    }
                };

                return .{ .name = name, .handler = gen.handler };
            }
        };

        fn dispatch(self: *WebsocketHandler, allocator: std.mem.Allocator, request: RequestMessage) ResponseMessage {
            inline for (Methods) |method| {
                if (std.mem.eql(u8, request.method, method.name)) {
                    return method.handler(self.controller, allocator, request.id, request.params);
                }
            }

            return ResponseMessage{ .id = request.id, .success = false, .message = "Unknown method" };
        }

        pub fn clientMessage(self: *WebsocketHandler, allocator: std.mem.Allocator, data: []const u8) !void {
            const response = blk: {
                const request = std.json.parseFromSlice(RequestMessage, allocator, data, .{}) catch {
                    break :blk ResponseMessage{ .id = -1, .success = false, .message = "Invalid request" };
                };
                break :blk self.dispatch(allocator, request.value);
            };

            var wb = self.conn.writeBuffer(allocator, .text);
            try std.json.stringify(response, .{}, wb.writer());
            try wb.flush();
        }

        ////////////////////////////////////////////////////////////////////////
        // Events
        ////////////////////////////////////////////////////////////////////////

        pub const EventMessage = struct {
            event: []const u8,
            payload: std.json.Value,
        };

        pub fn onRadioEvent(self: *WebsocketHandler, event: RadioEvent) !void {
            if (event == .audio) {
                try self.conn.writeBin(event.audio.samples);
            } else {
                var buf: [8192]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);

                switch (event) {
                    inline else => |value, tag| {
                        try std.json.stringify(struct {
                            event: []const u8,
                            payload: std.meta.TagPayload(RadioEvent, tag),
                        }{ .event = @tagName(event), .payload = value }, .{}, fbs.writer());
                    },
                }

                try self.conn.writeText(fbs.getWritten());
            }
        }
    };
};
