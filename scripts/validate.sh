#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project VibeShot.xcodeproj \
  -scheme VibeShot \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build test

DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project VibeShot.xcodeproj \
  -scheme VibeShot \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
