const std = @import("std");
const debug = std.debug;
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const posix = std.posix;

const SerialportHandle = switch (native_os) {
    .windows => std.os.windows.HANDLE,
    // I could possibly fit more
    .linux, .netbsd => posix.fd_t,
    else => @panic("Not implemented"),
};

pub const Speed = u64;
pub const BitWidth = usize;
pub const Parity = enum { None, Odd, Even, Mark, Space };
pub const StopBits = enum { Zero5, One, One5, Two };
pub const FlowControl = enum { None, XONXOFF, CTSRTS };
pub const Mode = enum { Blocking, NonBlocking };

extern "c" fn cfsetispeed(termios_p: *posix.termios, speed: posix.speed_t) c_int;
extern "c" fn cfsetospeed(termios_p: *posix.termios, speed: posix.speed_t) c_int;

pub const OptionError = error{UnsupportedValue};

pub fn fromSpeed_t(posix_speed: posix.speed_t) !Speed {
    return @intCast(@intFromEnum(posix_speed));
}

/// more or less "cross-platform" options struct.
/// Defaults to 9600 8N1 with no flow control
pub const Options = struct {
    speed: Speed = fromSpeed_t(.B9600) catch @enumFromInt(posix.speed_t.B9600),
    bit_width: BitWidth = 8,
    parity: Parity = .None,
    stop_bits: StopBits = .One,
    flow_control: FlowControl = .None,
    mode: Mode = .NonBlocking,
};

pub const SerialPort = struct {
    const InnerType: type = switch (native_os) {
        .windows => @panic("Not implemented"),
        .linux => SerialPortPosix,
        else => @panic("Not implemented"),
    };

    inner: InnerType,

    pub fn init(devname: []const u8, opts: Options) SerialPort {
        return SerialPort{
            .inner = InnerType.init(devname, opts) catch unreachable,
        };
    }

    pub fn setSpeed(self: *@This(), new_speed: u64) !void {
        return try self.inner.setSpeed(new_speed);
    }

    pub fn setParity(self: *@This(), new_parity: Parity) !void {
        return try self.inner.setParity(new_parity);
    }

    pub fn setBitWidth(self: *@This(), new_width: BitWidth) !void {
        return try self.inner.setBitWidth(new_width);
    }

    pub fn deinit(self: *@This()) void {
        return self.inner.deinit();
    }

    pub fn writer(self: *@This()) @This().InnerType.Writer {
        return self.inner.writer();
    }

    pub fn reader(self: *@This()) @This().InnerType.Reader {
        return self.inner.reader();
    }
};

pub const SerialPortPosix = struct {
    name: []const u8,
    handle: SerialportHandle,
    initial_config: posix.termios,
    const Writer = std.io.GenericWriter(@This(), posix.WriteError, write);
    const Reader = std.io.GenericReader(@This(), posix.ReadError, read);

    pub fn init(devname: []const u8, opt: Options) !@This() {
        var res: @This() = undefined;

        if (opt.mode == .NonBlocking) {
            std.log.warn("option {s} not supported", .{@tagName(opt.mode)});
        }

        const flags = posix.O{
            .ACCMODE = .RDWR,
            .NONBLOCK = (false and opt.mode == .NonBlocking),
        };
        const fdt = try posix.open(devname, flags, 0);
        errdefer posix.close(fdt);
        {
            var attrs = try posix.tcgetattr(fdt);
            res.initial_config = attrs;
            {
                attrs.iflag.IGNBRK = false;
                attrs.iflag.BRKINT = true;
                attrs.iflag.PARMRK = false;
                attrs.iflag.ISTRIP = false;
                attrs.iflag.INLCR = false;
                attrs.iflag.IGNCR = false;
                attrs.iflag.ICRNL = false;
                attrs.iflag.IXON = false;
            }
            attrs.oflag.OPOST = false;
            {
                attrs.lflag.ECHO = false;
                attrs.lflag.ECHONL = false;
                attrs.lflag.ICANON = false;
                attrs.lflag.ISIG = false;
                attrs.lflag.IEXTEN = false;
            }
            attrs.cflag = .{ .CREAD = true };
            try posix.tcsetattr(fdt, posix.TCSA.NOW, attrs);
        }
        try validateOptions(opt);

        res.name = devname;
        res.handle = fdt;

        try res.setSpeed(opt.speed);
        try res.setBitWidth(opt.bit_width);
        try res.setParity(opt.parity);
        return res;
    }

    pub fn deinit(self: *@This()) void {
        posix.tcsetattr(self.handle, .DRAIN, self.initial_config) catch unreachable;
        posix.close(self.handle);
    }

    fn validateOptions(opts: Options) !void {
        if (std.meta.intToEnum(posix.speed_t, opts.speed)) |_| {} else |_| {
            return OptionError.UnsupportedValue;
        }
        // Technically some implementation do not necessarily need to support
        // CS5 and CS6, however they still technically fit into the CS field.
        if ((opts.bit_width < 5) or (opts.bit_width > 8)) {
            return OptionError.UnsupportedValue;
        }
        switch (opts.parity) {
            .None, .Even, .Odd => {},
            else => return OptionError.UnsupportedValue,
        }
        switch (opts.stop_bits) {
            .One, .Two => {},
            else => return OptionError.UnsupportedValue,
        }
        if (opts.flow_control == .CTSRTS) {
            if (@hasField(posix.tc_cflag_t, "CRTSCCTS") or
                (@hasField(posix.tc_cflag_t, "CCTS_OFLOW") and
                @hasField(posix.tc_cflag_t, "CRTS_IFLOW")))
            {
                return OptionError.UnsupportedValue;
            }
        }
    }

    pub fn setSpeed(self: *@This(), new_speed: u64) !void {
        var attrs = try posix.tcgetattr(self.handle);
        const sp: posix.speed_t = @enumFromInt(new_speed);
        if (cfsetispeed(&attrs, sp) != 0) {
            return error.CannotSetSpeed;
        }
        if (cfsetospeed(&attrs, sp) != 0) {
            return error.CannotSetSpeed;
        }
        try posix.tcsetattr(self.handle, .NOW, attrs);
    }

    pub fn setParity(self: *@This(), new_parity: Parity) !void {
        var attrs = try posix.tcgetattr(self.handle);
        attrs.cflag.PARENB = (new_parity != .None);
        attrs.cflag.PARODD = (new_parity == .Odd);
        try posix.tcsetattr(self.handle, .NOW, attrs);
    }

    pub fn setBitWidth(self: *@This(), new_width: BitWidth) !void {
        var attrs = try posix.tcgetattr(self.handle);
        attrs.cflag.CSIZE = switch (new_width) {
            5 => .CS5,
            6 => .CS6,
            7 => .CS7,
            8 => .CS8,
            else => .CS8,
        };
        try posix.tcsetattr(self.handle, .NOW, attrs);
    }

    pub fn writer(self: @This()) @This().Writer {
        return @This().Writer{
            .context = self,
        };
    }

    fn write(self: @This(), bytes: []const u8) posix.WriteError!usize {
        return posix.write(self.handle, bytes);
    }

    pub fn reader(self: @This()) @This().Reader {
        return @This().Reader{
            .context = self,
        };
    }

    fn read(self: @This(), buf: []u8) posix.ReadError!usize {
        return try posix.read(self.handle, buf);
    }
};
