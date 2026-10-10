# Progress

Last updated: 2026-09-30

## Current phase

The quality/region/clipboard follow-up is implemented and under verification. Repeated Copy now
replaces the stale first clipboard image; app exports use quality 100; Remember Last Region is an
opt-in, geometry-only setting. Capture-start animation remains a visual investigation.
The restored display also receives initial keyboard focus; a focused synthetic regression covers it.
An ad-hoc `VibeShotUI` test run built successfully but XCUITest stalled before launching the app while
waiting for its LaunchServices worker; the test was interrupted, so signed GUI smoke remains open.

M0 project bootstrap is complete. M1 menu behavior, settings, and shortcuts is implemented. M2
permission, display mapping, immutable snapshots, and geometry are implemented. M3 selection overlays,
M4 annotation core, M5 text/final-toolbar, M6 local export/actions, and M7 lifecycle/release hardening
are implemented and under verification.

## Completed

- Defined Codex planner, implementer, and tester agents.
- Selected token-conscious model roles.
- Researched public Lightshot feature set and core Apple platform APIs.
- Defined product scope, architecture, engineering rules, implementation milestones, and test strategy.
- Added VibeShot project skill and reusable prompts.
- Added the native AppKit menu-bar application, Xcode project/shared scheme, unit/UI test targets,
  generated fixture, Swift Package validation path, and local validation script.
- Verified Debug build, 2/2 unit tests, Release build, and a manual smoke launch. The app registers as
  `com.vibeshot.VibeShot`, stays hidden with no windows, creates its status item, and quits cleanly.
- Implemented distinct left/right status-item actions, a dynamic settings menu, versioned typed
  settings validation/persistence, output format and fixed quality policy, save destination state,
  Launch at Login status/actions, Carbon global shortcuts with atomic replacement, and the M1 capture
  command probe. Added focused fake-backed coverage for menu, coordinator, settings, login state, and
  shortcut behavior.
- M1's Full Screen menu and shortcut intentionally emit one generic full-screen intent. A per-display
  submenu is deferred to M2, where display enumeration and ScreenCaptureKit mapping are owned.
- Shortcut replacement rollback is deterministic: if persistence and restoration both fail, VibeShot
  unregisters that action's runtime shortcut and reports a combined actionable error instead of leaving
  the newly registered shortcut active with stale persisted settings.
- Added the VibeShot brand icon and complete native macOS AppIcon asset set. The status item remains a
  monochrome SF Symbol template so it follows macOS menu-bar contrast and accessibility behavior.
- Implemented M2's Screen Recording preflight/recovery path, strict NSScreen-to-SCDisplay mapping,
  cursor-free per-display ScreenCaptureKit snapshots, immutable in-memory CaptureSession handoff, and
  idempotent cancellation/stale-session protection. Added typed point/pixel geometry with origin,
  scale, vertical-flip, outward-rounding, and clamp coverage, plus a typed multi-display full-screen
  menu.
- Implemented M3's session-ID event/cancel consumer contract, coordinator selecting/editing phases,
  pure display-local SelectionController and ToolbarLayoutEngine seams, and one prebuilt borderless
  overlay panel per captured display. Region selection clamps to one display with an 8-point minimum,
  all eight handles, move/crossing behavior, Command+A, live native-pixel dimensions, cursor feedback,
  and an explicit cross-display limitation hint. Full-screen selection resolves explicit display ID,
  pointer display, then deterministic ID order and commits immediately. Overlay teardown handles Escape,
  app deactivation, display changes, cancellation, and termination; no annotation controls were added.
- Implemented M4's typed lower-left canvas vectors, immutable pen/line/arrow/rectangle/marker items,
  shared Core Graphics source/dim/bright/vector rendering, transient gesture previews, ordered
  add/update/delete command history, and redo invalidation. The selected overlay now owns a short-lived
  annotation document, maps vectors through selection move/resize transforms without mutating them,
  consumes transient Escape first, and exposes temporary tool/color/width/undo/redo controls through
  the M3 toolbar layout seam. Last color/width settings migrate from version 1 payloads with safe
  defaults. M4 tests cover geometry, history, renderer ordering/clipping, gestures, transforms, and
  settings migration.
- Implemented M5 value-based multiline text annotations/styles, pure sanitization/layout/key-routing
  seams, shared transformed/clipped Core Text rendering, idempotent in-place NSTextView editing,
  text commit/cancel/focus behavior, and one-command text history. Replaced temporary controls with
  the final vertical tool/style toolbar and typed horizontal `CaptureEditorAction` seam; cancel is
  wired and M6 installs the export action handlers. Added accessibility labels/help/state, focus-chain
  setup, and seven compact text/tooling tests. Fixed the vertical toolbar's real-world routing
  regression where unassigned `NSButton.tag` values sent every tool click to `.select`; routing now
  resolves the typed button mapping directly. Added AppKit target/action coverage for every tool and
  synthetic controller coverage for rectangle, arrow, and text commit paths.
