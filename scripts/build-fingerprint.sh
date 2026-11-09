#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="$root/.build/fingerprint"
output="$root/Frameworks/Fingerprint.xcframework"
manifest="$root/Fingerprint/Cargo.toml"

rustup target add aarch64-apple-ios aarch64-apple-ios-sim

export IPHONEOS_DEPLOYMENT_TARGET=27.0
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
    cargo build --locked --release --manifest-path "$manifest" \
        --target-dir "$build_dir" --target "$target"
done

mkdir -p "$root/Frameworks"
rm -rf "$output"
xcodebuild -create-xcframework \
    -library "$build_dir/aarch64-apple-ios/release/libscrobbler_fingerprint.a" \
    -headers "$root/Fingerprint/include" \
    -library "$build_dir/aarch64-apple-ios-sim/release/libscrobbler_fingerprint.a" \
    -headers "$root/Fingerprint/include" \
    -output "$output"
