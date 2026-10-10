# Fix Image Quality at 100% Implementation Plan

**Implementation status (2026-09-30):** Complete; settings/menu and sync/async export tests pass.

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development`; honor the repository planner → coder → tester sequence and apply TDD.

**Goal:** Remove adjustable image quality and ensure every app-level export uses 100%.

**Architecture:** Keep `imageQuality` as a backward-compatible persisted field but normalize it to a single app-facing constant. Replace the menu slider with static text and pass the constant directly to sync/async export paths; keep low-level encoder policy parameterized for tests.

**Tech Stack:** Swift, AppKit menus, Image I/O, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-29-quality-region-memory-overlay-presentation-design.md`

## Global Constraints

- App-facing image quality is fixed at 100, including after loading legacy settings.
- PNG/BMP remain lossless; JPEG at 100 remains lossy.
- Keep the existing `imageQuality` key and generic low-level encoder policy.

## Review Focus

- Legacy persisted values: test decode/validation of 1, 37, and 90 normalizes to 100.
- Unvalidated injected store: test export still uses 100 rather than its stored value.
- No settings store: test sync and async paths use 100 rather than a stale fallback.
- Lossless output: test PNG/BMP do not receive lossy quality properties.
- Menu accessibility: test the static 100% item is present and the slider is absent.

---

### Task 1: Fix settings and menu contract

**Files:**
- Modify: `VibeShot/Settings/SettingsModule.swift`
- Modify: `VibeShot/MenuBar/StatusItemController.swift`
- Test: `VibeShotTests/VibeShotTests.swift`
- Update: `docs/PRODUCT_SPEC.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`, `docs/IMPLEMENTATION_PLAN.md`, `docs/PROGRESS.md`

**Interfaces:**
- Produces: `AppSettings.fixedImageQuality == 100`; legacy `imageQuality` remains Codable and validated.

- [x] **Step 1: Write failing settings/menu tests.** Assert defaults, legacy decode, and `validate()` all yield 100; assert the menu contains `Image Quality: 100%`, has no slider/custom quality control, and still handles PNG/BMP correctly.
- [x] **Step 2: Run focused tests and verify they fail** against current defaults/clamping and slider behavior.
- [x] **Step 3: Implement fixed settings behavior.** Add the app-facing constant; use it in defaults, decode fallback, and validation. Remove the quality slider/action and build the static menu item with a tooltip clarifying lossless versus lossy formats.
- [x] **Step 4: Run focused settings/menu tests and update behavior docs.** Confirm legacy settings are normalized without disturbing unrelated preferences; replace stale slider/1–100 requirements in the source-of-truth docs.

### Task 2: Fix all app export quality inputs

**Files:**
- Modify: `VibeShot/Export/ExportModule.swift`
- Test: `VibeShotTests/M6ExportTests.swift`

**Interfaces:**
- Consumes: `AppSettings.fixedImageQuality` from Task 1.
- Produces: sync/async app exports always pass quality 100; `ImageEncoderPolicy` stays generic.

- [x] **Step 1: Add encoder-spy tests** for `save` and `saveAsync` with nil settings and an intentionally unvalidated store containing a lower value; assert quality 100 reaches the encoder.
- [ ] **Step 2: Run the tests and verify they fail** on current settings/fallback values.
- [x] **Step 3: Route app export paths through the fixed constant**, including any app-facing fallback encoding calls; do not constrain direct low-level policy tests.
- [x] **Step 4: Run focused export tests** and assert PNG/BMP omit lossy quality properties.
