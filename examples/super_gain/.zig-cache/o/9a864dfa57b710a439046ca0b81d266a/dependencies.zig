pub const packages = struct {
    pub const @"../.." = struct {
        pub const build_root = "/Users/b/code/z-plug/examples/super_gain/../..";
        pub const build_zig = @import("../..");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "z_plug", "../.." },
};
