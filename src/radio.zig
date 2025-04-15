const std = @import("std");
const builtin = @import("builtin");

const radio = @import("radio");

////////////////////////////////////////////////////////////////////////////////
// Radio API Types
////////////////////////////////////////////////////////////////////////////////

pub const RadioConfiguration = struct {};

pub const RadioEvent = union(enum) {
    status: struct {
        frequency: f64,
        power_dbfs: f32,
        audio_bandwidth: f32,
        audio_agc_mode: AudioAgcMode,
    },

    audio: struct {
        samples: []const u8,
    },

    scan: struct {
        frequency: f64,
        power_dbfs: f32,
        timestamp: u64,
    },
};

pub const FrequencySweep = struct {
    start: f64,
    stop: f64,
    step: f64,
};

pub const AudioAgcMode = radio.blocks.AGCBlock(f32).Mode;

////////////////////////////////////////////////////////////////////////////////
// Mock Radio Implementation
////////////////////////////////////////////////////////////////////////////////

pub const MockRadioImpl = struct {
    allocator: std.mem.Allocator,

    // Radio state
    mutex: std.Thread.Mutex = .{},
    frequency: f64,
    audio_bandwidth: f32,
    audio_agc_mode: AudioAgcMode,
    scan_sweeps: ?[]const FrequencySweep = null,
    scan_abort_event: std.Thread.ResetEvent = .{},

    // Thread state
    thread: std.Thread = undefined,
    stop_event: std.Thread.ResetEvent = .{},
    event_callback: struct {
        context: *anyopaque,
        function: *const fn (context: *anyopaque, event: RadioEvent) void,
    } = undefined,

    pub fn init(allocator: std.mem.Allocator, _: RadioConfiguration) !MockRadioImpl {
        return .{ .allocator = allocator, .frequency = 5000e3, .audio_bandwidth = 5e3, .audio_agc_mode = .{ .preset = .Slow } };
    }

    pub fn deinit(_: *MockRadioImpl) void {}

    pub fn start(self: *MockRadioImpl, context: *anyopaque, callback: *const fn (context: *anyopaque, event: RadioEvent) void) !void {
        const Runner = struct {
            fn run(s: *MockRadioImpl) !void {
                var prng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp()));

                var tic: i64 = std.time.microTimestamp();
                var last_status_timestamp: i64 = 0;
                var phase: f32 = 0;
                var samples: [4800]f32 = undefined;

                while (true) {
                    if (s.stop_event.isSet()) break;

                    std.time.sleep(50 * std.time.ns_per_ms);

                    s.mutex.lock();
                    defer s.mutex.unlock();

                    if (s.scan_sweeps) |sweeps| {
                        try s._scan(sweeps);
                        s.allocator.free(sweeps);
                        s.scan_sweeps = null;
                    }

                    // Emit audio samples
                    const toc = std.time.microTimestamp();
                    const count = @min(@as(usize, @intCast(@divFloor(((toc - tic) * 48000), 1000000))), samples.len);
                    const omega = 2 * std.math.pi * ((@as(f32, @floatCast(s.frequency)) / 10000) / 48000);
                    for (samples[0..count]) |*sample| {
                        sample.* = std.math.cos(phase);
                        phase = @mod(phase + omega, 2 * std.math.pi);
                    }
                    s.event_callback.function(s.event_callback.context, .{ .audio = .{ .samples = std.mem.sliceAsBytes(samples[0..count]) } });
                    tic = std.time.microTimestamp();

                    // Emit status once a second
                    if (toc - last_status_timestamp > 1 * std.time.us_per_s) {
                        s.event_callback.function(s.event_callback.context, .{ .status = .{ .frequency = s.frequency, .power_dbfs = -20 + 5 * prng.random().float(f32), .audio_bandwidth = s.audio_bandwidth, .audio_agc_mode = s.audio_agc_mode } });
                        last_status_timestamp = toc;
                    }
                }
            }
        };

        self.event_callback.context = context;
        self.event_callback.function = callback;
        self.thread = try std.Thread.spawn(.{}, Runner.run, .{self});
    }

    pub fn stop(self: *MockRadioImpl) !void {
        self.scan_abort_event.set();
        self.stop_event.set();
        self.thread.join();
    }

    pub fn _scan(self: *MockRadioImpl, sweeps: []const FrequencySweep) !void {
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp()));

        outer: for (sweeps) |sweep| {
            var freq = sweep.start;
            while (freq <= sweep.stop) : (freq += sweep.step) {
                if (self.scan_abort_event.isSet()) {
                    self.scan_abort_event.reset();
                    break :outer;
                }

                std.time.sleep(100 * std.time.ns_per_ms);
                self.event_callback.function(self.event_callback.context, .{ .scan = .{ .frequency = freq, .power_dbfs = -60 + 55 * prng.random().float(f32), .timestamp = @intCast(std.time.milliTimestamp()) } });
            }
        }
    }

    pub fn scan(self: *MockRadioImpl, sweeps: []const FrequencySweep) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.scan_sweeps = try self.allocator.dupe(FrequencySweep, sweeps);
    }

    pub fn abortScan(self: *MockRadioImpl) !void {
        if (!self.scan_abort_event.isSet()) {
            self.scan_abort_event.set();
        }
    }

    pub fn tune(self: *MockRadioImpl, frequency: f64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (frequency < 500e3 or frequency > 31e6) {
            return error.OutOfBounds;
        }

        self.frequency = frequency;
    }

    pub fn setAudioBandwidth(self: *MockRadioImpl, bandwidth: f32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (bandwidth < 1e3 or bandwidth > 10e3) {
            return error.OutOfBounds;
        }

        self.audio_bandwidth = bandwidth;
    }

    pub fn setAudioAgcMode(self: *MockRadioImpl, mode: AudioAgcMode) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.audio_agc_mode = mode;
    }
};

////////////////////////////////////////////////////////////////////////////////
// ZigRadio Implementation
////////////////////////////////////////////////////////////////////////////////

pub const ZigRadioImpl = struct {};
