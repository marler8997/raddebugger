const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const metagen_exe = b.addExecutable(.{
        .name = "metagen",
        .target = target,
        .optimize = optimize,
    });
    //metagen_exe.defineCMacro("_UNICODE", "");
    metagen_exe.addIncludePath(b.path("src"));
    metagen_exe.addCSourceFiles(.{
        .files = &.{ "src/metagen/metagen_main.c" },
        .flags = &.{
            "-gcodeview",
            "-fdiagnostics-absolute-paths",
            "-Wall", "-Wno-unknown-warning-option", "-Wno-missing-braces", "-Wno-unused-function",
            "-Wno-writable-strings", "-Wno-unused-value", "-Wno-unused-variable", "-Wno-unused-local-typedef",
            "-Wno-deprecated-register", "-Wno-deprecated-declarations", "-Wno-unused-but-set-variable",
            "-Wno-single-bit-bitfield-constant-conversion", "-Wno-compare-distinct-pointer-types",
            "-Wno-initializer-overrides", "-Wno-incompatible-pointer-types-discards-qualifiers",
            "-Xclang", "-flto-visibility-public-std",
            "-D_USE_MATH_DEFINES",
            "-Dstrdup=_strdup",
            "-Dgnu_printf=printf",
            "-D_UNICODE",

            // disable some default zig sanitization that raddbg violates
            "-fno-sanitize=alignment",

            // prevent misaligned access which triggers zig's default sanitizer
            //"-DSTB_SPRINTF_NOUNALIGNED",
            switch (optimize) { .Debug => "-DBUILD_DEBUG=1", else => "-DBUILD_DEBUG=0" },
        },
    });
    metagen_exe.subsystem = .Console;
    metagen_exe.mingw_unicode_entry_point = true;
    metagen_exe.linkSystemLibrary("shlwapi");
    metagen_exe.linkSystemLibrary("advapi32");
    metagen_exe.linkSystemLibrary("shell32");
//#pragma comment(lib, "user32")
//#pragma comment(lib, "winmm")
//#pragma comment(lib, "rpcrt4")
//#pragma comment(lib, "shlwapi")
//#pragma comment(lib, "comctl32")

    metagen_exe.linkLibC();

    // we have to copy metagen_exe into a directory that lives alongside the src
    // directory because that's how it finds the src directory
    const metagen_exe_in_run_location = Generated.file_copy(b, .{
        .from = metagen_exe.getEmittedBin(),
        .path = "build/metagen.exe",
    });
    const metagen_pdb_in_run_location = Generated.file_copy(b, .{
        .from = metagen_exe.getEmittedPdb(),
        .path = "build/metagen.pdb",
    });


    const run_metagen = std.Build.Step.Run.create(b, "run metagen");
    // embed_file is relative to CWD, strange it's not the same
    // as relative to all the files?
    run_metagen.cwd = b.path("src");
    run_metagen.addFileArg(metagen_exe_in_run_location.path);
    run_metagen.step.dependOn(&metagen_pdb_in_run_location.step);
    run_metagen.has_side_effects = true;
    b.step("metagen", "").dependOn(&run_metagen.step);
}


