# Releasing VibeShot

VibeShot's M7 distribution baseline is a signed, notarized direct download for macOS 14+. The
repository does not contain signing certificates, App Store credentials, notarization passwords, or
keychain profiles. The Developer ID team and keychain profile are supplied only by the release
operator on the release Mac.

## Preflight

Use a supported Xcode installation and confirm the following before a real release run:

1. Screen Recording permission can be granted to the locally signed app.
2. A `Developer ID Application` certificate is present in the login keychain.
3. The Apple Developer Team ID is known.
4. A `notarytool` keychain profile exists and is referenced by `NOTARY_PROFILE`.
5. An Apple Silicon Mac and a multi-display Mac are available for the manual matrix in
   [TESTING.md](TESTING.md).

The release scripts stop with an actionable message when a tool, identity, team, profile, archive,
or exported app is missing. A real archive run also checks the configured Developer ID name against
`security find-identity -v -p codesigning`. `--help` and `--dry-run` never sign, upload, delete
project data, or contact Apple:

```sh
./scripts/archive.sh --help
./scripts/archive.sh --dry-run
./scripts/notarize.sh --dry-run
./scripts/verify.sh --dry-run
```

## Archive and export

Set only local environment references; do not put their values in source control:

```sh
export DEVELOPER_IDENTITY='Developer ID Application: Example Company (TEAMID1234)'
export DEVELOPMENT_TEAM='TEAMID1234'
./scripts/archive.sh
```

The script uses [scripts/ExportOptions.plist](../scripts/ExportOptions.plist), which selects the
Developer ID export method and contains no account or credential material. It writes the archive and
export under the repository's `build/` directory.

## Notarize and verify

Create the keychain profile once on the release Mac using Apple's `notarytool store-credentials`
flow, then reference its name:

```sh
export NOTARY_PROFILE='vibeshot-release'
./scripts/notarize.sh
./scripts/verify.sh
```

`notarize.sh` first performs a non-submitting `notarytool history` query with the configured
keychain profile. It then creates the submission zip under a unique temporary directory, submits it,
and removes only that temporary directory on exit. The submission, staple, and Gatekeeper checks are
still the authoritative release operations and require the operator's network access and
credentials.

Verification checks the code signature's hardened-runtime flag, Gatekeeper assessment, stapled ticket,
compiled `AppIcon.icns`, and the signed entitlements payload. The extracted payload must be absent
(the codesign representation for no capabilities) or parse as exactly `{}`: the app is not sandboxed
and has no hardened-runtime exceptions. An unsigned validation build is expected to stop at signature
verification; this repository does not claim a signed or notarized artifact until the release operator
runs these commands.

## Release evidence

Record the archive/export version, signing identity fingerprint, notarization submission result,
verification output, and manual matrix date in the release system. Do not record screenshot pixels,
annotation text, save paths, or system error strings in project logs.

This repository can validate unsigned builds and shell dry runs. It cannot claim signing,
notarization, Screen Recording approval, sleep/wake, or multi-display hardware completion until a
release operator runs those checks on real hardware.
