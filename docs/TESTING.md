# Testing strategy

## Automated test layers

### Unit tests

- `DisplayGeometry`: origin flips, points↔pixels, outward rounding, clamps, mixed scales, displays in
  negative X/Y positions, and round trips.
- Selection reducer/state: create, move, eight-handle resize, minimum size, clamping, full display.
- M3 overlay seams: handle-hit priority, single-display crossing hint/clamp, native pixel dimensions,
  full-screen display fallback, toolbar layout bounds, and synthetic dim/undim rendering.
- Annotation commands: add/update/delete, ordering/index preservation, undo, redo, redo invalidation,
  and transient commit/cancel behavior.
- Shape math: typed lower-left canvas bounds, line/arrow endpoints and arrowheads, freehand/marker
  bounds, rectangle stroke bounds, selection move/resize transforms, and degenerate gesture rejection.
- Annotation rendering: one transform/clip, committed-before-transient ordering, source dim/bright
  behavior, and preview/export renderer parity.
- Settings validation and migration: shortcut parsing, fixed quality 100, format fallback, and version-1
  payloads gaining remembered annotation color/width defaults.
- Encoder policy: UTI/extension, lossless/lossy properties, alpha flattening, safe file names.
- Capture coordinator state machine: invalid transitions, repeated triggers, cancellation, stale callback IDs.

### Rendering tests

Use generated color grids and text-free synthetic bitmaps. Compare dimensions and sampled pixels with
tolerances; use full snapshots only when they remain stable across supported macOS versions.

### Integration tests

- Clipboard contains readable PNG/image data after copy; PNG and compatibility representations
  are prepared before publication, and a failed multi-representation commit leaves no partial
  VibeShot payload.
- Each file format decodes and reports expected pixel dimensions.
- Save cancellation leaves no partial file.
- Settings persist into a fresh store instance.
- Platform adapters are exercised behind test doubles where system permission cannot be automated.

## Manual matrix

Run before MVP release:

| Area | Cases |
| --- | --- |
| Permission | first request, denied, later enabled, revoked while running |
| Displays | one Retina, one non-Retina, mixed scale, display left/above primary, attach/detach |
| Menu | left capture, right menu, rapid clicks, keyboard navigation, Quit |
| Shortcuts | default, customized, conflict, disabled, repeated key press |
| Selection | every drag direction, tiny region, edges/corners, move, all handles, full-screen |
| Tools | each color/width, zero-length drags, text commit/cancel, undo/redo sequence |
| Output | repeated Copy yields the latest image, all formats at quality 100, overwrite/cancel, unwritable folder |

Remember Last Region checks: opt in/out and clear-on-disable; restore only on the pointer display;
repeat after resolution/scale changes; verify create/move/resize/Command+A persistence, cancel retention,
full-screen exclusion, and that annotation gestures do not save geometry. Compare cold/warm real and
synthetic capture starts visually before attributing the opening flash to window animation.
| Lifecycle | Escape at every state, sleep/wake, Space switch, capture while menu is open |

M7 hardening additions:

| Area | Cases | Evidence |
| --- | --- | --- |
| Permission lifecycle | revoke Screen Recording while selecting/editing, re-enable and retry | signed app on real Mac |
| Topology/Space | attach/detach display, change arrangement, switch Space during capture/export UI | one-display and multi-display runs |
| Sleep/memory | sleep/wake during selection and export; exercise warning/critical pressure path where safely available | teardown count returns to idle |
| Export faults | encoder unavailable/finalize failure, unwritable folder, Save As cancel, share dismissal/failure | editor retained; no partial file |
| Release artifact | hardened runtime, empty entitlements, icon, Developer ID signature, notarization ticket | archive/export/verify output |

## P0/P1 finding gate

No P0 or P1 findings are accepted for the release candidate. Triage findings with the following
definitions and record the result in the release evidence:

| Priority | Definition | M7 status |
| --- | --- | --- |
| P0 | capture privacy/data-loss defect, stuck overlay, or release artifact that cannot launch | none known from automated scope; signed/manual verification pending |
| P1 | permission/lifecycle interruption, display geometry, shortcut, or export fault that breaks a documented MVP path | none known from automated scope; signed/manual verification pending |

The automated M7 suite contains three compact table-driven tests: interruption idempotence and
owned-system-UI behavior, export encoder faults/save cancellation, and runtime permission revocation.
Existing shortcut tests remain the shortcut-collision evidence.

## Performance budgets

- Menu click/shortcut to visible overlay: target under 300 ms on a typical supported Mac after permission.
- Drag preview: target 60 fps with no obvious input lag.
- Copy/save feedback: target under 500 ms for an ordinary single-display region.
- No retained full-display bitmap after returning to idle.

Budgets are targets to measure, not reasons to hide correctness failures.

## Release gate

### Export lockout regression

`swift test` includes committed 2x rectangle pixel checks after PNG/TIFF encoding and asynchronous
Save, stale/cancel Save rejection, Copy worker cancellation, and watchdog disarm/one-shot exit with
an injected clock and exit function. The real watchdog background callback also runs in the test.

The `VibeShotUI` scheme runs signed UI tests against DEBUG-only generated artwork using
`--synthetic-capture`, with optional `--export-error`, `--export-delay`, and
`--synthetic-save-directory` pointing to an existing test-owned temporary directory. Its in-memory
settings select that directory and PNG without touching UserDefaults; an invalid supplied path ends
the synthetic launch before any capture or Save panel is created. Tests cover explicit Save
Cancel restoring the editor, one Escape closing the capture from a focused native Save panel,
Command+Q from its filename field, and an actual PNG write with decoded pixel dimensions. It never
captures the desktop or requests Screen Recording. Tests terminate their app in teardown even on assertion failure.
Use a separate DerivedData directory so the test signature does not replace the regular app:

```sh
xcodebuild -project VibeShot.xcodeproj -scheme VibeShotUI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/VibeShot-signed-ui \
  DEVELOPMENT_TEAM=YOUR_TEAM CODE_SIGN_IDENTITY='Apple Development' test
```

Real permission recovery, multi-display hardware, print acceptance, and share-service completion
remain separate manual checks. The original reported Copy error is unknown; synthetic injected errors
verify visible recovery without claiming to reproduce that underlying error.

- Build and all automated tests pass in Debug and Release configurations.
- No P0/P1 defects in capture, privacy, data loss, or stuck-overlay behavior.
- Manual matrix passes on at least one Apple Silicon Mac and a multi-display setup.
- Screen Recording and Launch at Login recovery instructions match the current macOS UI.
- No network request occurs in the MVP during launch, capture, edit, copy, save, print, or share-sheet setup.
- `scripts/archive.sh`, `scripts/notarize.sh`, and `scripts/verify.sh` pass on a release Mac; their
  dry runs are safe to execute on a development machine.
- The compiled app preserves the AppIcon asset, has a `codesign` `(runtime)` flag, and its extracted
  entitlements are absent or parse as exactly `{}` (no App Sandbox or other runtime-exception
  capability).
