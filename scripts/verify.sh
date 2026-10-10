#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
app_path="$project_root/build/VibeShot-export/VibeShot.app"
dry_run=false

usage() {
	cat <<'EOF'
Usage: scripts/verify.sh [--dry-run] [APP_PATH]

Verifies the exported app's signature, Gatekeeper assessment, stapled ticket,
exactly empty entitlements, and compiled AppIcon.icns asset.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--dry-run) dry_run=true; shift ;;
		--help|-h) usage; exit 0 ;;
		-*) usage >&2; exit 2 ;;
		*) app_path=$1; shift ;;
	esac
done

codesign_path=$(command -v codesign || true)
spctl_path=$(command -v spctl || true)
xcrun_path=$(command -v xcrun || true)
plutil_path=$(command -v plutil || true)

[ -n "$codesign_path" ] || { echo "codesign was not found. Run this on macOS with Xcode tools installed." >&2; exit 1; }
[ -n "$spctl_path" ] || { echo "spctl was not found. Run this on macOS with Gatekeeper tools installed." >&2; exit 1; }
[ -n "$xcrun_path" ] || { echo "xcrun was not found. Install Xcode before verification." >&2; exit 1; }
[ -n "$plutil_path" ] || { echo "plutil was not found. Install the macOS developer tools before verification." >&2; exit 1; }
[ "$dry_run" = true ] || [ -d "$app_path" ] || { echo "App not found at $app_path. Run scripts/archive.sh first." >&2; exit 1; }

echo "App: $app_path"
if [ "$dry_run" = true ]; then
	echo "Dry run: would verify codesign, spctl, stapler, entitlements, and AppIcon.icns."
	exit 0
fi

[ -f "$app_path/Contents/Resources/AppIcon.icns" ] || { echo "Compiled AppIcon.icns is missing; release verification stopped." >&2; exit 1; }
"$codesign_path" --verify --deep --strict --verbose=2 "$app_path"
code_details=$("$codesign_path" -d --verbose=4 "$app_path" 2>&1)
if ! printf '%s\n' "$code_details" | grep -Eq '(^|[[:space:]])flags=0x[[:xdigit:]]+\([^)]*runtime[^)]*\)'; then
	echo "Hardened runtime verification failed: codesign flags do not include (runtime)." >&2
	echo "Inspect with: codesign -d --verbose=4 '$app_path'" >&2
	exit 1
fi
"$spctl_path" --assess --type execute --verbose=4 "$app_path"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" "$xcrun_path" stapler validate "$app_path"
entitlements_path=$(mktemp "${TMPDIR:-/tmp}/vibeshot-entitlements.XXXXXX")
cleanup() {
	rm -f -- "$entitlements_path"
}
trap cleanup EXIT HUP INT TERM
if ! "$codesign_path" -d --entitlements :- "$app_path" >"$entitlements_path" 2>/dev/null; then
	echo "Signed entitlements could not be extracted from $app_path." >&2
	echo "The artifact must be signed before release verification." >&2
	exit 1
fi
if [ ! -s "$entitlements_path" ]; then
	# codesign omits the entitlements blob entirely when the signed payload is empty;
	# that is equivalent to an empty dictionary and carries no application capability.
	entitlements_summary='{}'
else
	if ! "$plutil_path" -lint "$entitlements_path" >/dev/null 2>&1; then
		echo "The signed entitlements payload is not a valid plist." >&2
		exit 1
	fi
	entitlements_summary=$("$plutil_path" -convert json -o - "$entitlements_path" | tr -d '[:space:]')
fi
if [ "$entitlements_summary" != "{}" ]; then
	echo "Release entitlements are not exactly empty; application capabilities are forbidden." >&2
	echo "Inspect with: codesign -d --entitlements :- '$app_path'" >&2
	exit 1
fi
echo "Built entitlements: empty"
echo "Icon: $app_path/Contents/Resources/AppIcon.icns"
echo "Verification completed."
