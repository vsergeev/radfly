const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;

const RadioConfiguration = @import("radio.zig").RadioConfiguration;
const RadioController = @import("controller.zig").RadioController;
const HttpHandler = @import("handler.zig").HttpHandler;

const VERSION = @import("build_options").VERSION;
const FRONTEND_ASSETS = @import("build_options").FRONTEND_ASSETS;

////////////////////////////////////////////////////////////////////////////////
// Usage and Argument Parsing
////////////////////////////////////////////////////////////////////////////////

pub fn printUsage() !void {
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    return stderr_writer.interface.writeAll(
        \\Usage: radfly [options]
        \\
        \\Radio Configuration
        \\  --source <mock,rtlsdr,airspyhf>     SDR Source (default mock)
        \\  --device-index <index>              Device index (default 0)
        \\  --bias-tee <true/false>             Bias tee (default false)
        \\  --tune-offset <value in KHz>        Tune offset (default 50 KHz)
        \\  --initial-frequency <value in KHz>  Initial frequency (default 5000 KHz)
        \\
        \\Server Configuration
        \\  --http-port <port number>           HTTP listening port (default 8000)
        \\  --http-address <address>            HTTP listening address (default 127.0.0.1)
        \\
        \\Miscellaneous
        \\  --help                              Display usage
        \\  --version                           Display version
        \\  --debug                             Enable debug mode
    ++ "\n");
}

pub fn parseArgument(comptime T: anytype, arg_: ?([:0]const u8), context: []const u8) !T {
    if (arg_) |arg| {
        return @as(anyerror!T, blk: {
            if (T == []const u8) {
                break :blk arg;
            } else if (@typeInfo(T) == .@"enum") {
                break :blk std.meta.stringToEnum(T, arg) orelse error.InvalidArgument;
            } else if (T == bool) {
                if (std.mem.eql(u8, "true", arg)) {
                    break :blk true;
                } else if (std.mem.eql(u8, "false", arg)) {
                    break :blk false;
                } else {
                    break :blk error.InvalidArgument;
                }
            } else if (@typeInfo(T) == .float) {
                break :blk std.fmt.parseFloat(T, arg) catch error.InvalidArgument;
            } else if (@typeInfo(T) == .int) {
                break :blk std.fmt.parseInt(T, arg, 10) catch error.InvalidArgument;
            } else {
                @compileError("Unsupported type " ++ @typeName(T));
            }
        }) catch {
            std.log.err("Invalid value for argument \"{s}\"\n", .{context});
            try printUsage();
            std.process.exit(1);
        };
    } else {
        std.log.err("Missing value for argument \"{s}\"\n", .{context});
        try printUsage();
        std.process.exit(1);
    }
}

////////////////////////////////////////////////////////////////////////////////
// Top-level Configuration
////////////////////////////////////////////////////////////////////////////////

pub const Configuration = struct {
    radio: RadioConfiguration = .{},
    server: struct {
        http_port: u16 = 8000,
        http_address: []const u8 = "127.0.0.1",
    } = .{},
};

////////////////////////////////////////////////////////////////////////////////
// Logging Options
////////////////////////////////////////////////////////////////////////////////

pub const std_options = std.Options{
    .log_level = .info,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .websocket, .level = .err },
    },
};

////////////////////////////////////////////////////////////////////////////////
// Entry Point
////////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var config: Configuration = .{};

    // Handle Arguments

    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--source")) {
            config.radio.source = try parseArgument(@TypeOf(config.radio.source), args.next(), "--source");
        } else if (std.mem.eql(u8, arg, "--device-index")) {
            config.radio.device_index = try parseArgument(usize, args.next(), "--device-index");
        } else if (std.mem.eql(u8, arg, "--bias-tee")) {
            config.radio.bias_tee = try parseArgument(bool, args.next(), "--bias-tee");
        } else if (std.mem.eql(u8, arg, "--tune-offset")) {
            config.radio.tune_offset = try parseArgument(f32, args.next(), "--tune-offset");
        } else if (std.mem.eql(u8, arg, "--initial-frequency")) {
            config.radio.initial_frequency = try parseArgument(f64, args.next(), "--initial-frequency");
        } else if (std.mem.eql(u8, arg, "--http-port")) {
            config.server.http_port = try parseArgument(u16, args.next(), "--http-port");
        } else if (std.mem.eql(u8, arg, "--http-address")) {
            config.server.http_address = try parseArgument([]const u8, args.next(), "--http-address");
        } else if (std.mem.eql(u8, arg, "--debug")) {
            config.radio.debug = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            return printUsage();
        } else if (std.mem.eql(u8, arg, "--version")) {
            var stdout_writer = std.fs.File.stdout().writer(&.{});
            return stdout_writer.interface.writeAll(VERSION ++ "\n");
        } else {
            std.log.err("Unknown argument \"{s}\"\n", .{arg});
            try printUsage();
            std.process.exit(1);
        }
    }

    // Validate Configuration

    if (config.radio.source == .airspyhf and config.radio.device_index != 0) {
        std.log.err("Device index option not supported for airspyhf source.", .{});
        std.process.exit(1);
    }

    std.log.info("Starting with configuration: {}", .{config});

    // Initialization

    var controller = try RadioController(HttpHandler.WebsocketHandler).init(gpa.allocator(), config.radio);
    defer controller.deinit();

    var server = try httpz.Server(HttpHandler).init(gpa.allocator(), .{ .address = config.server.http_address, .port = config.server.http_port }, HttpHandler.init(&controller));
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
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    try controller.start();
    try server.listen();

    // Shutdown

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

fn shutdown(_: c_int) callconv(.c) void {
    if (server_ref) |server| {
        server_ref = null;
        server.stop();
    }
}
