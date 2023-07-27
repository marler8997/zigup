//! Publish Date: 2023_03_19
//! This file is hosted at github.com/marler8997/zig-build-repos and is meant to be copied
//! to projects that use it.
const std = @import("std");
const GitRepoStep = @This();

pub const ShaCheck = enum {
    none,
    warn,
    err,

    pub fn reportFail(self: ShaCheck, comptime fmt: []const u8, args: anytype) void {
        switch (self) {
            .none => unreachable,
            .warn => std.log.warn(fmt, args),
            .err => {
                std.log.err(fmt, args);
                std.os.exit(0xff);
            },
        }
    }
};

step: std.build.Step,
url: []const u8,
name: []const u8,
branch: ?[]const u8 = null,
sha: []const u8,
path: []const u8,
sha_check: ShaCheck = .warn,
fetch_enabled: bool,

var cached_default_fetch_option: ?bool = null;
pub fn defaultFetchOption(b: *std.build.Builder) bool {
    if (cached_default_fetch_option) |_| {} else {
        cached_default_fetch_option = if (b.option(bool, "fetch", "automatically fetch network resources")) |o| o else false;
    }
    return cached_default_fetch_option.?;
}

pub fn create(b: *std.build.Builder, opt: struct {
    url: []const u8,
    branch: ?[]const u8 = null,
    sha: []const u8,
    path: ?[]const u8 = null,
    sha_check: ShaCheck = .warn,
    fetch_enabled: ?bool = null,
    first_ret_addr: ?usize = null,
}) *GitRepoStep {
    var result = b.allocator.create(GitRepoStep) catch @panic("memory");
    const name = std.fs.path.basename(opt.url);
    result.* = GitRepoStep{
        .step = std.build.Step.init(.{
            .id = .custom,
            .name = b.fmt("clone git repository '{s}'", .{name}),
            .owner = b,
            .makeFn = make,
            .first_ret_addr = opt.first_ret_addr orelse @returnAddress(),
            .max_rss = 0,
        }),
        .url = opt.url,
        .name = name,
        .branch = opt.branch,
        .sha = opt.sha,
        .path = if (opt.path) |p| b.allocator.dupe(u8, p) catch @panic("OOM") else b.pathFromRoot(b.pathJoin(&.{ "dep", name })),
        .sha_check = opt.sha_check,
        .fetch_enabled = if (opt.fetch_enabled) |fe| fe else defaultFetchOption(b),
    };
    return result;
}

// TODO: this should be included in std.build, it helps find bugs in build files
fn hasDependency(step: *const std.build.Step, dep_candidate: *const std.build.Step) bool {
    for (step.dependencies.items) |dep| {
        // TODO: should probably use step.loop_flag to prevent infinite recursion
        //       when a circular reference is encountered, or maybe keep track of
        //       the steps encounterd with a hash set
        if (dep == dep_candidate or hasDependency(dep, dep_candidate))
            return true;
    }
    return false;
}

fn make(step: *std.Build.Step, prog_node: *std.Progress.Node) !void {
    _ = prog_node;
    const self = @fieldParentPtr(GitRepoStep, "step", step);

    std.fs.accessAbsolute(self.path, .{}) catch {
        const branch_args = if (self.branch) |b| &[2][]const u8{ " -b ", b } else &[2][]const u8{ "", "" };
        if (!self.fetch_enabled) {
            std.debug.print("Error: git repository '{s}' does not exist\n", .{self.path});
            std.debug.print("       Use -Dfetch to download it automatically, or run the following to clone it:\n", .{});
            std.debug.print("       git clone {s}{s}{s} {s} && git -C {3s} checkout {s} -b fordep\n", .{
                self.url,
                branch_args[0],
                branch_args[1],
                self.path,
                self.sha,
            });
            std.os.exit(1);
        }

        {
            var args = std.ArrayList([]const u8).init(self.step.owner.allocator);
            defer args.deinit();
            try args.append("git");
            try args.append("clone");
            try args.append(self.url);
            // TODO: clone it to a temporary location in case of failure
            //       also, remove that temporary location before running
            try args.append(self.path);
            if (self.branch) |branch| {
                try args.append("-b");
                try args.append(branch);
            }
            try run(self.step.owner, args.items);
        }
        try run(self.step.owner, &[_][]const u8{
            "git",
            "-C",
            self.path,
            "checkout",
            self.sha,
            "-b",
            "fordep",
        });
    };

    try self.checkSha();
}

fn checkSha(self: GitRepoStep) !void {
    if (self.sha_check == .none)
        return;

    const result: union(enum) { failed: anyerror, output: []const u8 } = blk: {
        const result = std.ChildProcess.exec(.{
            .allocator = self.step.owner.allocator,
            .argv = &[_][]const u8{
                "git",
                "-C",
                self.path,
                "rev-parse",
                "HEAD",
            },
            .cwd = self.step.owner.build_root.path,
            .env_map = self.step.owner.env_map,
        }) catch |e| break :blk .{ .failed = e };
        try std.io.getStdErr().writer().writeAll(result.stderr);
        switch (result.term) {
            .Exited => |code| {
                if (code == 0) break :blk .{ .output = result.stdout };
                break :blk .{ .failed = error.GitProcessNonZeroExit };
            },
            .Signal => break :blk .{ .failed = error.GitProcessFailedWithSignal },
            .Stopped => break :blk .{ .failed = error.GitProcessWasStopped },
            .Unknown => break :blk .{ .failed = error.GitProcessFailed },
        }
    };
    switch (result) {
        .failed => |err| {
            return self.sha_check.reportFail("failed to retreive sha for repository '{s}': {s}", .{ self.name, @errorName(err) });
        },
        .output => |output| {
            if (!std.mem.eql(u8, std.mem.trimRight(u8, output, "\n\r"), self.sha)) {
                return self.sha_check.reportFail("repository '{s}' sha does not match\nexpected: {s}\nactual  : {s}\n", .{ self.name, self.sha, output });
            }
        },
    }
}

fn run(builder: *std.build.Builder, argv: []const []const u8) !void {
    {
        var msg = std.ArrayList(u8).init(builder.allocator);
        defer msg.deinit();
        const writer = msg.writer();
        var prefix: []const u8 = "";
        for (argv) |arg| {
            try writer.print("{s}\"{s}\"", .{ prefix, arg });
            prefix = " ";
        }
        std.log.info("[RUN] {s}", .{msg.items});
    }

    var child = std.ChildProcess.init(argv, builder.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.cwd = builder.build_root.path;
    child.env_map = builder.env_map;

    try child.spawn();
    const result = try child.wait();
    switch (result) {
        .Exited => |code| if (code != 0) {
            std.log.err("git clone failed with exit code {}", .{code});
            std.os.exit(0xff);
        },
        else => {
            std.log.err("git clone failed with: {}", .{result});
            std.os.exit(0xff);
        },
    }
}

// Get's the repository path and also verifies that the step requesting the path
// is dependent on this step.
pub fn getPath(self: *const GitRepoStep, who_wants_to_know: *const std.build.Step) []const u8 {
    if (!hasDependency(who_wants_to_know, &self.step))
        @panic("a step called GitRepoStep.getPath but has not added it as a dependency");
    return self.path;
}
