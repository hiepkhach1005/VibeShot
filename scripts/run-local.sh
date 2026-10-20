#!/bin/sh
set -eu

usage() {
	cat <<'EOF'
Usage: scripts/run-local.sh [--reset-permissions] [--install-path PATH]

Builds Release, signs it with the local "Apple Development" identity, replaces the installed copy,
and launches it. A stable certificate signature lets macOS keep the Screen Recording grant across
rebuilds; ad-hoc builds are identified by cdhash and lose it every time.

  --reset-permissions  also clear VibeShot's Screen Recording grant (macOS asks again on launch)
  --install-path PATH  installed app location (default: $HOME/Documents/VibeShot.app)

Environment: DEVELOPMENT_TEAM overrides the team read from the signing certificate.
EOF
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
install_path="$HOME/Documents/VibeShot.app"
bundle_id=com.vibeshot.VibeShot
reset_permissions=false

while [ "$#" -gt 0 ]; do
	case "$1" in
		--reset-permissions) reset_permissions=true; shift ;;
		--install-path) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; install_path=$2; shift 2 ;;
		--help|-h) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done

identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)
[ -n "$identity" ] || { echo "No \"Apple Development\" signing identity found in the keychain." >&2; exit 1; }
team=${DEVELOPMENT_TEAM:-$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')}
[ -n "$team" ] || { echo "Could not read the team ID from \"$identity\"; set DEVELOPMENT_TEAM." >&2; exit 1; }

derived_data="$project_root/build/local"
xcodebuild -project "$project_root/VibeShot.xcodeproj" -scheme VibeShot -configuration Release \
	-derivedDataPath "$derived_data" \
	CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
	build -quiet
built_app="$derived_data/Build/Products/Release/VibeShot.app"
codesign --verify --strict "$built_app"

pkill -x VibeShot 2>/dev/null && sleep 1 || true
if [ "$reset_permissions" = true ]; then
	tccutil reset ScreenCapture "$bundle_id" || true
fi
rm -rf "$install_path"
ditto "$built_app" "$install_path"
open "$install_path"
echo "Launched $install_path (signed by $identity)"
