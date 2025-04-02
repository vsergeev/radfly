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

        radio: union(enum) {
            mock: MockRadioImpl,
        },
        listeners_mutex: std.Thread.Mutex = .{},
        listeners: std.AutoHashMap(*ListenerType, void) = undefined,

        pub fn init(allocator: std.mem.Allocator, config: RadioConfiguration) !Self {
            return .{
                .radio = .{ .mock = try MockRadioImpl.init(allocator, config) },
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
            self.listeners_mutex.lock();
            defer self.listeners_mutex.unlock();

            try self.listeners.put(listener, {});
        }

        pub fn removeListener(self: *Self, listener: *ListenerType) void {
            self.listeners_mutex.lock();
            defer self.listeners_mutex.unlock();

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
            self.listeners_mutex.lock();
            defer self.listeners_mutex.unlock();

            var listener_it = self.listeners.keyIterator();
            while (listener_it.next()) |listener| {
                listener.*.onRadioEvent(event) catch continue;
            }
        }
    };
}
