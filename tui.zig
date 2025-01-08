const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const ScrollView = vaxis.widgets.ScrollView;
const Text = vaxis.vxfw.Text;
const log = std.log.scoped(.tui);

fn compareStrings(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs).compare(std.math.CompareOperator.gt);
}

pub fn tui(allocator: std.mem.Allocator, compilers: [][]u8, default_compiler: ?[]const u8) !void {
    std.mem.sort([]const u8, compilers, {}, compareStrings);

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.anyWriter());

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();

    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    var selected_idx: u8 = 0;

    var scroll_view: ScrollView = .{};

    // The main event loop. Vaxis provides a thread safe, blocking, buffered
    // queue which can serve as the primary event queue for an application
    while (true) {
        const event = loop.nextEvent();
        const max_rows: usize = vx.window().height;
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.up, .{})) {
                    if (selected_idx > 0) {
                        selected_idx -= 1;
                    }
                    if (selected_idx < scroll_view.scroll.y and scroll_view.scroll.y > 0) {
                        scroll_view.scroll.y -= 1;
                    }
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    if (selected_idx < compilers.len - 1) {
                        selected_idx += 1;
                    }
                    // account for borders and status bar
                    if (selected_idx >= max_rows - 3 and scroll_view.scroll.y < compilers.len - 1) {
                        scroll_view.scroll.y += 1;
                    }
                }
                if (key.codepoint == 'd') {
                    // todo set default compiler
                }
                if (key.codepoint == 'c') {
                    // todo clean compiler
                }
                if (key.codepoint == 'q') {
                    break;
                }
                if (key.codepoint == 'c' and key.mods.ctrl) {
                    break;
                }
            },
            .winsize => |ws| {
                try vx.resize(allocator, tty.anyWriter(), ws);
            },
        }

        const win = vx.window();
        win.clear();

        const child_bar = win.child(
            .{
                .y_off = win.height - 1,
                .height = .{ .limit = 1 },
            },
        );

        const child = win.child(
            .{
                .height = .{ .limit = win.height - 1 },
                .border = .{ .where = .all, .glyphs = .single_square },
            },
        );

        scroll_view.draw(child, .{ .cols = win.width, .rows = compilers.len });
        _ = try child_bar.printSegment(.{ .text = "q:Quit  d:Default  c:Clean  ↑:Up  ↓:Down", .style = .{ .italic = true } }, .{ .wrap = .word, .commit = true });

        for (compilers, 0..) |compiler, j| {
            for (0..win.width - 3) |i| {
                const color: Cell.Color = if (selected_idx == j) .{ .rgb = .{ 0x81, 0xA2, 0xBE } } else Cell.Color.default;

                const currentSymbol: []const u8 = switch (i) {
                    0 => if (default_compiler) |def_comp| if (std.mem.eql(u8, def_comp, compiler)) "✓" else "o" else "o",
                    1 => " ",
                    else => if (i > compiler.len + 1) " " else compiler[i - 2 .. i - 1],
                };

                const cell: Cell = .{
                    .char = .{ .grapheme = currentSymbol },
                    .style = .{
                        .bg = color,
                    },
                };
                scroll_view.writeCell(child, @intCast(i), @intCast(j), cell);
            }
        }
        try vx.render(tty.anyWriter());
    }
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};
