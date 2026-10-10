#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
input_path="$project_root/build/VibeShot-export/VibeShot.app"
dry_run=false

usage() {
	cat <<'EOF'
Usage: scripts/notarize.sh [--dry-run] [APP_PATH]

Zips the exported app, submits it with xcrun notarytool, waits for Apple's result,
then staples and validates the ticket. Use a pre-created keychain profile via
NOTARY_PROFILE; credentials are never placed in this repository.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--dry-run) dry_run=true; shift ;;
		--help|-h) usage; exit 0 ;;
		-*) usage >&2; exit 2 ;;
		*) input_path=$1; shift ;;
	esac
done

developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun_path=$(command -v xcrun || true)
ditto_path=$(command -v ditto || true)
notary_profile=${NOTARY_PROFILE:-}
working_dir=
notary_check_path=
zip_path=

cleanup() {
	if [ -n "$notary_check_path" ]; then
		rm -f -- "$notary_check_path"
	fi
	if [ -n "$working_dir" ] && [ -d "$working_dir" ]; then
		rm -rf -- "$working_dir"
	fi
}
trap cleanup EXIT HUP INT TERM

[ -n "$xcrun_path" ] || { echo "xcrun was not found. Install Xcode and set DEVELOPER_DIR." >&2; exit 1; }
[ -n "$ditto_path" ] || { echo "ditto was not found; notarization requires the macOS toolchain." >&2; exit 1; }
[ "$dry_run" = true ] || [ -d "$input_path" ] || { echo "Exported app not found at $input_path. Run scripts/archive.sh first." >&2; exit 1; }
[ "$dry_run" = true ] || [ -n "$notary_profile" ] || { echo "Set NOTARY_PROFILE to an existing notarytool keychain profile (run notarytool store-credentials separately)." >&2; exit 1; }

echo "Input app: $input_path"
echo "Developer directory: $developer_dir"
if [ "$dry_run" = true ]; then
	echo "Dry run: would create a unique temporary zip, submit with notarytool, staple, and validate."
	echo "Dry run note: the temporary working directory would be removed on exit."
	[ -n "$notary_profile" ] || echo "Dry run note: NOTARY_PROFILE is not set."
	exit 0
fi

working_dir=$(mktemp -d "${TMPDIR:-/tmp}/vibeshot-notarize.XXXXXX")
zip_path="$working_dir/VibeShot-notarization.zip"
echo "Submission zip: $zip_path (temporary; removed on exit)"

# A history query checks that the profile can authenticate without submitting this artifact.
# Submission remains the authoritative notarization check and occurs only below.
notary_check_path=$(mktemp "${TMPDIR:-/tmp}/vibeshot-notary-check.XXXXXX")
if ! DEVELOPER_DIR="$developer_dir" "$xcrun_path" notarytool history \
	--keychain-profile "$notary_profile" \
	--output-format json >"$notary_check_path" 2>&1; then
	echo "notarytool profile preflight failed; no submission was made." >&2
	echo "Check NOTARY_PROFILE with notarytool store-credentials and retry." >&2
	exit 1
fi
rm -f -- "$notary_check_path"
notary_check_path=
echo "Notary profile preflight passed (non-submitting history query)."

"$ditto_path" -c -k --keepParent "$input_path" "$zip_path"
DEVELOPER_DIR="$developer_dir" "$xcrun_path" notarytool submit "$zip_path" --keychain-profile "$notary_profile" --wait
DEVELOPER_DIR="$developer_dir" "$xcrun_path" stapler staple "$input_path"
DEVELOPER_DIR="$developer_dir" "$xcrun_path" stapler validate "$input_path"

echo "Notarization completed and ticket stapled to $input_path"
