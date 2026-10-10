# Implementation plan

Implement milestones in order. Each milestone should be independently buildable and leave a focused
test trail. Do not start cloud features while an MVP exit criterion remains open.

## M0 — Project bootstrap

Create the native macOS Xcode project and test targets.

- Configure a menu-bar app with no ordinary main window and no Dock icon.
- Set deployment target to macOS 14+ and add the Screen Recording usage description.
- Establish source groups from `ARCHITECTURE.md` and minimal protocols for platform adapters.
- Add generated, privacy-safe visual fixtures for geometry/rendering tests.
- Confirm Debug and Release builds and a trivial unit test in CI/local commands.

Exit: app launches as a status item, quits cleanly, and build/test commands are documented.

## M1 — Status item, settings, and shortcuts

- Implement `StatusItemController` with distinct left/right clicks.
- Build the right-click menu and typed `SettingsStore`.
- Add format behavior and a static quality 100 label; lossless formats ignore lossy encoder properties.
- Implement Launch at Login through `SMAppService.mainApp`, reflecting denied/system state.
- Add global shortcut registration, conflict/error reporting, and persisted defaults.

Exit: menu behavior and settings persist; shortcuts invoke a stub capture command exactly once.

## M2 — Permission and screen snapshots

- Implement permission preflight/request and a recoverable denied-state explanation.
- Map `NSScreen` and ScreenCaptureKit displays reliably.
- Capture each display before overlays and hold a session-scoped snapshot set.
- Add the `DisplayGeometry` conversion layer and unit tests for scale/origin cases.

Exit: a left click or shortcut captures accurate pixels on every attached display without VibeShot UI.

## M3 — Region/full-screen selection overlays

- Create one overlay panel per display and coordinate them through `CaptureCoordinator`.
- Implement dimming, drag-to-select, live dimensions, move, eight resize handles, cursor feedback,
  minimum selection size, clamping, and `Command+A`.
- Add full-screen capture path and robust Escape/cancel teardown.
- Add a pure toolbar-layout seam for later annotation controls; do not show annotation toolbars in M3.

Exit: region and full-screen selections are stable on Retina and multi-display configurations.

## M4 — Annotation core

- Implement vector annotation types and shared rendering contract.
- Add tool selection, colors, stroke widths, pen, line, arrow, rectangle, and marker.
- Implement command-stack undo/redo and transient previews while dragging.
- Unit-test bounds, scaling, arrow geometry, ordering, and undo/redo.

Exit: every non-text tool previews smoothly and exports at matching coordinates.

## M5 — Text editing and final toolbar

- Add in-place text editor with keyboard/focus behavior and color/style integration.
- Complete vertical/horizontal toolbars and keyboard commands.
- Ensure text input does not accidentally trigger capture-level shortcuts.
- Add accessibility labels/tooltips and keyboard focus where practical.

Exit: the interaction shown in the provided Lightshot reference is functionally reproducible locally.

## M6 — Composite, copy, save, print, and share

- Render selected source pixels plus vector annotations at native resolution.
- Write PNG-compatible image data to `NSPasteboard` for `Command+C`.
- Encode PNG/JPEG/HEIC/BMP through Image I/O with correct quality semantics.
- Implement recent-folder and Save As flows, collision-safe names, visible errors, print, and the
  standard macOS share picker.
- Test output dimensions, alpha/background behavior, file signatures, and quality bounds.
- Keep Copy replacement and Remember Last Region regression coverage current; investigate capture-start
  animation with a direct macOS visual comparison before changing overlay presentation.

Exit: copy/save/print/share succeed and always close or retain the overlay according to documented behavior.

## M7 — Hardening and release readiness

- Exercise permission revoked while running, display attach/detach, Space changes, sleep/wake,
  shortcut collision, encoding failure, save cancellation, and low-memory teardown.
- Centralize topology, Space, sleep/wake, memory-pressure, app-deactivation, and permission-revocation
  observation in one idempotent lifecycle monitor; preserve export-owned system UI during deactivation.
- Keep local diagnostics privacy-safe: fixed stages with numeric durations, counts, and byte estimates
  only. Add deterministic no-op metrics and encoding seams for fault tests.
- Profile overlay latency and memory with large/multiple displays.
- Add signing, hardened runtime, release configuration, icon assets, Developer ID export options,
  archive/notarize/verify scripts, and notarization notes.
- Complete the manual test matrix and resolve all P0/P1 findings.

Exit: MVP acceptance criteria in `PRODUCT_SPEC.md` and release gates in `TESTING.md` pass.

## Post-MVP, separately approved

1. Opt-in local history with bounded retention and delete controls.
2. Blur/pixelate, numbered step labels, annotation object selection, and delete.
3. Explicit cloud upload with unguessable URLs, expiry/delete controls, and privacy warning.
4. Account/gallery sync only after authentication, data export, and deletion are designed.
5. Similar-image search only after provider terms and screenshot upload consent are accepted.

## Recommended first coding prompt

Use `prompts/01-implement-milestone.md` with `M0 — Project bootstrap`. After it passes, repeat one
milestone at a time. Avoid asking a single agent to implement M0–M7 in one context.