- Implemented M6 immutable export inputs, DisplayGeometry native-pixel cropping, committed-only
  vector/text compositing in sRGB RGBA, Image I/O PNG/JPEG/HEIC/BMP policy, white alpha flattening
  for JPEG/BMP, PNG plus TIFF clipboard data, collision-safe atomic saves, recent-folder/Save As
  flows with versioned folder bookmarks, aspect-fit printing, retained share-picker delegates, and
  typed action outcomes with exporting/re-entry guards. Added table-driven export coverage and
  wired the Xcode test target membership.
- Implemented M7's single `CaptureLifecycleMonitor` for topology, Space, app deactivation, sleep/wake,
  memory pressure, and permission revocation. Cancellation is idempotent, returns the coordinator to
  idle, and preserves capture-owned save/print/share system UI on deactivation while always tearing
  down for topology, Space, sleep/wake, memory, and permission changes. Added numeric-only local
  metrics/signposts with injectable no-op/recording sinks, an `ImageEncoding` fault seam, and three
  compact table-driven hardening tests.
- Enabled hardened runtime with an empty entitlements file and no App Sandbox, parameterized release
  version settings, preserved the native AppIcon asset, and added Developer ID ExportOptions plus
  archive/notarize/verify scripts with actionable identity/profile preflight, exact runtime/empty-
  entitlements checks, help, and dry-run modes. Added the direct download release runbook and M7
  manual/P0-P1 gate notes.
- M6 copy now snapshots its native-pixel composition and PNG/TIFF representations on a detached,
  value-only worker. The main actor owns only the final one-item pasteboard publication; copy work
  is session/job-tagged, cancelled on teardown/replacement, and stale output cannot publish or
  close a newer editor. Export actions expose a disabled `Exporting` accessibility state while copy
  preparation is in flight and failures retain the editor.

## Next task

Verify Remember Last Region and capture-start animation on a real macOS desktop, including cold/warm
real and synthetic captures. Only retain an overlay animation change if a direct comparison removes
the expansion without a blank first frame or input regression.


Prior export lockout work: all overlays hide for native export/error UI; Save panel and heavy work are
asynchronous, Copy cancellation reaches its worker, a session Carbon hotkey carries Escape through
the native Save panel, and Command+Q works through focused controls. An active-session 30-second
main-thread watchdog releases stuck windows by exiting VibeShot (unsaved work is lost). The generated
Retina rectangle PNG/TIFF/Save and watchdog/key unit tests pass, as does the signed synthetic UI
suite including a real Save panel PNG write, explicit Cancel restoration, Escape, and Command+Q.
The original Copy failure message remains unknown and is not claimed to be diagnosed.

Verify M3–M7 with the signed app: Screen Recording approval/denial/revocation recovery, one panel per display,
region drag/resize/move on Retina and mixed-scale displays, final tool/style toolbar and color controls,
draw-inside-selection behavior, text Return/newline/Escape/focus-loss paths, transient Escape,
vector/text scaling after selection resize, undo/redo, typed action-toolbar cancellation, native-pixel
crop/format signatures, alpha flattening, recent-folder/Save As/collision behavior, print/share
success-dismissal/error outcomes, cross-display hint/clamp, full-screen pointer/explicit-display
selection, Command+A, deactivation, and display-change teardown.
Also exercise Space/sleep-wake/memory-pressure cancellation, export fault/cancel retention, and the
Developer ID archive/notarization/verification runbook on a release Mac.
The UI test target is built but skipped by unsigned automated validation because its runner cannot
bootstrap without signing. Signed hardware checks, Developer ID signing, notarization, and Gatekeeper
verification remain release-operator blockers.

## Open release decisions

- Final bundle identifier and signing team.
- Release signing identity, Team ID, and notarization keychain profile.

## Milestone status

| Milestone | Status |
| --- | --- |
| M0 Project bootstrap | Complete |
| M1 Menu/settings/shortcuts | Implemented; verification/manual system checks pending |
| M2 Permission/snapshots | Implemented; verification/manual checks pending |
| M3 Selection overlays | Implemented; verification/manual checks pending |
| M4 Annotation core | Implemented; verification/manual checks pending |
| M5 Text/toolbars | Implemented; verification/manual checks pending |
| M6 Export/actions | Implemented; verification/manual checks pending |
| M7 Hardening/release | Implemented; signed/manual verification pending |

## 2026-10-10 — Prepare public GitHub source publication

- Refreshed the root README with the product workflow, implemented features, source-build steps, and development-preview limitations.
- Added ignore rules for local metadata, build outputs, generated SARIF reports, signing material, environment files, and private configuration.
- Ran Gitleaks against the Git candidate file snapshot and reviewed findings; no actual credentials were identified.
- Checked README relative links and image references. Application behavior was not changed and app build/test suites were not run for this documentation/publication task.
- Git commits use the account's GitHub noreply address.
