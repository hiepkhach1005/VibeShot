# Remember Last Region Implementation Plan

**Implementation status (2026-09-30):** Implemented; focused unit tests pass. Signed GUI smoke check remains.

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development`; honor the repository planner → coder → tester sequence and apply TDD.

**Goal:** Optionally restore the last completed region on the same display without retaining image or annotation content.

**Architecture:** Persist normalized display-local geometry under a persistent display UUID in version-4 settings. Capture the pointer location when the request starts, restore before showing overlays, and save only when selection geometry changes at a completed interaction boundary.

**Tech Stack:** Swift, AppKit, CoreGraphics, ScreenCaptureKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-29-quality-region-memory-overlay-presentation-design.md`

## Global Constraints

- Remember Last Region is off by default; disabling it clears all saved rectangles.
- Persist only normalized `x`, `y`, `width`, `height` geometry keyed by persistent display UUID.
- Full-screen capture ignores remembered-region data; missing display identity starts with no restored region.
- Restore a fresh selection/document before showing the overlay; preserve cancellation and multi-display safety.

## Review Focus

- Old settings and malformed dictionary entries: valid preferences/records survive independently.
- Resolution/scale/display-origin changes: normalized geometry restores within current bounds and minimum size.
- Pointer/display mismatch: only the pointer display at request time is considered; fallback is deterministic.
- Selection completion: creation, move, resize, and region Command+A persist once; drag intermediates and annotation edits do not.
- Disable/write failure/cancel: clearing is atomic, failures preserve true persisted state, and cancellation keeps the last completed region.

---

### Task 1: Add tolerant settings persistence and normalized geometry

**Files:**
- Modify: `VibeShot/Settings/SettingsModule.swift`
- Modify: `VibeShot/Capture/CaptureModels.swift`
- Test: `VibeShotTests/VibeShotTests.swift`
- Test: `VibeShotTests/M3SelectionTests.swift`

**Interfaces:**
- Produces: `RememberedRegion: Codable, Equatable, Sendable` with `Double` fields `x`, `y`, `width`, `height`, plus `normalized(from:in:)` and `displayLocalRect(in:minimumSize:)`; `AppSettings.rememberLastRegion: Bool` and `rememberedRegions: [String: RememberedRegion]`.

- [x] **Step 1: Add failing migration/geometry tests.** Cover v1/v3 payloads, missing fields, per-entry malformed records, valid sibling preservation, disable/re-enable clearing, and normalized round trips/clamping/minimum size.
- [x] **Step 2: Run focused tests and verify they fail** on missing fields, schema v3, and absent conversion behavior.
- [x] **Step 3: Implement version-4 settings and Codable geometry.** Decode each UUID entry independently; drop invalid records; clear the dictionary when `rememberLastRegion == false`; keep SettingsStore's candidate-write-then-assign failure semantics.
- [x] **Step 4: Run settings and geometry tests** including negative global origins, resolution/scale changes, and non-finite inputs.

### Task 2: Carry persistent display identity and request-time pointer

**Files:**
- Modify: `VibeShot/Capture/CaptureModels.swift`
- Modify: `VibeShot/Capture/CapturePlatform.swift`
- Modify: `VibeShot/Capture/CaptureCoordinator.swift`
- Test: `VibeShotTests/VibeShotTests.swift`

**Interfaces:**
- Produces: `ScreenDescriptor.persistentDisplayID: String?`; `GlobalScreenPoint(x:y:)`; `CaptureSession.pointerLocation: GlobalScreenPoint?`; injectable `CapturePointerProviding.currentPointerLocation()`.

- [x] **Step 1: Add failing provider/coordinator tests** proving pointer position is sampled when capture is requested (before snapshot await), display UUID survives `replacing(pixelSize:)`, and missing UUID remains nil.
- [ ] **Step 2: Run focused tests and verify they fail.**
- [x] **Step 3: Implement identity and pointer propagation.** Populate UUID using CoreGraphics; inject a pointer-location provider into `CaptureCoordinator`; capture it before asynchronous work and include it in the session. Keep existing initializers source-compatible with nil/default values for tests.
- [x] **Step 4: Run capture model/coordinator tests** including pointer outside topology fallback inputs.

### Task 3: Restore, persist, and expose the setting

**Files:**
- Modify: `VibeShot/Overlay/SelectionController.swift`
- Modify: `VibeShot/Overlay/OverlayWindowController.swift`
- Modify: `VibeShot/Overlay/CaptureSessionConsumer.swift`
- Modify: `VibeShot/MenuBar/StatusItemController.swift`
- Modify: `VibeShot/App/AppDelegate.swift`
- Test: `VibeShotTests/M3SelectionTests.swift`
- Test: `VibeShotTests/VibeShotTests.swift`
- Update: `docs/PRODUCT_SPEC.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`, `docs/IMPLEMENTATION_PLAN.md`, `docs/HISTORY.md`, `docs/PROGRESS.md`

**Interfaces:**
- Consumes: `RememberedRegion`, display UUID, and request-time pointer from Tasks 1–2.
- Produces: `SelectionController.restoreSelection(_:) -> Bool`, `CaptureOverlayWindowController.restoreSelection(_:) -> Bool`, a completed-geometry callback, pre-show region restoration, and a checkable Remember Last Region item.

- [ ] **Step 1: Add failing controller/session/menu tests.** Cover restore-before-show, only the matching pointer display, no cross-display fallback, full-screen exclusion, fresh annotation state, and checked state after persisted update/failure.
- [ ] **Step 2: Add failing selection-completion persistence tests.** Assert one write after create/move/resize/region Command+A, none during drag/annotation, and cancellation retains completed geometry. Exercise the local mouse monitor path as well as controller callbacks.
- [ ] **Step 3: Run focused tests and verify they fail.**
- [x] **Step 4: Implement restore and completion callbacks.** Clamp restored geometry to display bounds and 8-point minimum; restore before `show()`. Compare geometry at interaction start/end to avoid annotation mouse-up writes; persist via one settings mutation. Full-screen never reads/writes remembered state.
- [x] **Step 5: Implement menu/error behavior.** Toggle setting and clear records atomically; reflect stored state after success/failure. Route region-save failures through an overlay-safe owned-system-UI callback that restores only the active session.
- [ ] **Step 6: Run focused tests and update docs.** Verify failed settings writes leave editing responsive; document the opt-in geometry-only policy, schema migration, display routing, tests, and current milestone status.
