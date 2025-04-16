const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;

const RadioController = @import("controller.zig").RadioController;
const HttpHandler = @import("handler.zig").HttpHandler;

const FRONTEND_ASSETS = @import("build_options").FRONTEND_ASSETS;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var controller = try RadioController(HttpHandler.WebsocketHandler).init(gpa.allocator(), .{});
    defer controller.deinit();

    var server = try httpz.Server(HttpHandler).init(gpa.allocator(), .{ .port = 8000 }, HttpHandler.init(&controller));
    defer server.deinit();

    var router = try server.router(.{});
    inline for (FRONTEND_ASSETS) |path| {
        router.get(path, staticFileHandler(path, &.{}), .{});
    }
    router.get("/", staticFileHandler("/index.html", &.{
        .{ "Cross-Origin-Opener-Policy", "same-origin" },
        .{ "Cross-Origin-Embedder-Policy", "require-corp" },
    }), .{});
    router.get("/ws", ws, .{});

    server_ref = &server;
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);
    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    try controller.start();
    try server.listen();

    try controller.stop();
}

////////////////////////////////////////////////////////////////////////////////
// Routes
////////////////////////////////////////////////////////////////////////////////

fn staticFileHandler(path: []const u8, headers: []const struct { []const u8, []const u8 }) fn (handler: HttpHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const gen = struct {
        fn handler(_: HttpHandler, _: *httpz.Request, res: *httpz.Response) !void {
            res.content_type = comptime httpz.ContentType.forFile(path);
            res.body = @embedFile("dist" ++ path);
            inline for (headers) |header| res.headers.add(header[0], header[1]);
        }
    };
    return gen.handler;
}

fn ws(handler: HttpHandler, req: *httpz.Request, res: *httpz.Response) !void {
    if (try httpz.upgradeWebsocket(HttpHandler.WebsocketHandler, req, res, &HttpHandler.WebsocketHandler.Context{ .controller = handler.controller }) == false) {
        res.status = 500;
        res.body = "Invalid websocket";
    }
}

////////////////////////////////////////////////////////////////////////////////
// Shutdown Handler
////////////////////////////////////////////////////////////////////////////////

var server_ref: ?*httpz.Server(HttpHandler) = null;

fn shutdown(_: c_int) callconv(.C) void {
    if (server_ref) |server| {
        server_ref = null;
        server.stop();
    }
}
