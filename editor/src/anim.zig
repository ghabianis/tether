const std = @import("std");
const math = @import("./math.zig");

const print = std.debug.print;

pub const Interpolation = enum {
    Constant,
    Linear,
    Cubic,
};

/// T must be a type with the following functions:
/// - add(T, T) -> T
/// - mul_f(T, f32) -> T
/// - default() -> T
/// - interpolate(T, T, f32) -> T
/// - hermite(f32, T, T, T, T) -> T
pub fn Track(comptime T: type) type {
    return struct {
        const Self = @This();
        frames: []const Frame,
        interp: Interpolation,

        pub const Frame = struct {
            time: f32,
            value: T,
            in: T,
            out: T,
        };

        pub fn adjust_time_to_fit(self: *const Self, time_: f32, looping: bool) f32 {
            const len = self.frames.len;
            if (len <= 1) return 0.0;

            const start_time = self.frames[0].time;
            const end_time = self.frames[len - 1].time;
            const duration = end_time - start_time;

            var time = time_;
            if (duration <= 0.0) return 0.0;
            
            if (looping) {
                time = @mod(time - start_time, end_time - start_time);
                if (time < 0.0) {
                    time += end_time - start_time;
                }
                time = time + start_time;
            } else {
                if (time <= self.frames[0].time) {
                    time = start_time;
                }
                if (time >= self.frames[len - 1].time) {
                    time = end_time;
                }
            }

            return time;
        }

        pub fn frame_idx(self: *const Self, time_: f32, looping: bool) ?usize {
            const len = self.frames.len;
            if (len <= 1) return null;

            var time: f32 = time_;

            if (looping) {
                const start_time = self.frames[0].time;
                const end_time = self.frames[len - 1].time;
                const duration = end_time - start_time;
                _ = duration;
                time = @mod(time - start_time, end_time - end_time);
                if (time < 0.0) {
                    time += end_time - start_time;
                }
                time = time + start_time;
            } else {
                if (time <= self.frames[0].time) {
                    return 0;
                }
                if (time >= self.frames[len - 1].time) {
                    return len - 2;
                }
            }

            var i = len - 1;
            while (i >= 0): (i -= 1) {
                if (time >= self.frames[i].time) {
                    return i;
                }
            }

            return null;
        }


        pub fn sample(self: *const Self, time: f32, looping: bool) T {
            const frame = self.frame_idx(time, looping) orelse return T.default();
            std.debug.assert(!(frame >= self.frames.len -| 1));

            switch (self.interp) {
                .Constant => return self.sample_constant(),
                .Linear => return self.sample_linear(time, looping, frame),
                .Cubic => return self.sample_cubic(time, looping, frame),
            }
        }

        fn sample_constant(self: *const Self) T {
            return self.frames[0].value;
        }
            
        fn sample_linear(self: *const Self, time: f32, looping: bool, frame: usize) T {
            const next_frame = frame + 1;

            const track_time = self.adjust_time_to_fit(time, looping);
            const end_time = self.frames[next_frame].time;
            const start_time = self.frames[frame].time;
            const frame_delta = end_time - start_time;
            if (frame_delta <= 0) {
                return T.default();
            }

            const t = (track_time - self.frames[frame].time) / frame_delta;
            const start = self.frames[frame].value;
            const end = self.frames[next_frame].value;
            return T.interpolate(start, end, t);
        }

        fn sample_cubic(self: *const Self, time: f32, looping: bool, frame: usize) T {
            const next_frame = frame + 1;

            const track_time = self.adjust_time_to_fit(time, looping);
            const frame_delta = self.frames[next_frame].time - self.frames[frame].time;

            if (frame_delta <= 0) return T.default();

            const t = (track_time - self.frames[frame].time) / frame_delta;
            
            const point1 = self.frames[frame].value;
            const point2 = self.frames[next_frame].value;
            var slope1 = self.frames[frame].out;
            var slope2 = self.frames[next_frame].in;
            
            slope1 = slope1.mul_f(frame_delta);
            slope2 = slope2.mul_f(frame_delta);
            return T.hermite(t, point1, slope1, point2, slope2);
        }
    };
}

pub const ScalarTrack = Track(math.Scalar);
pub const Float2Track = Track(math.Float2);
pub const Float3Track = Track(math.Float3);
pub const QuatTrack = Track(math.Quat);
