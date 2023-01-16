const builtin = @import("builtin");
const std = @import("std");
const Builder = std.build.Builder;

const system_sdk = @import("system_sdk.zig");

pub fn build(b: *Builder) !void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    var options = Options{};
    if (b.option(bool, "vulkan", "TODO: Add description")) |value| options.vulkan = value;
    if (b.option(bool, "metal", "TODO: Add description")) |value| options.metal = value;
    if (b.option(bool, "opengl", "TODO: Add description")) |value| options.opengl = value;
    if (b.option(bool, "gles", "TODO: Add description")) |value| options.gles = value;
    if (b.option(bool, "x11", "TODO: Add description")) |value| options.x11 = value;
    if (b.option(bool, "wayland", "TODO: Add description")) |value| options.wayland = value;
    if (b.option(bool, "shared", "TODO: Add description")) |value| options.shared = value;
    if (b.option(bool, "install_libs", "TODO: Add description")) |value| options.install_libs = value;
    // TODO: Expose system_sdk options in some way?
    // options.system_sdk = ?

    const lib = try buildLibrary(b, mode, target, options);
    addGLFWIncludes(lib);
    if (options.shared) {
        lib.defineCMacro("GLFW_DLL", null);
        system_sdk.include(b, lib, options.system_sdk);
    } else {
        linkGLFWDependencies(b, lib, options);
    }
    lib.install();

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&(try testStep(b, mode, target)).step);
    test_step.dependOn(&(try testStepShared(b, mode, target)).step);
}

pub fn testStep(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget) !*std.build.RunStep {
    const main_tests = b.addTestExe("glfw-tests", sdkPath("/src/main.zig"));
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);
    try link(b, main_tests, .{});
    main_tests.install();
    return main_tests.run();
}

fn testStepShared(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget) !*std.build.RunStep {
    const main_tests = b.addTestExe("glfw-tests-shared", sdkPath("/src/main.zig"));
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);
    try link(b, main_tests, .{ .shared = true });
    main_tests.install();
    return main_tests.run();
}

pub const Options = struct {
    /// Not supported on macOS.
    vulkan: bool = true,

    /// Only respected on macOS.
    metal: bool = true,

    /// Deprecated on macOS.
    opengl: bool = false,

    /// Not supported on macOS. GLES v3.2 only, currently.
    gles: bool = false,

    /// Only respected on Linux.
    x11: bool = true,

    /// Only respected on Linux.
    wayland: bool = true,

    /// System SDK options.
    system_sdk: system_sdk.Options = .{},

    /// Build and link GLFW as a shared library.
    shared: bool = false,

    install_libs: bool = false,
};

pub const pkg = std.build.Pkg{
    .name = "glfw",
    .source = .{ .path = sdkPath("/src/main.zig") },
};

pub const LinkError = error{FailedToLinkGPU} || std.mem.Allocator.Error;
pub fn link(b: *Builder, step: *std.build.LibExeObjStep, options: Options) LinkError!void {
    const lib = try buildLibrary(b, step.build_mode, step.target, options);
    step.linkLibrary(lib);
    addGLFWIncludes(step);
    if (options.shared) {
        step.defineCMacro("GLFW_DLL", null);
        system_sdk.include(b, step, options.system_sdk);
    } else {
        linkGLFWDependencies(b, step, options);
    }
}

fn buildLibrary(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget, options: Options) std.mem.Allocator.Error!*std.build.LibExeObjStep {
    const lib = if (options.shared)
        b.addSharedLibrary("glfw", null, .unversioned)
    else
        b.addStaticLibrary("glfw", null);
    lib.setBuildMode(mode);
    lib.setTarget(target);

    if (options.shared)
        lib.defineCMacro("_GLFW_BUILD_DLL", null);

    addGLFWIncludes(lib);
    try addGLFWSources(b, lib, options);
    linkGLFWDependencies(b, lib, options);

    if (options.install_libs)
        lib.install();

    return lib;
}

fn addGLFWIncludes(step: *std.build.LibExeObjStep) void {
    step.addIncludePath(sdkPath("/upstream/glfw/include"));
    step.addIncludePath(sdkPath("/upstream/vulkan_headers/include"));
}

fn addGLFWSources(b: *Builder, lib: *std.build.LibExeObjStep, options: Options) std.mem.Allocator.Error!void {
    const include_glfw_src = comptime "-I" ++ sdkPath("/upstream/glfw/src");
    switch (lib.target_info.target.os.tag) {
        .windows => lib.addCSourceFiles(&.{
            sdkPath("/src/sources_all.c"),
            sdkPath("/src/sources_windows.c"),
        }, &.{ "-D_GLFW_WIN32", include_glfw_src }),
        .macos => lib.addCSourceFiles(&.{
            sdkPath("/src/sources_all.c"),
            sdkPath("/src/sources_macos.m"),
            sdkPath("/src/sources_macos.c"),
        }, &.{ "-D_GLFW_COCOA", include_glfw_src }),
        else => {
            // TODO(future): for now, Linux can't be built with musl:
            //
            // ```
            // ld.lld: error: cannot create a copy relocation for symbol stderr
            // thread 2004762 panic: attempt to unwrap error: LLDReportedFailure
            // ```
            var sources = std.ArrayList([]const u8).init(b.allocator);
            var flags = std.ArrayList([]const u8).init(b.allocator);
            try sources.append(sdkPath("/src/sources_all.c"));
            try sources.append(sdkPath("/src/sources_linux.c"));
            if (options.x11) {
                try sources.append(sdkPath("/src/sources_linux_x11.c"));
                try flags.append("-D_GLFW_X11");
            }
            if (options.wayland) {
                try sources.append(sdkPath("/src/sources_linux_wayland.c"));
                try flags.append("-D_GLFW_WAYLAND");
            }
            try flags.append(comptime "-I" ++ sdkPath("/upstream/glfw/src"));
            // TODO(upstream): glfw can't compile on clang15 without this flag
            try flags.append("-Wno-implicit-function-declaration");

            lib.addCSourceFiles(sources.items, flags.items);
        },
    }
}

fn linkGLFWDependencies(b: *Builder, step: *std.build.LibExeObjStep, options: Options) void {
    step.linkLibC();
    system_sdk.include(b, step, options.system_sdk);
    switch (step.target_info.target.os.tag) {
        .windows => {
            step.linkSystemLibraryName("gdi32");
            step.linkSystemLibraryName("user32");
            step.linkSystemLibraryName("shell32");
            if (options.opengl) {
                step.linkSystemLibraryName("opengl32");
            }
            if (options.gles) {
                step.linkSystemLibraryName("GLESv3");
            }
        },
        .macos => {
            step.linkFramework("IOKit");
            step.linkFramework("CoreFoundation");
            if (options.metal) {
                step.linkFramework("Metal");
            }
            if (options.opengl) {
                step.linkFramework("OpenGL");
            }
            step.linkSystemLibraryName("objc");
            step.linkFramework("AppKit");
            step.linkFramework("CoreServices");
            step.linkFramework("CoreGraphics");
            step.linkFramework("Foundation");
        },
        else => {
            // Assume Linux-like
            if (options.wayland) {
                step.defineCMacro("WL_MARSHAL_FLAG_DESTROY", null);
            }
        },
    }
}

fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}
