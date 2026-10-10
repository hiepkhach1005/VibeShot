#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
archive_path="$project_root/build/VibeShot.xcarchive"
export_path="$project_root/build/VibeShot-export"
dry_run=false

usage() {
	cat <<'EOF'
Usage: scripts/archive.sh [--dry-run] [--archive-path PATH] [--export-path PATH]

Creates and exports a signed Developer ID archive. Credentials remain in the local
keychain/environment; this script never accepts or stores secrets.

Required for a real run:
  DEVELOPER_IDENTITY  codesign identity, e.g. "Developer ID Application: ..."
  DEVELOPMENT_TEAM    ten-character Apple Developer Team ID
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--dry-run) dry_run=true; shift ;;
		--archive-path) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; archive_path=$2; shift 2 ;;
		--export-path) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; export_path=$2; shift 2 ;;
		--help|-h) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done

export_options="$script_dir/ExportOptions.plist"
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcodebuild_path=$(command -v xcodebuild || true)
security_path=$(command -v security || true)

[ -n "$xcodebuild_path" ] || { echo "xcodebuild was not found. Install Xcode and set DEVELOPER_DIR to its Developer directory." >&2; exit 1; }
[ -f "$project_root/VibeShot.xcodeproj/project.pbxproj" ] || { echo "VibeShot.xcodeproj is missing at $project_root." >&2; exit 1; }
[ -f "$export_options" ] || { echo "Developer ID ExportOptions.plist is missing at $export_options." >&2; exit 1; }

developer_identity=${DEVELOPER_IDENTITY:-}
development_team=${DEVELOPMENT_TEAM:-}
if [ "$dry_run" = false ]; then
	[ -n "$developer_identity" ] || { echo "Set DEVELOPER_IDENTITY to a Developer ID Application certificate before archiving." >&2; exit 1; }
	[ -n "$development_team" ] || { echo "Set DEVELOPMENT_TEAM to the Apple Developer Team ID before archiving." >&2; exit 1; }
	case "$developer_identity" in
		Developer\ ID\ Application:*) ;;
		*)
			echo "DEVELOPER_IDENTITY must name a Developer ID Application certificate." >&2
			exit 1
			;;
	esac
	case "$development_team" in
		??????????) ;;
		*)
			echo "DEVELOPMENT_TEAM must be the ten-character Apple Developer Team ID." >&2
			exit 1
			;;
	esac
	case "$development_team" in
		*[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789]*)
			echo "DEVELOPMENT_TEAM must contain only uppercase letters and digits." >&2
			exit 1
			;;
	esac
	[ -n "$security_path" ] || { echo "security was not found. Run this on macOS with a login keychain and Xcode tools installed." >&2; exit 1; }
	identity_list=$("$security_path" find-identity -v -p codesigning 2>/dev/null || true)
	if ! printf '%s\n' "$identity_list" | grep -F -- "\"$developer_identity\"" >/dev/null 2>&1; then
		echo "No matching Developer ID Application identity was found in the login keychain." >&2
		echo "Inspect available identities with: security find-identity -v -p codesigning" >&2
		exit 1
	fi
fi

echo "Project: $project_root/VibeShot.xcodeproj"
echo "Archive: $archive_path"
echo "Export:  $export_path"
echo "Developer directory: $developer_dir"
if [ "$dry_run" = true ]; then
	echo "Dry run: would archive and export with Developer ID signing."
	[ -n "$developer_identity" ] || echo "Dry run note: DEVELOPER_IDENTITY is not set."
	[ -n "$development_team" ] || echo "Dry run note: DEVELOPMENT_TEAM is not set."
	[ -n "$security_path" ] || echo "Dry run note: security is unavailable; identity preflight is deferred."
	exit 0
fi

mkdir -p "$(dirname -- "$archive_path")" "$export_path"
DEVELOPER_DIR="$developer_dir" "$xcodebuild_path" \
	-project "$project_root/VibeShot.xcodeproj" \
	-scheme VibeShot \
	-configuration Release \
	-archivePath "$archive_path" \
	CODE_SIGN_STYLE=Manual \
	CODE_SIGN_IDENTITY="$developer_identity" \
	DEVELOPMENT_TEAM="$development_team" \
	archive

DEVELOPER_DIR="$developer_dir" "$xcodebuild_path" \
	-exportArchive \
	-archivePath "$archive_path" \
	-exportOptionsPlist "$export_options" \
	-exportPath "$export_path"

echo "Archive/export completed. Artifact: $export_path/VibeShot.app"
