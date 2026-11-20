#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$project_dir/outputs"
app_dir="$output_dir/EyePause.app"
cache_dir="$project_dir/work/cache"
build_dir="$project_dir/work/release-build"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

cd "$project_dir"
mkdir -p "$cache_dir/clang" "$cache_dir/swiftpm"
SDKROOT="$sdk_path" \
CLANG_MODULE_CACHE_PATH="$cache_dir/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/swiftpm" \
swift build -c release --disable-sandbox --scratch-path "$build_dir"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
binary_dir="$(SDKROOT="$sdk_path" swift build -c release --disable-sandbox --scratch-path "$build_dir" --show-bin-path)"
cp "$binary_dir/EyePause" "$app_dir/Contents/MacOS/EyePause"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
