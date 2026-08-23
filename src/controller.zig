const std = @import("std");

const RadioConfiguration = @import("radio.zig").RadioConfiguration;
const MockRadioImpl = @import("radio.zig").MockRadioImpl;
const ZigRadioImpl = @import("radio.zig").ZigRadioImpl;

const RadioEvent = @import("radio.zig").RadioEvent;
const FrequencySweep = @import("radio.zig").FrequencySweep;
const AudioAgcMode = @import("radio.zig").AudioAgcMode;

pub fn RadioController(ListenerType: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        radio: union(enum) {
            mock: MockRadioImpl,
            zigradio: ZigRadioImpl,
        },
        listeners_mutex: std.Io.Mutex = .init,
        listeners: std.AutoHashMap(*ListenerType, void) = undefined,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: RadioConfiguration) !Self {
            return .{
                .io = io,
                .radio = switch (config.source) {
                    .mock => .{ .mock = try MockRadioImpl.init(allocator, io, config) },
                    else => .{ .zigradio = try ZigRadioImpl.init(allocator, io, config) },
                },
                .listeners = std.AutoHashMap(*ListenerType, void).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            switch (self.radio) {
                inline else => |*radio| radio.deinit(),
            }
            self.listeners.deinit();
        }

        pub fn start(self: *Self) !void {
            const gen = struct {
                fn callback(ptr: *anyopaque, event: RadioEvent) void {
                    @as(*Self, @ptrCast(@alignCast(ptr))).onRadioEvent(event);
                }
            };

            switch (self.radio) {
                inline else => |*radio| try radio.start(self, gen.callback),
            }
        }

        pub fn stop(self: *Self) !void {
            switch (self.radio) {
                inline else => |*radio| try radio.stop(),
            }
        }

        pub fn addListener(self: *Self, listener: *ListenerType) !void {
            self.listeners_mutex.lockUncancelable(self.io);
            defer self.listeners_mutex.unlock(self.io);

            try self.listeners.put(listener, {});
        }

        pub fn removeListener(self: *Self, listener: *ListenerType) void {
            self.listeners_mutex.lockUncancelable(self.io);
            defer self.listeners_mutex.unlock(self.io);

            _ = self.listeners.remove(listener);
        }

        pub fn scan(self: *Self, sweeps: []const FrequencySweep) !void {
            return switch (self.radio) {
                inline else => |*radio| radio.scan(sweeps),
            };
        }

        pub fn abortScan(self: *Self) !void {
            return switch (self.radio) {
                inline else => |*radio| radio.abortScan(),
            };
        }

        pub fn tune(self: *Self, frequency: f32) !void {
            return switch (self.radio) {
                inline else => |*radio| radio.tune(frequency),
            };
        }

        pub fn setAudioBandwidth(self: *Self, bandwidth: f32) !void {
            return switch (self.radio) {
                inline else => |*radio| radio.setAudioBandwidth(bandwidth),
            };
        }

        pub fn setAudioAgcMode(self: *Self, mode: AudioAgcMode) !void {
            return switch (self.radio) {
                inline else => |*radio| radio.setAudioAgcMode(mode),
            };
        }

        pub fn onRadioEvent(self: *Self, event: RadioEvent) void {
            self.listeners_mutex.lockUncancelable(self.io);
            defer self.listeners_mutex.unlock(self.io);

            var listener_it = self.listeners.keyIterator();
            while (listener_it.next()) |listener| {
                listener.*.onRadioEvent(event) catch continue;
            }
        }
    };
}
