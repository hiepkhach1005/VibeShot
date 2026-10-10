# Overlay Opening Animation Investigation Plan

**Investigation status (2026-09-30):** Unconfirmed without a direct cold/warm visual A/B comparison. No production animation change was retained.

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development`; honor the repository planner → coder → tester sequence and apply TDD if a production behavior change is confirmed.

**Goal:** Determine whether AppKit's automatic panel-ordering animation causes the capture-start expansion and apply the smallest verified fix.

**Architecture:** Compare the existing default panel behavior to an overlay-only `.none` animation setting. Preserve the capture image, dimming, key handling, cancellation, and multi-display flow; if the difference does not reproduce the reported behavior, leave production code unchanged.

**Tech Stack:** Swift, AppKit `NSPanel`, Swift Testing, signed macOS UI/manual verification.

**Spec:** `docs/superpowers/specs/2026-09-29-quality-region-memory-overlay-presentation-design.md`

## Global Constraints

- The current expansion is a hypothesis, not a confirmed cause.
- Do not add arbitrary delays, change dim opacity, or suppress selection feedback.
- Apply `NSWindow.AnimationBehavior.none` only to capture overlay panels and only if comparison supports it.

## Review Focus

- Cold versus warm capture: compare the same display and selection path.
- Real versus synthetic snapshots: separate ScreenCaptureKit timing from AppKit ordering.
- First frame: confirm dim/background/selection render correctly with no blank or unstyled flash.
- Input: confirm panel remains interactive/key-capable and Escape/Command+Q still cancel.
- Multi-display: confirm all display overlays still appear and teardown together.

---

### Task 1: Compare AppKit default ordering with no automatic animation

**Files:**
- Modify only if hypothesis is supported: `VibeShot/Overlay/OverlayWindowController.swift`
- Test only if fix is retained: `VibeShotTests/M3SelectionTests.swift`
- Optional generated fixture/test launch adjustment: `VibeShot/App/AppDelegate.swift`
- Update: `docs/ARCHITECTURE.md`, `docs/TESTING.md`, `docs/HISTORY.md`, `docs/PROGRESS.md`

**Interfaces:**
- Consumes: existing `CaptureOverlayWindowController.show()` and synthetic capture path.
- Produces: either a verified overlay-specific no-animation setting or a documented unresolved finding; no API changes.

- [ ] **Step 1: Record baseline observations** for cold/warm real capture and synthetic capture: whether the image scales/expands, whether a blank frame appears, and whether the selection/toolbar/input is ready. Do not use private screenshots as fixtures.
- [ ] **Step 2: Add a failing property test** named `captureOverlayDisablesAutomaticOrderingAnimation`, asserting the panel uses `.none`; run `swift test --filter M3SelectionTests` and confirm it fails with current default behavior.
- [ ] **Step 3: Apply the single-variable experiment.** Set `panel.animationBehavior = .none` only on the capture panel; run `swift test --filter M3SelectionTests` and confirm PASS, rebuild, and repeat the same real/synthetic cold/warm cases against baseline.
- [ ] **Step 4: Keep or remove the experiment based on evidence.** If expansion is removed with no blank frame or input/display regressions, retain the property and test. Otherwise remove both and leave production behavior unchanged.
- [ ] **Step 5: Verify and record.** Run `swift test --filter M3SelectionTests`; when signing/runtime permits, run the signed `VibeShotUI` command documented in `docs/TESTING.md`. Manually verify cold/warm real capture on macOS; update architecture/testing/history/progress with confirmed fix or exact unresolved limitation.
