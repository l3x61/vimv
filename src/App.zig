const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const config = @import("config");
const window_title = config.exe_name;
const zglfw = @import("zglfw");
const Window = zglfw.Window;
const zgui = @import("zgui");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

const Browser = @import("Browser.zig");
const Viewer = @import("Viewer.zig");

const App = @This();

const log = std.log.scoped(.GUI);
const window_width = 800;
const window_height = 450;
const font_size = 18;
const gl_major = 4;
const gl_minor = 0;

var scroll_event = ScrollEvent{ .xoffset = 0, .yoffset = 0 };
const ScrollEvent = struct {
    xoffset: f64,
    yoffset: f64,
};

allocator: Allocator = undefined,
window: *Window = undefined,
ini_file_path: ArrayList(u8) = undefined,
font_regular: zgui.Font = undefined,
font_bold: zgui.Font = undefined,
browser: Browser = undefined,
viewer: Viewer = undefined,
show_demo: bool = false,
quit_exe: bool = false,
dockspace_setup: bool = false,
fullscreen: bool = false,
pos_x: c_int = undefined,
pos_y: c_int = undefined,
width: c_int = undefined,
height: c_int = undefined,
refresh_rate: c_int = undefined,

pub fn init(allocator: Allocator) !App {
    log.debug("{s}()", .{@src().fn_name});

    var self = App{};

    self.allocator = allocator;
    try self.windowInit();
    try self.guiInit();
    self.browser = try Browser.init(allocator, ".");
    self.viewer = try Viewer.init(allocator);

    return self;
}

fn windowInit(self: *App) !void {
    try zglfw.init();

    zglfw.windowHint(.context_version_major, gl_major);
    zglfw.windowHint(.context_version_minor, gl_minor);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);
    zglfw.windowHint(.client_api, .opengl_api);
    zglfw.windowHint(.doublebuffer, true);

    self.window = try zglfw.Window.create(window_width, window_height, window_title, null);
    self.window.setSizeLimits(-1, -1, -1, -1);

    zglfw.makeContextCurrent(self.window);
    zglfw.swapInterval(1);

    _ = zglfw.setScrollCallback(self.window, scrollCallback);

    try zopengl.loadCoreProfile(zglfw.getProcAddress, gl_major, gl_minor);

    log.debug("{s}() Max Texture Size: {d}", .{ @src().fn_name, getMaxTextureSize() });
}

fn scrollCallback(_: *Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    scroll_event.xoffset = xoffset;
    scroll_event.yoffset = yoffset;
}

pub fn mouseWheelScrollY() f64 {
    defer scroll_event = .{ .xoffset = 0, .yoffset = 0 };
    return scroll_event.yoffset;
}

fn guiInit(self: *App) !void {
    zgui.init(self.allocator);

    const appdata_path = try std.fs.getAppDataDir(self.allocator, config.exe_name);
    try fs.cwd().makePath(appdata_path);
    log.info("{s}() config.ini location set to {s}", .{ @src().fn_name, appdata_path });

    self.ini_file_path = ArrayList(u8).fromOwnedSlice(self.allocator, appdata_path);
    try self.ini_file_path.appendSlice("/config.ini");
    try self.ini_file_path.append(0);
    const ini_cstr: [:0]u8 = self.ini_file_path.items[0 .. self.ini_file_path.items.len - 1 :0];
    zgui.io.setIniFilename(ini_cstr.ptr);

    const scale = scale: {
        const scale = self.window.getContentScale();
        break :scale @max(scale[0], scale[1]);
    };

    zgui.getStyle().scaleAllSizes(scale);

    self.font_regular = zgui.io.addFontFromMemory(
        @embedFile("fonts/JetBrainsMonoNL-Regular.ttf"),
        font_size * scale,
    );

    self.font_bold = zgui.io.addFontFromMemory(
        @embedFile("fonts/JetBrainsMonoNL-ExtraBold.ttf"),
        font_size * scale,
    );
    zgui.io.setConfigFlags(.{ .dock_enable = true });
    zgui.backend.init(self.window);
}

pub fn deinit(self: *App) void {
    log.debug("{s}()", .{@src().fn_name});

    self.browser.deinit();
    self.viewer.deinit();

    zgui.backend.deinit();
    zgui.deinit();
    self.ini_file_path.deinit();
    self.window.destroy();
    zglfw.terminate();
}

pub fn run(self: *App) !void {
    log.debug("{s}()", .{@src().fn_name});

    while (!self.quit_exe) {
        try self.update();
        try self.draw();
    }
}

fn update(self: *App) !void {
    zglfw.pollEvents();

    if (self.window.shouldClose() or zgui.isKeyPressed(.escape, false) or zgui.isKeyPressed(.q, false)) {
        self.quit_exe = true;
    }

    if (zgui.isKeyPressed(.f, false)) {
        self.fullscreen = !self.fullscreen;
        try self.toggleFullscreen();
    }

    if (zgui.isKeyPressed(.d, false)) {
        self.show_demo = !self.show_demo;
    }

    try self.browser.update(self);
    try self.viewer.update();
}

fn draw(self: *App) !void {
    gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0, 0, 0, 0 });

    const fb_size = self.window.getFramebufferSize();
    zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

    const viewport = zgui.getMainViewport();
    const dockspace = zgui.DockSpaceOverViewport(0, viewport, .{ .no_undocking = true, .auto_hide_tab_bar = true });

    if (!self.dockspace_setup) {
        log.debug("{s}() init dockspace", .{@src().fn_name});

        zgui.dockBuilderRemoveNode(dockspace);
        _ = zgui.dockBuilderAddNode(dockspace, .{ .dock_space = true, .no_undocking = true });
        zgui.dockBuilderSetNodeSize(dockspace, viewport.getSize());

        var node_left: u32 = undefined;
        var node_right: u32 = undefined;
        _ = zgui.dockBuilderSplitNode(dockspace, .left, 0.3333, &node_left, &node_right);

        zgui.dockBuilderDockWindow(Browser.window_title, node_left);
        zgui.dockBuilderDockWindow(Viewer.window_title, node_right);

        zgui.dockBuilderFinish(dockspace);
        self.dockspace_setup = true;
    }

    try self.browser.draw(self);
    try self.viewer.draw();

    if (self.show_demo) {
        zgui.showDemoWindow(null);
    }

    self.render();
}

fn render(self: *App) void {
    zgui.backend.draw();
    self.window.swapBuffers();
}

fn getMaxTextureSize() i32 {
    var size: i32 = undefined;
    gl.getIntegerv(gl.MAX_TEXTURE_SIZE, &size);
    return size;
}

fn toggleFullscreen(self: *App) !void {
    log.debug("{s}() fullscreen = {}", .{ @src().fn_name, self.fullscreen });
    // https://github.com/glfw/glfw/issues/1699
    const monitor = zglfw.getPrimaryMonitor() orelse {
        log.err("{s}() could not get primary monitor", .{@src().fn_name});
        self.fullscreen = false;
        return;
    };

    if (self.fullscreen) {
        zglfw.getWindowPos(self.window, &self.pos_x, &self.pos_y);
        zglfw.getWindowSize(self.window, &self.width, &self.height);
        const mode = try zglfw.getVideoMode(monitor);
        self.refresh_rate = mode.refresh_rate;
        zglfw.setWindowMonitor(self.window, monitor, self.pos_x, self.pos_y, mode.width, mode.height, mode.refresh_rate);
        return;
    }

    zglfw.setWindowMonitor(self.window, null, self.pos_x, self.pos_y, self.width, self.height, self.refresh_rate);
}
