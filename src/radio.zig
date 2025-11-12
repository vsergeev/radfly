const std = @import("std");
const builtin = @import("builtin");

const radio = @import("radio");

////////////////////////////////////////////////////////////////////////////////
// Radio API Types
////////////////////////////////////////////////////////////////////////////////

pub const RadioConfiguration = struct {
    source: enum {
        mock,
        rtlsdr,
        airspyhf,
    } = .mock,
    bias_tee: bool = false,
    tune_offset: ?f32 = -50e3,
    initial_frequency: f64 = 5000e3,
    debug: bool = false,
};

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

                    std.Thread.sleep(50 * std.time.ns_per_ms);

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

                std.Thread.sleep(100 * std.time.ns_per_ms);
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

pub const ZigRadioImpl = struct {
    // Constants
    pub const MIN_AUDIO_SAMPLES = 100;
    pub const SCAN_POWER_SAMPLES = 5;

    // Config
    allocator: std.mem.Allocator,
    config: RadioConfiguration,

    // Flowgraph state
    flowgraph: struct {
        top: radio.Flowgraph,
        source: union(enum) {
            rtlsdr: radio.blocks.RtlSdrSource,
            airspyhf: radio.blocks.AirspyHFSource,
        },
        tuner: radio.blocks.TunerBlock,
        am_demod: radio.blocks.AMEnvelopeDemodulatorBlock,
        power_filter: radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 32),
        power_meter: radio.blocks.PowerMeterBlock(std.math.Complex(f32)),
        af_gain: radio.blocks.AGCBlock(f32),
        af_downsampler: radio.blocks.DownsamplerBlock(f32),
        audio_sink: radio.blocks.ApplicationSink(f32),
        power_sink: radio.blocks.ApplicationSink(f32),
    },

    // Parameter state
    mutex: std.Thread.Mutex = .{},
    frequency: f64,
    audio_bandwidth: f32,
    audio_agc_mode: AudioAgcMode,
    power: f32,
    scan_sweeps: ?[]const FrequencySweep = null,
    scan_abort_event: std.Thread.ResetEvent = .{},

    // Thread state
    thread: std.Thread = undefined,
    stop_event: std.Thread.ResetEvent = .{},
    event_callback: struct {
        context: *anyopaque,
        function: *const fn (context: *anyopaque, event: RadioEvent) void,
    } = undefined,

    pub fn init(allocator: std.mem.Allocator, config: RadioConfiguration) !ZigRadioImpl {
        return .{
            .allocator = allocator,
            .config = config,
            .flowgraph = .{
                .top = radio.Flowgraph.init(allocator, .{ .debug = config.debug }),
                .source = switch (config.source) {
                    .rtlsdr => .{ .rtlsdr = radio.blocks.RtlSdrSource.init(config.initial_frequency + (config.tune_offset orelse 0), 960e3, .{ .debug = config.debug, .bias_tee = config.bias_tee }) },
                    .airspyhf => .{ .airspyhf = radio.blocks.AirspyHFSource.init(config.initial_frequency + (config.tune_offset orelse 0), 384e3, .{ .debug = config.debug }) },
                    else => return error.UnsupportedSource,
                },
                .tuner = radio.blocks.TunerBlock.init(config.tune_offset orelse 0, 10e3, switch (config.source) {
                    .rtlsdr => 10,
                    .airspyhf => 4,
                    else => unreachable,
                }),
                .am_demod = radio.blocks.AMEnvelopeDemodulatorBlock.init(.{ .bandwidth = 5e3 }),
                .power_filter = radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 32).init(0.5e3, .{}),
                .power_meter = radio.blocks.PowerMeterBlock(std.math.Complex(f32)).init(50, .{}),
                .af_gain = radio.blocks.AGCBlock(f32).init(.{ .preset = .Medium }, .{}),
                .af_downsampler = radio.blocks.DownsamplerBlock(f32).init(2),
                .audio_sink = radio.blocks.ApplicationSink(f32).init(),
                .power_sink = radio.blocks.ApplicationSink(f32).init(),
            },
            .frequency = config.initial_frequency,
            .audio_bandwidth = 5e3,
            .audio_agc_mode = .{ .preset = .Medium },
            .power = 0,
        };
    }

    pub fn deinit(self: *ZigRadioImpl) void {
        self.flowgraph.top.deinit();
    }

    pub fn start(self: *ZigRadioImpl, context: *anyopaque, callback: *const fn (context: *anyopaque, event: RadioEvent) void) !void {
        // Build flowgraph
        try self.flowgraph.top.connect(switch (self.flowgraph.source) {
            inline else => |*source| &source.block,
        }, &self.flowgraph.tuner.block);
        try self.flowgraph.top.connect(&self.flowgraph.tuner.block, &self.flowgraph.am_demod.block);
        try self.flowgraph.top.connect(&self.flowgraph.am_demod.block, &self.flowgraph.af_gain.block);
        try self.flowgraph.top.connect(&self.flowgraph.af_gain.block, &self.flowgraph.af_downsampler.block);
        try self.flowgraph.top.connect(&self.flowgraph.af_downsampler.block, &self.flowgraph.audio_sink.block);
        try self.flowgraph.top.connect(&self.flowgraph.tuner.block, &self.flowgraph.power_filter.block);
        try self.flowgraph.top.connect(&self.flowgraph.power_filter.block, &self.flowgraph.power_meter.block);
        try self.flowgraph.top.connect(&self.flowgraph.power_meter.block, &self.flowgraph.power_sink.block);

        // Start flowgraph
        try self.flowgraph.top.start();

        const Runner = struct {
            fn run(s: *ZigRadioImpl) !void {
                var tic: i64 = std.time.microTimestamp();

                while (true) {
                    if (s.stop_event.isSet()) break;

                    // Wait for audio samples
                    s.flowgraph.audio_sink.wait(MIN_AUDIO_SAMPLES, 10 * std.time.ns_per_ms) catch |err| switch (err) {
                        error.Timeout => continue,
                        else => return err,
                    };

                    s.mutex.lock();
                    defer s.mutex.unlock();

                    // Handle scanning
                    if (s.scan_sweeps) |sweeps| {
                        try s._scan(sweeps);
                        s.allocator.free(sweeps);
                        s.scan_sweeps = null;
                        continue;
                    }

                    // Emit audio samples
                    const audio_samples = s.flowgraph.audio_sink.get();
                    s.event_callback.function(s.event_callback.context, .{ .audio = .{ .samples = std.mem.sliceAsBytes(audio_samples) } });
                    s.flowgraph.audio_sink.update(audio_samples.len);

                    // Check for power samples
                    if (try s.flowgraph.power_sink.available() > 0) {
                        const power_samples = s.flowgraph.power_sink.get();
                        s.power = power_samples[power_samples.len - 1];
                        s.flowgraph.power_sink.update(power_samples.len);
                    }

                    // Emit status once a second
                    const toc = std.time.microTimestamp();
                    if (toc - tic > 1 * std.time.us_per_s) {
                        s.event_callback.function(s.event_callback.context, .{ .status = .{ .frequency = s.frequency, .power_dbfs = s.power, .audio_bandwidth = s.audio_bandwidth, .audio_agc_mode = s.audio_agc_mode } });
                        tic = toc;
                    }
                }
            }
        };

        // Start thread
        self.event_callback.context = context;
        self.event_callback.function = callback;
        self.thread = try std.Thread.spawn(.{}, Runner.run, .{self});
    }

    pub fn stop(self: *ZigRadioImpl) !void {
        self.scan_abort_event.set();
        self.stop_event.set();
        self.thread.join();
        _ = try self.flowgraph.top.stop();
    }

    fn _tune(self: *ZigRadioImpl, frequency: f64) !void {
        try switch (self.flowgraph.source) {
            inline else => |*source| self.flowgraph.top.call(&source.block, @TypeOf(source.*).setFrequency, .{frequency + (self.config.tune_offset orelse 0)}),
        };
    }

    pub fn _scan(self: *ZigRadioImpl, sweeps: []const FrequencySweep) !void {
        outer: for (sweeps) |sweep| {
            var frequency = sweep.start;
            while (frequency <= sweep.stop) : (frequency += sweep.step) {
                // Check for scan abort
                if (self.scan_abort_event.isSet()) {
                    self.scan_abort_event.reset();
                    break :outer;
                }

                // Tune
                try self._tune(frequency);

                // Wait
                std.Thread.sleep(50 * std.time.ns_per_ms);

                // Flush power meter
                try self.flowgraph.top.call(&self.flowgraph.power_meter.block, radio.blocks.PowerMeterBlock(std.math.Complex(f32)).reset, .{});

                // Read power meter until flush
                while (true) {
                    try self.flowgraph.power_sink.wait(1, null);
                    if (std.math.isNan(self.flowgraph.power_sink.pop().?)) break;
                }

                // Read power meter N times and average
                var power_dbfs: f32 = 0;
                for (0..SCAN_POWER_SAMPLES) |_| {
                    try self.flowgraph.power_sink.wait(1, null);
                    const power_sample = self.flowgraph.power_sink.pop().?;
                    power_dbfs += power_sample;
                }
                power_dbfs /= SCAN_POWER_SAMPLES;

                // Stream scan frame
                self.event_callback.function(self.event_callback.context, .{ .scan = .{ .frequency = frequency, .power_dbfs = power_dbfs, .timestamp = @intCast(std.time.milliTimestamp()) } });

                // Discard audio sink samples
                try self.flowgraph.audio_sink.discard();
            }
        }

        try self._tune(self.frequency);
        try self.flowgraph.top.call(&self.flowgraph.af_gain.block, radio.blocks.AGCBlock(f32).reset, .{});
    }

    pub fn scan(self: *ZigRadioImpl, sweeps: []const FrequencySweep) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.scan_sweeps = try self.allocator.dupe(FrequencySweep, sweeps);
    }

    pub fn abortScan(self: *ZigRadioImpl) !void {
        if (!self.scan_abort_event.isSet()) {
            self.scan_abort_event.set();
        }
    }

    pub fn tune(self: *ZigRadioImpl, frequency: f64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self._tune(frequency);
        try self.flowgraph.top.call(&self.flowgraph.af_gain.block, radio.blocks.AGCBlock(f32).reset, .{});

        self.frequency = frequency;
    }

    pub fn setAudioBandwidth(self: *ZigRadioImpl, bandwidth: f32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.flowgraph.top.call(&self.flowgraph.am_demod.block, radio.blocks.AMEnvelopeDemodulatorBlock.setBandwidth, .{bandwidth});

        self.audio_bandwidth = bandwidth;
    }

    pub fn setAudioAgcMode(self: *ZigRadioImpl, mode: AudioAgcMode) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.flowgraph.top.call(&self.flowgraph.af_gain.block, radio.blocks.AGCBlock(f32).setMode, .{mode});

        self.audio_agc_mode = mode;
    }
};
