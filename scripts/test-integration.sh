#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$project_dir/work/cache/clang"
mkdir -p "$cache_dir"
swiftc -parse-as-library -module-cache-path "$cache_dir" \
    "$project_dir/Sources/EyePause/TimerEngine.swift" \
    "$project_dir/Sources/EyePause/Preferences.swift" \
    "$project_dir/Sources/EyePause/EyePauseModel.swift" \
    "$project_dir/Sources/EyePause/SettingsView.swift" \
    "$project_dir/Sources/EyePause/BreakOverlayController.swift" \
    "$project_dir/Sources/EyePause/AppWindows.swift" \
    "$project_dir/Tests/IntegrationChecks.swift" \
    -o "$project_dir/work/integration-checks"
"$project_dir/work/integration-checks"
