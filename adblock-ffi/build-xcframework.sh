#!/bin/bash
#
# Builds AdblockFFI.xcframework from the Rust crate.
#
# This is the whole Rust story. Run it when the `adblock` version changes, commit
# the resulting xcframework, and the Xcode project (and anyone who clones the
# repo, and CI) consumes a binary — nobody needs a Rust toolchain to build the
# app. That is how Brave's iOS app consumes the same engine, minus the 760 MB of
# Chromium that ships alongside it in BraveCore.
#
# Requires: rustup with the Apple targets, and cbindgen.
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
#   cargo install cbindgen

set -euo pipefail

cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"

DEVICE_TARGET="aarch64-apple-ios"
SIM_TARGET="aarch64-apple-ios-sim"
LIB="libadblock_ffi.a"
OUTPUT="AdblockFFI.xcframework"

# Where the app project expects to find the finished framework.
INSTALL_DIR="../prototype/Frameworks"

echo "==> Building Rust static libraries"
# `cargo rustc --crate-type staticlib`, not `cargo build`. The crate also declares
# `rlib` so its tests can link against it, and cargo silently disables LTO for any
# crate with more than one crate-type — no warning, just a 39 MB archive instead of
# a 9.7 MB one. Restricting the shipping build to the one crate type we actually
# ship brings LTO back.
cargo rustc --release --target "$DEVICE_TARGET" --crate-type staticlib
cargo rustc --release --target "$SIM_TARGET" --crate-type staticlib

echo "==> Generating the C header"
mkdir -p include
cbindgen --config cbindgen.toml --crate adblock_ffi --output include/adblock_ffi.h

# The module map is what lets Swift write `import AdblockFFI` with no bridging
# header. It has to sit next to the header inside the framework's Headers dir.
cat > include/module.modulemap <<'EOF'
module AdblockFFI {
    header "adblock_ffi.h"
    export *
}
EOF

echo "==> Assembling $OUTPUT"
# Device and simulator slices cannot be lipo'd together — same architecture,
# different platform — so they stay as separate slices.
rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
    -library "target/$DEVICE_TARGET/release/$LIB" -headers include \
    -library "target/$SIM_TARGET/release/$LIB"    -headers include \
    -output "$OUTPUT"

echo "==> Installing into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$OUTPUT"
cp -R "$OUTPUT" "$INSTALL_DIR/$OUTPUT"

echo "==> Done"
du -sh "$INSTALL_DIR/$OUTPUT"
