# SDD ledger — plan: docs/superpowers/plans/2026-09-29-remember-last-region.md

Workspace note: `sdd-workspace` failed because this directory is not a Git repository; no worktree, base commit, or generated Git review package is available. The user explicitly requested implementation in this workspace. Baseline of named source/test/docs files is archived at `/tmp/vibeshot-baseline.kvKfhm/baseline.tar`; keep edits limited to approved plans and review against this baseline.

## Pre-flight scan and rulings

| Pair | Shared files/interface | Finding | Ruling |
|---|---|---|---|
| Remember Task 1 × Task 2 | `CaptureModels.swift` | Task 1 adds normalized geometry; Task 2 adds display identity and request point/session propagation. | Keep distinct types and add compatibly; execute Task 1 before Task 2. |
| Remember Task 1 × Task 3 | `SettingsModule.swift`, `RememberedRegion`; settings/menu/docs | Task 3 consumes v4 settings and geometry from Task 1. | Preserve geometry-only schema; Task 3 must use atomic store update and not bypass validation. |
| Remember Task 2 × Task 3 | `ScreenDescriptor.persistentDisplayID`, `CaptureSession.pointerLocation` | Restore routing depends on stable display identity and request-start pointer. | Capture pointer synchronously before async snapshot; carry optional UUID unchanged through pixel-size replacement. |
| Remember Task 3 × Animation Task 1 | `OverlayWindowController.swift`; architecture/testing/history/progress docs | Restore-before-show and animation experiment share presentation controller/docs. | Finish restore flow first; animation remains unchanged unless observed comparison supports `.none`. |
| Remember plan × Quality plan | settings/menu and source-of-truth docs | v4 migration overlaps fixed quality. | Keep `imageQuality` normalized to 100 when versioning settings. |
| Remember plan self-check | restore-before-show vs interaction persistence | Restored geometry is not a new completed selection; annotation-only mouse-up must not save. | Suppress persistence during restore and compare geometry at interaction start/end; full-screen/cancel do not clear memory. |

## Tasks

- Task 1: implemented. Settings schema v4, tolerant per-entry decode, atomic clear on disable, normalized geometry and clamped restore.
- Task 2: implemented. Persistent CoreGraphics display UUID and synchronous request-time pointer propagated to session.
- Task 3: implemented. Pre-show restore on pointer display, completed geometry callbacks, menu toggle, and overlay-safe settings failure UI.
- Verification: settings, geometry, pointer timing, display routing, callback, menu failure tests pass. Direct signed GUI validation remains for final human smoke testing.
- Tester repair: an unconditional last-ID `makeKey()` overrode the restored display. Initial focus now targets the restored display; a focused synthetic two-panel test verifies `isKeyWindow` on that display.
