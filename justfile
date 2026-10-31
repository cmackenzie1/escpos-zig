# List available recipes.
default:
    @just --list

# Build the native binary.
build:
    zig build

# Cross-compile a static arm64 Linux binary into zig-out-arm64/.
build-arm64:
    zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall -p zig-out-arm64

# Format all Zig sources.
fmt:
    zig fmt .

# Check formatting without modifying files.
fmt-check:
    zig fmt --check .

# Run the test suite.
test:
    zig build test --summary all