const Generated = struct {
    step: std.Build.Step,
    path: std.Build.LazyPath,

    destination: []const u8,
    generated_file: std.Build.GeneratedFile,
    source: std.Build.LazyPath,
    mode: enum { file, directory },

    pub fn file_copy(b: *std.Build, options: struct {
        from: std.Build.LazyPath,
        path: []const u8,
    }) *Generated {
        return create(b, options.path, .{
            .copy = options.from,
        });
    }

    /// The `generator` program creates several files in the output directory, which is passed in
    /// as an argument.
    ///
    /// NB: there's no check that there aren't extra file at the destination. In other words, this
    /// API can be used for mixing generated and hand-written files in a single directory.
    pub fn directory(b: *std.Build, options: struct {
        generator: *std.Build.Step.Compile,
        path: []const u8,
    }) *Generated {
        return create(b, options.path, .{
            .directory = options.generator,
        });
    }

    fn create(b: *std.Build, destination: []const u8, generator: union(enum) {
        file: *std.Build.Step.Compile,
        directory: *std.Build.Step.Compile,
        copy: std.Build.LazyPath,
    }) *Generated {
        const result = b.allocator.create(Generated) catch @panic("OOM");
        result.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("generate {s}", .{std.fs.path.basename(destination)}),
                .owner = b,
                .makeFn = make,
            }),
            .path = .{ .generated = .{ .file = &result.generated_file } },

            .destination = destination,
            .generated_file = .{ .step = &result.step },
            .source = switch (generator) {
                .file => |compile| b.addRunArtifact(compile).captureStdOut(),
                .directory => |compile| b.addRunArtifact(compile).addOutputDirectoryArg("out"),
                .copy => |lazy_path| lazy_path,
            },
            .mode = switch (generator) {
                .file, .copy => .file,
                .directory => .directory,
            },
        };
        result.source.addStepDependencies(&result.step);

        return result;
    }

    fn make(step: *std.Build.Step, prog_node: std.Progress.Node) !void {
        _ = prog_node;
        const b = step.owner;
        const generated: *Generated = @fieldParentPtr("step", step);
        const ci = try std.process.hasEnvVar(b.allocator, "CI");
        const source_path = generated.source.getPath2(b, step);

        if (ci) {
            const fresh = switch (generated.mode) {
                .file => file_fresh(b, source_path, generated.destination),
                .directory => directory_fresh(b, source_path, generated.destination),
            } catch |err| {
                return step.fail("unable to check '{s}': {s}", .{
                    generated.destination, @errorName(err),
                });
            };

            if (!fresh) {
                return step.fail("file '{s}' is outdated", .{
                    generated.destination,
                });
            }
            step.result_cached = true;
        } else {
            const prev = switch (generated.mode) {
                .file => file_update(b, source_path, generated.destination),
                .directory => directory_update(b, source_path, generated.destination),
            } catch |err| {
                return step.fail("unable to update '{s}': {s}", .{
                    generated.destination, @errorName(err),
                });
            };
            step.result_cached = prev == .fresh;
        }

        generated.generated_file.path = generated.destination;
    }

    fn file_fresh(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !bool {
        const want = try b.build_root.handle.readFileAlloc(
            b.allocator,
            source_path,
            std.math.maxInt(usize),
        );
        defer b.allocator.free(want);

        const got = b.build_root.handle.readFileAlloc(
            b.allocator,
            target_path,
            std.math.maxInt(usize),
        ) catch return false;
        defer b.allocator.free(got);

        return std.mem.eql(u8, want, got);
    }

    fn file_update(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !std.fs.Dir.PrevStatus {
        return std.fs.Dir.updateFile(
            b.build_root.handle,
            source_path,
            b.build_root.handle,
            target_path,
            .{},
        );
    }

    fn directory_fresh(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !bool {
        var source_dir = try b.build_root.handle.openDir(source_path, .{ .iterate = true });
        defer source_dir.close();

        var target_dir = b.build_root.handle.openDir(target_path, .{}) catch return false;
        defer target_dir.close();

        var source_iter = source_dir.iterate();
        while (try source_iter.next()) |entry| {
            std.debug.assert(entry.kind == .file);
            const want = try source_dir.readFileAlloc(
                b.allocator,
                entry.name,
                std.math.maxInt(usize),
            );
            defer b.allocator.free(want);

            const got = target_dir.readFileAlloc(
                b.allocator,
                entry.name,
                std.math.maxInt(usize),
            ) catch return false;
            defer b.allocator.free(got);

            if (!std.mem.eql(u8, want, got)) return false;
        }

        return true;
    }

    fn directory_update(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !std.fs.Dir.PrevStatus {
        var result: std.fs.Dir.PrevStatus = .fresh;
        var source_dir = try b.build_root.handle.openDir(source_path, .{ .iterate = true });
        defer source_dir.close();

        var target_dir = try b.build_root.handle.makeOpenPath(target_path, .{});
        defer target_dir.close();

        var source_iter = source_dir.iterate();
        while (try source_iter.next()) |entry| {
            std.debug.assert(entry.kind == .file);
            const status = try std.fs.Dir.updateFile(
                source_dir,
                entry.name,
                target_dir,
                entry.name,
                .{},
            );
            if (status == .stale) result = .stale;
        }

        return result;
    }
};
