#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$project_dir/work/cache/clang"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
test_binary="$project_dir/work/timer-engine-checks"

mkdir -p "$cache_dir"
SDKROOT="$sdk_path" CLANG_MODULE_CACHE_PATH="$cache_dir" swiftc \
    -parse-as-library \
    "$project_dir/Sources/EyePause/TimerEngine.swift" \
    "$project_dir/Tests/TimerEngineChecks.swift" \
    -o "$test_binary"
"$test_binary"
