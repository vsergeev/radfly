const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;

const RadioController = @import("controller.zig").RadioController;
const HttpHandler = @import("handler.zig").HttpHandler;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var controller = try RadioController(HttpHandler.WebsocketHandler).init(gpa.allocator(), .{});
    defer controller.deinit();

    var server = try httpz.Server(HttpHandler).init(gpa.allocator(), .{ .port = 8000 }, HttpHandler.init(&controller));
    defer server.deinit();

    var router = try server.router(.{});
    router.get("/", index, .{});
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

fn index(_: HttpHandler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body = @embedFile("index.html");
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
