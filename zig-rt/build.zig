// Build the Elixism Zig runtime: `zig build test` (unit tests) and
// `zig build wasm` (the wasm32-freestanding runtime module).
// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = root });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseFast,
    });
    const wasm = b.addExecutable(.{ .name = "elixism_rt", .root_module = wasm_mod });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_step = b.step("wasm", "Build the WASM runtime module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);

    // Native shared library exposing the regex C ABI for the host (Guile FFI).
    const cabi = b.createModule(.{
        .root_source_file = b.path("src/cabi.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const lib = b.addLibrary(.{ .name = "elixism_re", .root_module = cabi, .linkage = .dynamic });
    b.installArtifact(lib);

    // The regex engine as a wasm module too (edge path).
    const re_wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/cabi.zig"),
        .target = wasm_target,
        .optimize = .ReleaseFast,
    });
    const re_wasm = b.addExecutable(.{ .name = "elixism_re", .root_module = re_wasm_mod });
    re_wasm.entry = .disabled;
    re_wasm.rdynamic = true;
    const re_wasm_step = b.step("re-wasm", "Build the regex engine as a wasm module");
    re_wasm_step.dependOn(&b.addInstallArtifact(re_wasm, .{}).step);
}
